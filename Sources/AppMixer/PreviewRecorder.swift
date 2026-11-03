import AppKit
import CoreAudio
import SwiftUI

/// `AppMixer --record-demo <dir>`: renders the real panel offscreen, frame by frame, with demo apps and
/// devices (no personal data) and a synthesized music signal that runs through the real EQ → ring →
/// spectrum path. Writes PNG frames for `scripts/make-demo-gif.sh`. Nothing is played or saved.
enum PreviewRecorder {
    static let fps = 12.0
    static let duration = 9.0

    static func record(to directory: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = MixerModel(engineEnabled: false)

        // Demo apps/devices (Apple apps present on every Mac; generic device names).
        func app(_ bundleID: String, _ name: String) -> (AudioApp, NSImage?) {
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            return (AudioApp(id: bundleID, name: name, pid: 0, objectIDs: [], isPlaying: true, isApp: true), icon)
        }
        let demo = [app("com.apple.Music", "Music"), app("com.apple.Safari", "Safari"), app("com.apple.FaceTime", "FaceTime")]
        var icons: [String: NSImage] = [:]
        for (a, icon) in demo { if let icon { icons[a.id] = icon } }
        let devices = [
            OutputDevice(id: 9001, uid: "demo.speakers", name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
            OutputDevice(id: 9002, uid: "demo.airpods", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
            OutputDevice(id: 9003, uid: "demo.display", name: "Studio Display", transport: kAudioDeviceTransportTypeDisplayPort),
        ]
        model.loadPreview(apps: demo.map(\.0), icons: icons, devices: devices,
                          systemUID: "demo.speakers", systemVolume: 0.45)
        model.showAll = false
        let music = "com.apple.Music", safari = "com.apple.Safari", facetime = "com.apple.FaceTime"
        model.expandedEQ = music

        // Audio: synthesized music through a real renderer with the current EQ.
        let rate = 48_000.0
        let renderer = TapRenderer(gain: 1, tapChannels: 2, sampleRate: rate)
        model.demoRing = renderer.ring
        let synth = DemoMusic(rate: rate)
        let block = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        defer { input.deallocate(); output.deallocate() }
        let inList = AudioBufferList.allocate(maximumBuffers: 1)
        let outList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(inList.unsafeMutablePointer); free(outList.unsafeMutablePointer) }
        inList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(block * 8), mData: input)
        outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(block * 8), mData: output)
        func play(seconds: Double) {
            for _ in 0..<Int((seconds * rate / Double(block)).rounded()) {
                synth.fill(input, frames: block)
                renderer.render(input: inList.unsafePointer, output: outList.unsafeMutablePointer)
            }
        }
        play(seconds: 0.5)   // fill the analysis window

        // View, at a fixed size so every frame lines up.
        let host = NSHostingView(rootView: MixerPanel(model: model).background(Color(nsColor: .windowBackgroundColor)))
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let window = NSWindow(contentRect: NSRect(origin: screen.origin, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0              // on screen so SwiftUI renders, but invisible
        window.ignoresMouseEvents = true
        window.contentView = host
        window.orderFrontRegardless()
        settle(window, host, 0.3)
        let size = host.fittingSize
        window.setContentSize(size)

        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let bass = EQ.presets.first { $0.name == "Bass Boost" }!.gains
        let vocal = EQ.presets.first { $0.name == "Vocal / Podcast" }!.gains
        var lastEQ: [Double] = []
        let frames = Int(duration * fps)

        for f in 0..<frames {
            let t = Double(f) / fps
            // Script: EQ Flat → Bass Boost → Vocal; Safari down; FaceTime to AirPods; system volume up.
            let gains: [Double]
            if t < 1.2 { gains = EQ.flat }
            else if t < 2.7 { gains = mix(EQ.flat, bass, ease((t - 1.2) / 1.5)) }
            else if t < 3.6 { gains = bass }
            else if t < 5.1 { gains = mix(bass, vocal, ease((t - 3.6) / 1.5)) }
            else { gains = vocal }
            if gains != lastEQ {
                model.setEQ(gains, for: music)
                renderer.eq.update(EQ.isFlat(gains) ? nil : EQ.coefficients(gains: gains, sampleRate: rate))
                lastEQ = gains
            }
            model.setVolume(t < 5.3 ? 1 : 1 - 0.6 * ease((t - 5.3) / 1.1), for: safari)
            model.setOutput(t < 6.7 ? nil : "demo.airpods", for: facetime)
            model.setPreviewSystemVolume(Float(t < 7.1 ? 0.45 : 0.45 + 0.2 * ease((t - 7.1) / 0.9)))

            play(seconds: 1 / fps)
            model.advancePreviewTick()
            settle(window, host, 0.02)
            guard let image = capture(host, size: size, scale: window.backingScaleFactor) else { continue }
            let url = URL(fileURLWithPath: directory).appendingPathComponent(String(format: "frame_%03d.png", f))
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
        print("wrote \(frames) frames (\(Int(size.width))×\(Int(size.height)) pt @\(Int(window.backingScaleFactor))x, \(Int(fps)) fps) to \(directory)")
    }

    private static func settle(_ window: NSWindow, _ host: NSView, _ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private static func capture(_ host: NSView, size: CGSize, scale: CGFloat) -> CGImage? {
        guard let layer = host.layer,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.translateBy(x: 0, y: size.height)   // the layer tree is top-down; CG is bottom-up
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    private static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func mix(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] {
        zip(a, b).map { ($0 + ($1 - $0) * t * 2).rounded() / 2 }   // 0.5 dB steps like the UI
    }
}

/// A small deterministic "song": kick and bass on the beat, hi-hats, a chord pad and vowel-like formants.
private final class DemoMusic {
    private let rate: Double
    private var n = 0
    private var seed: UInt32 = 0x1234_5678
    private var lastNoise: Float = 0

    init(rate: Double) { self.rate = rate }

    private func noise() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed >> 8) / Float(1 << 24) * 2 - 1
    }

    func fill(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        let beat = 0.5                                      // 120 BPM
        let pad: [Double] = [220, 277.2, 329.6, 440, 554.4, 659.3]
        let formants: [(Double, Double)] = [(700, 0.035), (1150, 0.03), (2600, 0.016), (3400, 0.01)]
        for i in 0..<frames {
            let t = Double(n) / rate
            let inBeat = t.truncatingRemainder(dividingBy: beat)
            let inHalf = t.truncatingRemainder(dividingBy: beat / 2)
            let bar = Int(t / (beat * 4)) % 2
            let root = bar == 0 ? 55.0 : 49.0

            var v = 0.0
            v += 0.32 * exp(-inBeat * 14) * sin(2 * .pi * (48 + 60 * exp(-inBeat * 30)) * inBeat)    // kick
            v += (0.12 + 0.05 * exp(-inBeat * 6)) * sin(2 * .pi * root * t)                         // bass
            v += 0.05 * sin(2 * .pi * root * 2 * t)
            let hat = Double(noise() - lastNoise) * 0.5
            lastNoise = noise()
            v += 0.10 * exp(-inHalf * 40) * hat                                                     // hi-hat
            for (k, f) in pad.enumerated() {
                v += 0.012 * (1 + 0.4 * sin(2 * .pi * 0.3 * t + Double(k))) * sin(2 * .pi * f * t + Double(k))
            }
            let vowel = 0.5 + 0.5 * sin(2 * .pi * 0.25 * t)
            for (f, a) in formants {
                v += a * vowel * sin(2 * .pi * f * (1 + 0.01 * sin(2 * .pi * 5 * t)) * t)
            }
            v += 0.004 * Double(noise())                                                           // air
            let s = Float(v)
            out[2 * i] = s
            out[2 * i + 1] = s
            n += 1
        }
    }
}
