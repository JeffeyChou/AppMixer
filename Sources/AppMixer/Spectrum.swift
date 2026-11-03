import Accelerate
import Foundation

/// Lock-free single-producer ring of the most recent mono samples of one tap (post-EQ, pre-volume).
/// The IO thread appends; the UI copies the latest window. A torn read only affects one frame of the
/// visualisation, so there is no synchronisation beyond the monotonically increasing write count.
final class AnalysisRing {
    static let capacity = 16_384                 // power of two
    let sampleRate: Double
    private let buffer: UnsafeMutablePointer<Float>
    private let written: UnsafeMutablePointer<Int>

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        buffer = .allocate(capacity: Self.capacity)
        buffer.initialize(repeating: 0, count: Self.capacity)
        written = .allocate(capacity: 1)
        written.initialize(to: 0)
    }

    deinit {
        buffer.deallocate()
        written.deallocate()
    }

    /// IO thread: appends the average of `channels` planar buffers (spaced `stride` apart).
    func append(planar: UnsafePointer<Float>, channels: Int, stride: Int, frames: Int) {
        guard channels > 0, frames > 0 else { return }
        let mask = Self.capacity - 1
        let start = written.pointee
        let w = 1 / Float(channels)
        var i = 0
        while i < frames {
            var sum: Float = 0
            for c in 0..<channels { sum += planar[c * stride + i] }
            buffer[(start + i) & mask] = sum * w
            i += 1
        }
        written.pointee = start + frames
    }

    /// Copies the latest `count` samples into `dst`; returns the total number of samples written so far
    /// (unchanged between calls = no new audio).
    func latest(_ count: Int, into dst: UnsafeMutablePointer<Float>) -> Int {
        let end = written.pointee
        let mask = Self.capacity - 1
        for i in 0..<count { dst[i] = buffer[(end - count + i) & mask] }
        return end
    }
}

/// Constant-Q (1/6 octave) spectrum of an `AnalysisRing`, 32 Hz–16 kHz, with analyser-style ballistics
/// (fast rise, ~45 dB/s fall). An 8192-point real FFT via vDSP; called ~30×/s while an EQ is open.
final class SpectrumAnalyzer {
    static let log2n: vDSP_Length = 13
    static let size = 1 << 13
    static let bandsPerOctave = 6.0
    static let floorDB: Float = -96

    /// Band centre frequencies (Hz), log-spaced like the EQ graph's x axis.
    let centers: [Double]
    /// Smoothed level of each band in dBFS (a full-scale sine reads 0 dB).
    private(set) var levels: [Float]

    private let setup: FFTSetup
    private var window: [Float]
    private var samples: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var bins: [(lo: Int, hi: Int, peak: Bool)] = []
    private var binRate = 0.0
    private var lastWritten = -1

    init() {
        let n = Self.size
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }   // Hann
        samples = [Float](repeating: 0, count: n)
        windowed = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        power = [Float](repeating: 0, count: n / 2)
        let lo = EQ.frequencies.first!, hi = EQ.frequencies.last!
        let count = Int((log2(hi / lo) * Self.bandsPerOctave).rounded()) + 1
        centers = (0..<count).map { lo * pow(2, Double($0) / Self.bandsPerOctave) }
        levels = [Float](repeating: Self.floorDB, count: count)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Pulls the newest window from `ring` and advances the display levels by one frame.
    func update(from ring: AnalysisRing?, smoothing: Bool = true) {
        guard let ring else { decay(); return }
        let n = Self.size
        let written = samples.withUnsafeMutableBufferPointer { ring.latest(n, into: $0.baseAddress!) }
        guard written != lastWritten else { decay(); return }   // no new audio: let the bars fall
        lastWritten = written
        if ring.sampleRate != binRate { prepareBins(sampleRate: ring.sampleRate) }

        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { s in
                    s.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        power[0] = 0   // packed DC/Nyquist; irrelevant here

        // zrip output is 2× the DFT and Hann has coherent gain 0.5, so a sine of amplitude A peaks at
        // |X| = A·N/2. Band energy is summed and divided by Hann's noise bandwidth (1.5 bins).
        let reference = 20 * log10(Float(n) / 2)
        for (b, range) in bins.enumerated() {
            var energy: Float = 0
            if range.peak {
                for k in range.lo...range.hi { energy = max(energy, power[k]) }
            } else {
                for k in range.lo...range.hi { energy += power[k] }
                energy /= 1.5
            }
            let db = max(10 * log10(energy + 1e-20) - reference, Self.floorDB)
            if !smoothing {
                levels[b] = db
            } else if db > levels[b] {
                levels[b] += (db - levels[b]) * 0.7
            } else {
                levels[b] = max(db, levels[b] - 1.5)
            }
        }
    }

    private func decay() {
        for b in levels.indices where levels[b] > Self.floorDB {
            levels[b] = max(Self.floorDB, levels[b] - 1.5)
        }
    }

    private func prepareBins(sampleRate: Double) {
        binRate = sampleRate
        let df = sampleRate / Double(Self.size)
        let half = pow(2, 0.5 / Self.bandsPerOctave)
        let maxBin = Self.size / 2 - 1
        bins = centers.map { fc in
            let loF = fc / half / df, hiF = fc * half / df
            let lo = Int(loF.rounded(.up)), hi = Int(hiF.rounded(.down))
            if hi - lo + 1 >= 3 {
                return (min(lo, maxBin), min(hi, maxBin), false)   // wide band: summed energy
            }
            // Narrow (low-frequency) band: a tone's energy straddles bins, so read the peak of every bin
            // overlapping the band instead.
            return (min(max(Int(loF.rounded(.down)), 1), maxBin), min(max(Int(hiF.rounded(.up)), 1), maxBin), true)
        }
    }
}
