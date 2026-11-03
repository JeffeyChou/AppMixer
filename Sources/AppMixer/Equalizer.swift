import Foundation
import os

/// 10-band graphic EQ: RBJ peaking filters at octave centres, ±12 dB.
enum EQ {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let bandCount = 10
    static let maxGain: Double = 12
    static let q: Double = 1.41          // ~1 octave bandwidth
    static let flat = [Double](repeating: 0, count: bandCount)

    struct Preset {
        let name: String
        let gains: [Double]
    }

    static let presets: [Preset] = [
        Preset(name: "Flat", gains: flat),
        Preset(name: "Bass Boost", gains: [6, 5, 4, 2, 0.5, 0, 0, 0, 0, 0]),
        Preset(name: "Bass Cut", gains: [-6, -5, -4, -2, -0.5, 0, 0, 0, 0, 0]),
        Preset(name: "Vocal / Podcast", gains: [-4, -3, -1, 1, 2.5, 3.5, 3, 1.5, 0, -1]),
        Preset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 0.5, 2, 4, 5, 6]),
        Preset(name: "Treble Cut", gains: [0, 0, 0, 0, 0, -0.5, -2, -4, -5, -6]),
        Preset(name: "Loudness", gains: [5, 4, 2, 0, -1, -1, 0, 2, 3.5, 4.5]),
        Preset(name: "Small Speakers", gains: [-6, -3, 2, 3, 1, 0, 1, 2, 2, 1]),
    ]

    static func isFlat(_ gains: [Double]) -> Bool { gains.allSatisfy { abs($0) < 0.05 } }

    static func presetName(for gains: [Double]) -> String? {
        presets.first { zip($0.gains, gains).allSatisfy { abs($0 - $1) < 0.05 } }?.name
    }

    /// Normalised biquad coefficients [b0, b1, b2, a1, a2] for every band, flattened.
    static func coefficients(gains: [Double], sampleRate: Double) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(bandCount * 5)
        for (i, f) in frequencies.enumerated() {
            out += peaking(frequency: f, gainDB: i < gains.count ? gains[i] : 0, sampleRate: sampleRate).map(Float.init)
        }
        return out
    }

    static func peaking(frequency: Double, gainDB: Double, sampleRate: Double) -> [Double] {
        guard abs(gainDB) > 0.01, frequency < sampleRate * 0.45 else { return [1, 0, 0, 0, 0] }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return [(1 + alpha * a) / a0, (-2 * cosw) / a0, (1 - alpha * a) / a0,
                (-2 * cosw) / a0, (1 - alpha / a) / a0]
    }

    /// Combined magnitude response in dB at `frequency` (for drawing the curve).
    static func response(gains: [Double], at frequency: Double, sampleRate: Double = 48_000) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        var db = 0.0
        for (i, f) in frequencies.enumerated() where abs(gains[i]) > 0.01 {
            let k = peaking(frequency: f, gainDB: gains[i], sampleRate: sampleRate)
            let nr = k[0] + k[1] * c1 + k[2] * c2, ni = -(k[1] * s1 + k[2] * s2)
            let dr = 1 + k[3] * c1 + k[4] * c2, di = -(k[3] * s1 + k[4] * s2)
            db += 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
        }
        return db
    }
}

/// Real-time EQ state for one tap. New coefficients are handed over through a lock that the IO thread
/// only ever *tries* to take, so the audio thread never blocks; filter memory is kept across updates so
/// dragging a band doesn't click.
final class EQProcessor {
    static let maxChannels = 8
    private let bands = EQ.bandCount

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let pending: UnsafeMutablePointer<Float>
    private var pendingEnabled = false
    private var pendingGeneration = 0

    // IO-thread only.
    private let active: UnsafeMutablePointer<Float>
    private let memory: UnsafeMutablePointer<Float>   // [channel][band][z1, z2]
    private var enabled = false
    private var appliedGeneration = 0

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        pending = .allocate(capacity: bands * 5)
        pending.initialize(repeating: 0, count: bands * 5)
        active = .allocate(capacity: bands * 5)
        active.initialize(repeating: 0, count: bands * 5)
        memory = .allocate(capacity: Self.maxChannels * bands * 2)
        memory.initialize(repeating: 0, count: Self.maxChannels * bands * 2)
    }

    deinit {
        lock.deallocate()
        pending.deallocate()
        active.deallocate()
        memory.deallocate()
    }

    /// nil = bypass. Call from any thread except the IO thread.
    func update(_ coefficients: [Float]?) {
        os_unfair_lock_lock(lock)
        if let coefficients, coefficients.count == bands * 5 {
            for i in 0..<(bands * 5) { pending[i] = coefficients[i] }
            pendingEnabled = true
        } else {
            pendingEnabled = false
        }
        pendingGeneration &+= 1
        os_unfair_lock_unlock(lock)
    }

    /// IO thread: filters `channels` planar buffers (spaced `capacity` apart) in place.
    func process(_ buffers: UnsafeMutablePointer<Float>, channels: Int, capacity: Int, frames: Int) {
        if os_unfair_lock_trylock(lock) {
            if pendingGeneration != appliedGeneration {
                appliedGeneration = pendingGeneration
                let wasEnabled = enabled
                enabled = pendingEnabled
                if enabled { active.update(from: pending, count: bands * 5) }
                if enabled && !wasEnabled { memory.update(repeating: 0, count: Self.maxChannels * bands * 2) }
            }
            os_unfair_lock_unlock(lock)
        }
        guard enabled, frames > 0 else { return }

        for ch in 0..<min(channels, Self.maxChannels) {
            let x = buffers + ch * capacity
            for b in 0..<bands {
                let c = active + b * 5
                let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
                if b0 == 1 && b1 == 0 && b2 == 0 && a1 == 0 && a2 == 0 { continue }   // 0 dB band
                let m = memory + (ch * bands + b) * 2
                var z1 = m[0], z2 = m[1]
                var i = 0
                while i < frames {   // transposed direct form II
                    let input = x[i]
                    let y = b0 * input + z1
                    z1 = b1 * input - a1 * y + z2
                    z2 = b2 * input - a2 * y
                    x[i] = y
                    i += 1
                }
                m[0] = z1
                m[1] = z2
            }
        }
    }
}
