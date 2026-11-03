import CoreAudio
import Foundation

/// Per-app processing via a Core Audio process tap:
///
///   app audio ──▶ process tap (app muted at the hardware while we read it)
///                     │
///                     ▼
///   private aggregate device [ tap as input  +  output device(s) ]
///                     │  IOProc: EQ → × gain → clamp
///                     ▼
///      chosen output (system output, a specific device, or several devices when sharing)
///
/// Everything is private to this process, so if AppMixer quits or crashes the tap disappears
/// and the app plays normally again.
final class ProcessTap {
    let signature: String
    private let renderer: TapRenderer
    private let sampleRate: Double
    private var appliedEQ: [Double]?
    private var tapID = CA.unknown
    private var aggregateID = CA.unknown
    private var procID: AudioDeviceIOProcID?

    /// `outputUIDs`: one device, or several to play on all of them (stacked aggregate, first = clock).
    init(name: String, processObjectIDs: [AudioObjectID], outputUIDs: [String], gain: Float, eq: [Double]?) throws {
        signature = ProcessTap.signature(objectIDs: processObjectIDs, outputUIDs: outputUIDs)
        guard let mainUID = outputUIDs.first else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, what: "no output device")
        }

        var tap = CA.unknown
        var aggregate = CA.unknown
        func cleanUp() {
            if aggregate != CA.unknown { AudioHardwareDestroyAggregateDevice(aggregate) }
            if tap != CA.unknown { AudioHardwareDestroyProcessTap(tap) }
        }

        let channels: Int
        let rate: Double
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
            description.uuid = UUID()
            description.name = "AppMixer – \(name)"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")

            let format = try CA.get(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0 else {
                throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, what: "unexpected tap format")
            }
            channels = Int(format.mChannelsPerFrame)

            var subdevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: mainUID]]
            for uid in outputUIDs.dropFirst() {
                subdevices.append([kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: true])
            }
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AppMixer – \(name)",
                kAudioAggregateDeviceUIDKey: "AppMixer.aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: mainUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: outputUIDs.count > 1,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: subdevices,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
                      "AudioHardwareCreateAggregateDevice")

            let nominal = (try? CA.get(aggregate, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0
            rate = nominal > 0 ? nominal : (format.mSampleRate > 0 ? format.mSampleRate : 48_000)
        } catch {
            cleanUp()
            throw error
        }

        tapID = tap
        aggregateID = aggregate
        sampleRate = rate
        renderer = TapRenderer(gain: gain, tapChannels: channels, sampleRate: rate)
        setEQ(eq)

        let renderer = self.renderer
        var proc: AudioDeviceIOProcID?
        do {
            // nil queue: the block runs directly on the HAL's real-time IO thread.
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, output, _ in
                renderer.render(input: input, output: output)
            }, "AudioDeviceCreateIOProcIDWithBlock")
            procID = proc
            try check(AudioDeviceStart(aggregate, proc), "AudioDeviceStart")
        } catch {
            invalidate()
            throw error
        }
    }

    static func signature(objectIDs: [AudioObjectID], outputUIDs: [String]) -> String {
        outputUIDs.joined(separator: "+") + "|" + objectIDs.sorted().map(String.init).joined(separator: ",")
    }

    func setGain(_ gain: Float) {
        renderer.target.pointee = gain
    }

    /// Latest post-EQ samples, for the spectrum view.
    var analysis: AnalysisRing { renderer.ring }

    /// nil or all-zero = EQ off.
    func setEQ(_ gains: [Double]?) {
        let effective = gains.flatMap { EQ.isFlat($0) ? nil : $0 }
        guard effective != appliedEQ else { return }
        appliedEQ = effective
        renderer.eq.update(effective.map { EQ.coefficients(gains: $0, sampleRate: sampleRate) })
    }

    func invalidate() {
        if aggregateID != CA.unknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != CA.unknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = CA.unknown
        tapID = CA.unknown
    }

    deinit { invalidate() }
}

/// Real-time render state. No allocation or blocking in `render`.
final class TapRenderer {
    /// Written by the engine queue, read by the IO thread (an aligned Float store is atomic on arm64/x86_64).
    let target: UnsafeMutablePointer<Float>
    let eq = EQProcessor()
    let ring: AnalysisRing
    private var current: Float
    private let tapChannels: Int
    private let capacity = 16_384                       // frames per channel in the scratch buffer
    private let scratch: UnsafeMutablePointer<Float>   // planar: tapChannels × capacity

    init(gain: Float, tapChannels: Int, sampleRate: Double) {
        ring = AnalysisRing(sampleRate: sampleRate)
        target = .allocate(capacity: 1)
        target.initialize(to: gain)
        current = gain
        self.tapChannels = tapChannels
        scratch = .allocate(capacity: tapChannels * capacity)
        scratch.initialize(repeating: 0, count: tapChannels * capacity)
    }

    deinit {
        target.deallocate()
        scratch.deallocate()
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        let g0 = current
        let g1 = target.pointee
        current = g1

        // 1. Gather the tap's channels (the trailing input buffers) into planar scratch buffers.
        var remaining = tapChannels
        var firstTapBuffer = inList.count
        while firstTapBuffer > 0 && remaining > 0 {
            firstTapBuffer -= 1
            remaining -= Int(inList[firstTapBuffer].mNumberChannels)
        }
        var frames = remaining == 0 ? capacity : 0
        if frames > 0 {
            for tc in 0..<tapChannels {
                guard let (src, stride, n) = channel(inList, firstTapBuffer, tc) else { frames = 0; break }
                frames = min(frames, n)
                let dst = scratch + tc * capacity
                var i = 0
                while i < frames {
                    dst[i] = src[i * stride]
                    i += 1
                }
            }
        }

        // 2. EQ in place, then hand the (post-EQ, pre-volume) signal to the spectrum view.
        eq.process(scratch, channels: tapChannels, capacity: capacity, frames: frames)
        ring.append(planar: scratch, channels: tapChannels, stride: capacity, frames: frames)

        // 3. Gain ramp (g0 → g1, avoids zipper noise) + clamp into every output buffer.
        var totalOut = 0
        for b in outList { totalOut += Int(b.mNumberChannels) }
        let step = frames > 0 ? (g1 - g0) / Float(frames) : 0

        var base = 0
        for ob in 0..<outList.count {
            let buf = outList[ob]
            let nch = Int(buf.mNumberChannels)
            defer { base += nch }
            guard nch > 0, let raw = buf.mData else { continue }
            memset(raw, 0, Int(buf.mDataByteSize))
            let out = raw.assumingMemoryBound(to: Float.self)
            let n = min(frames, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * nch))
            guard n > 0 else { continue }

            for c in 0..<nch {
                let oc = base + c
                var g = g0
                var i = 0
                if totalOut == 1 {
                    // Mono device: average all tap channels.
                    let w = 1 / Float(tapChannels)
                    while i < n {
                        var sum: Float = 0
                        for tc in 0..<tapChannels { sum += scratch[tc * capacity + i] }
                        out[i * nch + c] = clamp(sum * w * g)
                        g += step
                        i += 1
                    }
                } else if oc < tapChannels {
                    let src = scratch + oc * capacity
                    while i < n {
                        out[i * nch + c] = clamp(src[i] * g)
                        g += step
                        i += 1
                    }
                }
            }
        }
    }

    @inline(__always)
    private func clamp(_ x: Float) -> Float { x > 1 ? 1 : (x < -1 ? -1 : x) }

    /// Pointer, stride and frame count of tap channel `channel` within the input buffer list.
    @inline(__always)
    private func channel(_ list: UnsafeMutableAudioBufferListPointer, _ firstBuffer: Int, _ channel: Int)
        -> (UnsafeMutablePointer<Float>, Int, Int)? {
        var idx = channel
        var b = firstBuffer
        while b < list.count {
            let buf = list[b]
            let n = Int(buf.mNumberChannels)
            if idx < n {
                guard let data = buf.mData, n > 0 else { return nil }
                let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * n)
                return (data.assumingMemoryBound(to: Float.self) + idx, n, frames)
            }
            idx -= n
            b += 1
        }
        return nil
    }
}
