import AppKit
import SwiftUI

/// Menu bar icon. Left click toggles the mixer popover; right click (or ⌃-click) shows a menu
/// with Mute All / Reset All / Quit. (SwiftUI's MenuBarExtra can't do a right-click menu.)
final class StatusBarController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private let model: MixerModel
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let measureOpen: Bool
    private var openTimings: [(String, Double)] = []
    private var lastClose = Date.distantPast

    /// `measureOpen`: dev mode (`--measure-open`) that opens/closes the panel a few times, prints how long
    /// the main thread was blocked during each opening animation, and quits. Audio engine is off.
    private let iconPreview: Bool

    /// `iconPreview`: dev mode (`--icon-preview`) that only shows the menu bar icon for 3 s, engine off.
    init(measureOpen: Bool = false, iconPreview: Bool = false) {
        self.measureOpen = measureOpen
        self.iconPreview = iconPreview
        model = MixerModel(engineEnabled: !(measureOpen || iconPreview))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wider than the default square item so it's an easier click target.
        statusItem = NSStatusBar.system.statusItem(withLength: 32)
        if let button = statusItem.button {
            button.image = Self.statusIcon()
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Open on mouse *down*, like the system's menu bar items (mouse-up adds the whole click duration).
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        let host = NSHostingController(rootView: MixerPanel(model: model))
        host.sizingOptions = [.preferredContentSize]   // popover follows the SwiftUI content size
        popover.contentViewController = host
        popover.behavior = .transient                   // closes when clicking elsewhere
        popover.animates = false                        // appear on the next frame, no zoom-in delay
        popover.delegate = self
        warmUp()

        if measureOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.runOpenBenchmark() }
        }
        if iconPreview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
        }
    }

    /// Menu bar glyph: bigger and heavier than a plain symbol, nudged down so it sits on the same
    /// optical baseline as the system icons. Tunable without rebuilding (then restart AppMixer):
    ///   defaults write dev.appmixer.AppMixer iconPointSize -float 18
    ///   defaults write dev.appmixer.AppMixer iconOffsetY -float 0.5    # points downward (negative = up)
    ///   defaults write dev.appmixer.AppMixer iconWeight semibold       # regular|medium|semibold|bold|heavy
    static func statusIcon() -> NSImage {
        let defaults = UserDefaults.standard
        let pointSize = CGFloat(defaults.object(forKey: "iconPointSize") as? Double ?? 17)
        // Measured on macOS 26: at 17 pt with no offset the glyph sits ~0.5 pt below the system icons
        // (Wi-Fi, Control Center), so the default lifts it by 0.5 pt to share their centre line.
        let offsetY = CGFloat(defaults.object(forKey: "iconOffsetY") as? Double ?? -0.5)
        let weight: NSFont.Weight = switch defaults.string(forKey: "iconWeight") ?? "semibold" {
        case "regular": .regular
        case "medium": .medium
        case "bold": .bold
        case "heavy": .heavy
        default: .semibold
        }

        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "AppMixer")?
            .withSymbolConfiguration(config) else { return NSImage() }

        // The button centres its image vertically, so extra transparent space above the glyph moves it
        // down by half that amount (and a negative offset moves it up).
        let glyph = symbol.size
        let pad = abs(offsetY) * 2
        let image = NSImage(size: NSSize(width: glyph.width, height: glyph.height + pad), flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: offsetY >= 0 ? 0 : pad, width: glyph.width, height: glyph.height))
            return true
        }
        image.isTemplate = true   // tinted by the system for light/dark menu bars
        image.accessibilityDescription = "AppMixer"
        return image
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // A transient popover closes itself on the same mouse-down that hits the icon; don't reopen it.
        if Date().timeIntervalSince(lastClose) < 0.3 { return }
        openTimings = []
        // No refresh here: Core Audio listeners keep the list current, and changing state right before
        // showing would make SwiftUI re-layout in the middle of the opening animation.
        timed("layout") { layoutPanel() }
        timed("show") { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        timed("activate") { NSApp.activate() }
        timed("makeKey") { popover.contentViewController?.view.window?.makeKey() }
    }

    /// Lay the SwiftUI panel out and size the popover *before* it animates in, so the animation
    /// doesn't run while SwiftUI is doing its first layout or the popover is resizing.
    private func layoutPanel() {
        guard let view = popover.contentViewController?.view else { return }
        let size = view.fittingSize
        if view.frame.size != size { view.setFrameSize(size) }
        view.layoutSubtreeIfNeeded()
        if popover.contentSize != size { popover.contentSize = size }
    }

    /// Build the SwiftUI view tree at launch instead of on the first click.
    private func warmUp() {
        guard let view = popover.contentViewController?.view else { return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        layoutPanel()
        view.displayIfNeeded()
        window.contentView = nil
    }

    private func timed(_ label: String, _ body: () -> Void) {
        guard measureOpen else { body(); return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        openTimings.append((label, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6))
    }

    // MARK: - Dev benchmark

    private func runOpenBenchmark() {
        let savedShowAll = model.showAll
        let plan: [Bool] = [false, false, false, true, true, true]   // idle hidden ×3, idle shown ×3
        var index = 0

        func next() {
            guard index < plan.count, let button = statusItem.button else {
                model.showAll = savedShowAll
                NSApp.terminate(nil)
                return
            }
            model.showAll = plan[index]
            model.refreshNow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let probe = StallProbe()
                probe.start()
                self.togglePopover(button)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let r = probe.stop()
                    let phases = self.openTimings.map { String(format: "%@ %.1f", $0.0, $0.1) }.joined(separator: ", ")
                    let size = self.popover.contentSize
                    print(String(format: "open #%d idle=%@ size=%.0fx%.0f | longest main-thread stall %.1f ms, frames >8.3ms: %d | %@",
                                 index + 1, plan[index] ? "on " : "off", size.width, size.height,
                                 r.maxGap, r.slowFrames, phases))
                    fflush(stdout)
                    self.popover.performClose(nil)
                    self.lastClose = .distantPast
                    index += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
                }
            }
        }
        next()
    }


    private func showContextMenu() {
        if popover.isShown { popover.performClose(nil) }
        model.refreshNow()

        let menu = NSMenu()
        menu.delegate = self
        let mute = menu.addItem(withTitle: model.isAllMuted ? "Unmute All" : "Mute All Playing Apps",
                                action: model.canToggleMuteAll ? #selector(muteAll) : nil, keyEquivalent: "")
        mute.image = NSImage(systemSymbolName: model.isAllMuted ? "speaker.wave.2" : "speaker.slash",
                             accessibilityDescription: nil)
        let reset = menu.addItem(withTitle: "Reset All to 100%",
                                 action: model.hasCustomizations ? #selector(resetAll) : nil, keyEquivalent: "")
        reset.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AppMixer", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = self }

        // Attach the menu only for this click so a normal left click still opens the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func popoverDidShow(_ notification: Notification) { model.setPanelVisible(true) }
    func popoverDidClose(_ notification: Notification) {
        lastClose = Date()
        model.setPanelVisible(false)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @objc private func muteAll() { model.toggleMuteAll() }
    @objc private func resetAll() { model.resetAll() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Measures main-thread responsiveness: a 1 ms timer (in common modes) records the longest gap between
/// fires, i.e. how long the main thread was blocked.
private final class StallProbe {
    private var timer: Timer?
    private var last: UInt64 = 0
    private(set) var maxGap: Double = 0
    private var slow = 0

    func start() {
        last = DispatchTime.now().uptimeNanoseconds
        let t = Timer(timeInterval: 0.001, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let gap = Double(now - last) / 1e6
        last = now
        maxGap = max(maxGap, gap)
        if gap > 8.3 { slow += 1 }
    }

    func stop() -> (maxGap: Double, slowFrames: Int) {
        tick()
        timer?.invalidate()
        return (maxGap, slow)
    }
}
