import CoreAudio
import Foundation

/// Per-app volume via a Core Audio process tap:
///
///   app audio ──▶ process tap (app muted at the hardware while we read it)
///                     │
///                     ▼
///   private aggregate device [ tap as input  +  current output device as output ]
///                     │  IOProc: out = clamp(in × gain)
///                     ▼
///                 speakers / headphones
///
/// Everything is private to this process, so if AppMixer quits or crashes the tap disappears
/// and the app plays at its normal volume again.
final class ProcessTap {
    let signature: String
    private let renderer: TapRenderer
    private var tapID = CA.unknown
    private var aggregateID = CA.unknown
    private var procID: AudioDeviceIOProcID?

    init(name: String, processObjectIDs: [AudioObjectID], outputDevice: AudioDeviceID, gain: Float) throws {
        signature = ProcessTap.signature(objectIDs: processObjectIDs, outputDevice: outputDevice)

        var tap = CA.unknown
        var aggregate = CA.unknown
        func cleanUp() {
            if aggregate != CA.unknown { AudioHardwareDestroyAggregateDevice(aggregate) }
            if tap != CA.unknown { AudioHardwareDestroyProcessTap(tap) }
        }

        let channels: Int
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

            let outputUID = try CA.deviceUID(outputDevice)
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AppMixer – \(name)",
                kAudioAggregateDeviceUIDKey: "AppMixer.aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
                      "AudioHardwareCreateAggregateDevice")
        } catch {
            cleanUp()
            throw error
        }

        tapID = tap
        aggregateID = aggregate
        renderer = TapRenderer(gain: gain, tapChannels: channels)

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

    static func signature(objectIDs: [AudioObjectID], outputDevice: AudioDeviceID) -> String {
        "\(outputDevice)|" + objectIDs.sorted().map(String.init).joined(separator: ",")
    }

    func setGain(_ gain: Float) {
        renderer.target.pointee = gain
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

/// Real-time render state. No allocation or locking in `render`.
final class TapRenderer {
    /// Written by the main thread, read by the IO thread (an aligned Float store is atomic on arm64/x86_64).
    let target: UnsafeMutablePointer<Float>
    private var current: Float
    private let tapChannels: Int

    init(gain: Float, tapChannels: Int) {
        target = .allocate(capacity: 1)
        target.initialize(to: gain)
        current = gain
        self.tapChannels = tapChannels
    }

    deinit { target.deallocate() }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        let g0 = current
        let g1 = target.pointee
        current = g1

        // Tap streams come after any input streams of the output device, so they are the
        // trailing buffers of the input list.
        var remaining = tapChannels
        var firstTapBuffer = inList.count
        while firstTapBuffer > 0 && remaining > 0 {
            firstTapBuffer -= 1
            remaining -= Int(inList[firstTapBuffer].mNumberChannels)
        }
        let tapFound = remaining == 0

        var totalOut = 0
        for b in outList { totalOut += Int(b.mNumberChannels) }

        var base = 0
        for ob in 0..<outList.count {
            let buf = outList[ob]
            let nch = Int(buf.mNumberChannels)
            defer { base += nch }
            guard nch > 0, let raw = buf.mData else { continue }
            memset(raw, 0, Int(buf.mDataByteSize))
            guard tapFound else { continue }

            let out = raw.assumingMemoryBound(to: Float.self)
            let outFrames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * nch)

            for c in 0..<nch {
                let oc = base + c
                if totalOut == 1 {
                    // Mono device: average all tap channels into it.
                    let w = 1 / Float(tapChannels)
                    for tc in 0..<tapChannels {
                        mix(inList, firstTapBuffer, tc, into: out + c, outStride: nch, outFrames: outFrames,
                            g0: g0 * w, g1: g1 * w)
                    }
                } else if oc < tapChannels {
                    mix(inList, firstTapBuffer, oc, into: out + c, outStride: nch, outFrames: outFrames,
                        g0: g0, g1: g1)
                }
                // Clamp so boosted (>100%) audio clips cleanly instead of wrapping in the driver.
                var i = 0
                while i < outFrames {
                    let p = out + (i * nch + c)
                    if p.pointee > 1 { p.pointee = 1 } else if p.pointee < -1 { p.pointee = -1 }
                    i += 1
                }
            }
        }
    }

    /// Adds tap channel `channel` × a linear gain ramp (g0 → g1, avoids zipper noise) into `dst`.
    @inline(__always)
    private func mix(_ list: UnsafeMutableAudioBufferListPointer, _ firstBuffer: Int, _ channel: Int,
                     into dst: UnsafeMutablePointer<Float>, outStride: Int, outFrames: Int,
                     g0: Float, g1: Float) {
        var idx = channel
        var b = firstBuffer
        while b < list.count {
            let buf = list[b]
            let n = Int(buf.mNumberChannels)
            if idx < n {
                guard let data = buf.mData else { return }
                let src = data.assumingMemoryBound(to: Float.self) + idx
                let frames = min(outFrames, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * n))
                guard frames > 0 else { return }
                let step = (g1 - g0) / Float(frames)
                var g = g0
                var i = 0
                while i < frames {
                    dst[i * outStride] += src[i * n] * g
                    g += step
                    i += 1
                }
                return
            }
            idx -= n
            b += 1
        }
    }
}
