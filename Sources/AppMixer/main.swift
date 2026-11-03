import AppKit
import CoreAudio
import SwiftUI

/// `AppMixer --list`: print what Core Audio reports, without starting the UI or touching any audio.
func listAudioProcesses() {
    if let device = try? CA.defaultOutputDevice() {
        print("Default output: \(CA.name(device))  uid=\((try? CA.deviceUID(device)) ?? "?")")
    }
    print("Permission (System Audio Recording): \(AudioCapturePermission.status())\n")

    print("Output devices:")
    let current = AudioDevices.defaultOutput()
    for d in AudioDevices.outputDevices() {
        let vol = AudioDevices.volume(d.id).map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
        let mute = AudioDevices.isMuted(d.id).map { $0 ? "muted" : "" } ?? ""
        print("  \(d.id == current ? "*" : " ") \(d.name)  [\(d.uid)]  \(fourCC(OSStatus(bitPattern: d.transport)))  volume \(vol) \(mute)")
    }
    print("")

    let processes = AudioProcessScanner.scan()
    print("Core Audio processes: \(processes.count)")
    for p in processes {
        let owner = Responsibility.responsiblePID(for: p.pid).map(String.init) ?? "-"
        print(String(format: "  obj %-5u pid %-6d resp %-6@ %@  %@",
                     p.objectID, p.pid, owner, p.isRunningOutput ? "▶︎" : " ", p.bundleID ?? "(no bundle id)"))
    }

    // Timing of what the UI used to do on the main thread every second.
    func ms(_ block: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 { block() }
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 10 / 1e6
    }
    let scanMs = ms { _ = AudioProcessScanner.scan() }
    let groupMs = ms { _ = AudioProcessScanner.group(processes) }
    let q = DispatchQueue(label: "bench")
    let (coldMs, warmMs) = q.sync { () -> (Double, Double) in
        let cold = ms { _ = AudioProcessCatalog(listenQueue: q).scan() }
        let catalog = AudioProcessCatalog(listenQueue: q)
        _ = catalog.scan()
        let warm = ms { _ = catalog.scan() }
        let a = catalog.scan(), b = AudioProcessScanner.group(AudioProcessScanner.scan())
        print("catalog apps: \(a.count), playing: \(a.filter(\.isPlaying).map(\.name)) | full scan apps: \(b.count), playing: \(b.filter(\.isPlaying).map(\.name))")
        return (cold, warm)
    }
    print(String(format: "\nold full scan+group: %.2f ms | catalog cold: %.2f ms, warm (listeners): %.2f ms",
                 scanMs + groupMs, coldMs, warmMs))

    print("\nGrouped (as the app sees them):")
    let q2 = DispatchQueue(label: "list")
    for app in q2.sync(execute: { AudioProcessCatalog(listenQueue: q2).scan() }) {
        let devices = app.outputDevices.map { CA.name($0) }
        print("  \(app.isPlaying ? "▶︎" : " ") \(app.name)  [\(app.id)]  objects=\(app.objectIDs)\(devices.isEmpty ? "" : "  → \(devices)")")
    }
}

/// `AppMixer --snapshot out.png [--idle]`: render the mixer panel offscreen to a PNG
/// (for README screenshots and layout checks). Does not change any volume.
func snapshotPanel(to path: String, showIdle: Bool, demo: Bool) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let model = MixerModel(engineEnabled: false)   // UI-only: nothing below is saved or applied
    model.showAll = showIdle
    var demoRenderer: TapRenderer?
    defer { _ = demoRenderer }
    if demo, let first = (model.playingApps + model.idleApps).first {
        model.setEQ(EQ.presets[1].gains, for: first.id)
        model.toggleEQExpanded(first.id)
        // Synthetic "music" (pink-ish partials + a bass note and a vocal formant) through the demo EQ,
        // so the preview shows a spectrum drawn by the real render → ring → analyser path.
        let rate = 48_000.0
        let renderer = TapRenderer(gain: 1, tapChannels: 2, sampleRate: rate)
        renderer.eq.update(EQ.coefficients(gains: EQ.presets[1].gains, sampleRate: rate))
        var partials: [(f: Double, a: Double, p: Double)] = (0..<48).map { i in
            let f = 30 * pow(500, Double(i) / 47)
            return (f, 0.02 / sqrt(f / 30), Double(i) * 1.7)
        }
        partials += [(55, 0.12, 0), (110, 0.06, 1), (820, 0.05, 2), (1250, 0.04, 3), (2900, 0.02, 4)]
        let frames = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        let inList = AudioBufferList.allocate(maximumBuffers: 1), outList = AudioBufferList.allocate(maximumBuffers: 1)
        inList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: input)
        outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: output)
        var n = 0
        for _ in 0..<40 {
            for i in 0..<frames {
                let t = Double(n + i) / rate
                let v = Float(partials.reduce(0) { $0 + $1.a * sin(2 * .pi * $1.f * t + $1.p) })
                input[2 * i] = v
                input[2 * i + 1] = v
            }
            n += frames
            renderer.render(input: inList.unsafePointer, output: outList.unsafeMutablePointer)
        }
        model.demoRing = renderer.ring
        model.spectrumAnalyzer(for: first.id).update(from: renderer.ring, smoothing: false)
        demoRenderer = renderer
        if let other = model.devices.first(where: { $0.uid != model.systemDeviceUID }) {
            model.setOutput(other.uid, for: first.id)
        }
    }

    let host = NSHostingView(rootView: MixerPanel(model: model))
    host.frame.size = host.fittingSize
    let screen = NSScreen.main?.visibleFrame ?? .zero
    let window = NSWindow(contentRect: NSRect(origin: screen.origin, size: host.frame.size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = 0            // on a real screen so SwiftUI renders, but invisible
    window.ignoresMouseEvents = true
    window.contentView = host
    window.orderFrontRegardless()
    for _ in 0..<3 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        window.setContentSize(host.fittingSize)
        window.displayIfNeeded()
    }
    let size = host.bounds.size
    let scale = window.backingScaleFactor
    guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let layer = host.layer else { return }
    ctx.scaleBy(x: scale, y: scale)
    ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
    ctx.fill(CGRect(origin: .zero, size: size))
    ctx.translateBy(x: 0, y: size.height)   // the hosting view's layer is top-down; CG is bottom-up
    ctx.scaleBy(x: 1, y: -1)
    layer.render(in: ctx)
    window.orderOut(nil)
    guard let image = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(Int(size.width))×\(Int(size.height)) pt)")
}

/// `AppMixer --watch SECONDS`: diagnostics for the playing-state detection. Prints what the
/// listener-driven catalog reports and flags any disagreement with a direct read of every process.
func watchPlaying(seconds: Double) {
    let q = DispatchQueue(label: "watch")
    let catalog = AudioProcessCatalog(listenQueue: q)
    func playingSet() -> Set<String> { Set(catalog.scan().filter(\.isPlaying).map(\.name)) }
    func truthSet() -> Set<String> {
        let me = getpid()
        return Set(AudioProcessScanner.group(AudioProcessScanner.scan().filter { $0.pid != me }).filter(\.isPlaying).map(\.name))
    }
    let start = Date()
    func stamp() -> String { String(format: "t=%5.2f", Date().timeIntervalSince(start)) }
    var last: Set<String> = q.sync { playingSet() }
    print("\(stamp()) catalog playing: \(last.sorted())"); fflush(stdout)
    catalog.onChange = {
        let now = playingSet()
        if now != last { print("\(stamp()) listener → playing: \(now.sorted())"); fflush(stdout); last = now }
    }
    var address = CA.address(kAudioHardwarePropertyProcessObjectList)
    AudioObjectAddPropertyListenerBlock(CA.systemObject, &address, q) { _, _ in
        let now = playingSet()
        if now != last { print("\(stamp()) process list → playing: \(now.sorted())"); fflush(stdout); last = now }
    }
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        Thread.sleep(forTimeInterval: 0.5)
        q.sync {
            let cached = playingSet(), truth = truthSet()
            if cached != truth {
                print("\(stamp()) MISMATCH catalog \(cached.sorted()) vs direct read \(truth.sorted())"); fflush(stdout)
            }
        }
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--watch") {
    watchPlaying(seconds: Double(CommandLine.arguments.dropFirst(i + 1).first ?? "") ?? 15)
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--record-demo"), i + 1 < CommandLine.arguments.count {
    PreviewRecorder.record(to: CommandLine.arguments[i + 1])
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

if CommandLine.arguments.contains("--list") {
    listAudioProcesses()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    snapshotPanel(to: CommandLine.arguments[i + 1], showIdle: CommandLine.arguments.contains("--idle"),
                  demo: CommandLine.arguments.contains("--demo"))
    exit(0)
}

let app = NSApplication.shared
let controller = StatusBarController(measureOpen: CommandLine.arguments.contains("--measure-open"),
                                     iconPreview: CommandLine.arguments.contains("--icon-preview"))
app.delegate = controller
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
