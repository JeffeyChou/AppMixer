import CoreAudio
import Foundation

/// `AppMixer --selftest`: runs the real-time render path (`TapRenderer`) on synthetic sine waves and
/// checks gain, EQ and channel mapping against the math, then times it. No audio device involved.
enum SelfTest {
    static let rate = 48_000.0
    static let frames = 512

    static func run() -> Bool {
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            print("\(pass ? "PASS" : "FAIL")  \(name): \(detail)")
            ok = ok && pass
        }

        // 1. Flat EQ, gain 1 → output identical to input.
        do {
            let r = run(frequency: 1000, gain: 1, eq: nil, blocks: 4)
            check("passthrough", r.maxError < 1e-6, String(format: "max |out-in| = %.2e", r.maxError))
        }
        // 2. Steady gain 0.25 → -12.04 dB.
        do {
            let r = run(frequency: 1000, gain: 0.25, eq: nil, blocks: 20)  // ramp settles in block 1
            check("gain 0.25", abs(r.gainDB + 12.04) < 0.05, String(format: "%.2f dB (expected -12.04)", r.gainDB))
        }
        // 3. EQ: measured gain at several frequencies matches the analytic response.
        let bass = EQ.presets.first { $0.name == "Bass Boost" }!.gains
        let vocal = EQ.presets.first { $0.name == "Vocal / Podcast" }!.gains
        for (name, gains) in [("Bass Boost", bass), ("Vocal", vocal)] {
            for f in [40.0, 125, 1000, 6000] {
                let r = run(frequency: f, gain: 1, eq: gains, blocks: 60)
                let expected = EQ.response(gains: gains, at: f, sampleRate: rate)
                check("EQ \(name) @ \(Int(f)) Hz", abs(r.gainDB - expected) < 0.1,
                      String(format: "%.2f dB (expected %.2f)", r.gainDB, expected))
            }
        }
        // 4. Mono output device gets the average of L and R.
        do {
            let r = run(frequency: 440, gain: 1, eq: nil, blocks: 4, outChannels: 1)
            check("mono downmix", r.maxError < 1e-6, String(format: "max error = %.2e", r.maxError))
        }

        // 5. Cost of one 512-frame stereo buffer with a 10-band EQ (budget at 48 kHz: 10 667 µs).
        let iterations = 20_000
        let t = timeRender(eq: vocal, iterations: iterations)
        print(String(format: "TIME  render 512 frames stereo + 10-band EQ: %.2f µs/buffer = %.3f%% of one core in real time",
                     t, t / (Double(frames) / rate * 1e6) * 100))
        return ok
    }

    private struct Result { let gainDB: Double; let maxError: Float }

    /// Feeds `blocks` buffers of a sine through a renderer; compares the last block with the input.
    private static func run(frequency: Double, gain: Float, eq: [Double]?, blocks: Int, outChannels: Int = 2) -> Result {
        let renderer = TapRenderer(gain: gain, tapChannels: 2)
        renderer.eq.update(eq.map { EQ.coefficients(gains: $0, sampleRate: rate) })
        let input = Buffers(channels: 2, frames: frames)
        let output = Buffers(channels: outChannels, frames: frames)
        var phase = 0.0
        var maxError: Float = 0
        var inTail: [Double] = [], outTail: [Double] = []   // last 8 blocks, channel 0
        for block in 0..<blocks {
            for i in 0..<frames {
                let v = Float(0.25 * sin(phase))
                phase += 2 * .pi * frequency / rate
                input.data[i * 2] = v
                input.data[i * 2 + 1] = v
            }
            renderer.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
            guard block >= blocks - 8 else { continue }
            for i in 0..<frames {
                let x = input.data[i * 2]
                let y = output.data[i * outChannels]
                inTail.append(Double(x))
                outTail.append(Double(y))
                if block == blocks - 1 { maxError = max(maxError, abs(y - x * gain)) }
            }
        }
        // RMS over a whole number of periods at the end, so the result doesn't depend on phase.
        let period = rate / frequency
        let n = max(1, Int((Double(inTail.count) / period).rounded(.down) * period))
        func rms(_ v: [Double]) -> Double { sqrt(v.suffix(n).reduce(0) { $0 + $1 * $1 } / Double(n)) }
        return Result(gainDB: 20 * log10(rms(outTail) / rms(inTail)), maxError: maxError)
    }

    private static func timeRender(eq: [Double], iterations: Int) -> Double {
        let renderer = TapRenderer(gain: 0.8, tapChannels: 2)
        renderer.eq.update(EQ.coefficients(gains: eq, sampleRate: rate))
        let input = Buffers(channels: 2, frames: frames)
        let output = Buffers(channels: 2, frames: frames)
        for i in 0..<(frames * 2) { input.data[i] = Float(sin(Double(i) * 0.01)) * 0.3 }
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            renderer.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        }
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(iterations) / 1000
    }

    /// One interleaved AudioBuffer in an AudioBufferList.
    private final class Buffers {
        let data: UnsafeMutablePointer<Float>
        let list: UnsafeMutableAudioBufferListPointer

        init(channels: Int, frames: Int) {
            data = .allocate(capacity: channels * frames)
            data.initialize(repeating: 0, count: channels * frames)
            list = AudioBufferList.allocate(maximumBuffers: 1)
            list[0] = AudioBuffer(mNumberChannels: UInt32(channels),
                                  mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.size),
                                  mData: UnsafeMutableRawPointer(data))
        }

        deinit {
            data.deallocate()
            free(list.unsafeMutablePointer)
        }
    }
}
