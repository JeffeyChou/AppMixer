import AppKit
import CoreAudio
import SwiftUI

/// `AppMixer --list`: print what Core Audio reports, without starting the UI or touching any audio.
func listAudioProcesses() {
    if let device = try? CA.defaultOutputDevice() {
        print("Default output: \(CA.name(device))  uid=\((try? CA.deviceUID(device)) ?? "?")")
    }
    print("Permission (System Audio Recording): \(AudioCapturePermission.status())\n")

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

    print("\nGrouped:")
    for app in AudioProcessScanner.group(processes) {
        print("  \(app.isPlaying ? "▶︎" : " ") \(app.name)  [\(app.id)]  objects=\(app.objectIDs)")
    }
}

/// `AppMixer --snapshot out.png [--idle]`: render the mixer panel offscreen to a PNG
/// (for README screenshots and layout checks). Does not change any volume.
func snapshotPanel(to path: String, showIdle: Bool) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let model = MixerModel(engineEnabled: false)
    let savedShowAll = model.showAll
    model.showAll = showIdle
    defer { model.showAll = savedShowAll }

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
    print("wrote \(path) (\(Int(size.width))×\(Int(size.height)) pt, max list height \(Int((NSScreen.main?.visibleFrame.height ?? 0) * 0.5 - 110)) pt)")
}

if CommandLine.arguments.contains("--list") {
    listAudioProcesses()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    snapshotPanel(to: CommandLine.arguments[i + 1], showIdle: CommandLine.arguments.contains("--idle"))
    exit(0)
}

let app = NSApplication.shared
let controller = StatusBarController(measureOpen: CommandLine.arguments.contains("--measure-open"),
                                     iconPreview: CommandLine.arguments.contains("--icon-preview"))
app.delegate = controller
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
