import AppKit
import Combine
import CoreAudio

/// UI state: the app list, saved per-app volumes, permission. Lives on the main thread but keeps the
/// main thread light: process scanning runs on `scanQueue`, taps are created/destroyed by `TapEngine`
/// on its own queue, and the playing state is only polled while the panel is open.
final class MixerModel: ObservableObject {
    static let maxVolume = 1.5   // slider range 0…150 %
    static let placeholderIcon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var permission: AudioCapturePermission.Status
    @Published private(set) var outputName = ""
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var volumes: [String: Double]
    @Published private(set) var muted: Set<String>
    @Published var showAll: Bool { didSet { defaults.set(showAll, forKey: Keys.showAll) } }

    private let defaults = UserDefaults.standard
    private let engine = TapEngine()
    private let scanQueue: DispatchQueue
    private let catalog: AudioProcessCatalog   // used only on scanQueue
    private var scanInFlight = false
    private var scanAgain = false
    private var icons: [String: NSImage] = [:]
    private var outputDevice = CA.unknown
    private var requestingPermission = false
    private var pollTimer: Timer?
    private var saveWork: DispatchWorkItem?
    /// false = UI-only model (used by `--snapshot`): never creates taps, asks for permission or polls.
    private let engineEnabled: Bool

    private enum Keys {
        static let volumes = "volumes", muted = "muted", showAll = "showAll"
    }

    init(engineEnabled: Bool = true) {
        self.engineEnabled = engineEnabled
        volumes = (defaults.dictionary(forKey: Keys.volumes) as? [String: Double]) ?? [:]
        muted = Set(defaults.stringArray(forKey: Keys.muted) ?? [])
        showAll = defaults.bool(forKey: Keys.showAll)
        permission = AudioCapturePermission.status()
        let queue = DispatchQueue(label: "AppMixer.scan", qos: .userInitiated)
        scanQueue = queue
        // "Is playing" changes are pushed by Core Audio listeners, so no polling is needed.
        catalog = AudioProcessCatalog(listenQueue: queue)
        catalog.onPlayingChange = { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }

        refreshNow()
        guard engineEnabled else { return }

        engine.onError = { [weak self] id, message in
            guard let self, self.errors[id] != message else { return }
            self.errors[id] = message
        }
        installListeners()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.saveNow()
            self?.engine.shutdown()
        }
    }

    // MARK: - Queries for the UI

    /// Apps producing sound right now.
    var playingApps: [AudioApp] {
        sortedForDisplay(apps.filter(\.isPlaying))
    }

    /// Silent apps: always the ones with a custom volume/mute, plus everything else when "show idle" is on.
    var idleApps: [AudioApp] {
        sortedForDisplay(apps.filter { !$0.isPlaying && (showAll || isCustomized($0.id)) })
    }

    /// Real apps (with an icon) first, then background clients; each group by name.
    private func sortedForDisplay(_ list: [AudioApp]) -> [AudioApp] {
        list.sorted { a, b in
            if a.isApp != b.isApp { return a.isApp }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func volume(_ id: String) -> Double { volumes[id] ?? 1.0 }
    func isMuted(_ id: String) -> Bool { muted.contains(id) }
    func isCustomized(_ id: String) -> Bool { volumes[id] != nil || muted.contains(id) }

    var hasCustomizations: Bool { !volumes.isEmpty || !muted.isEmpty }

    /// True when the "mute all" toggle is engaged: something is muted and nothing audible is left unmuted.
    var isAllMuted: Bool {
        !muted.isEmpty && apps.filter(\.isPlaying).allSatisfy { muted.contains($0.id) }
    }

    var canToggleMuteAll: Bool { isAllMuted || apps.contains(where: \.isPlaying) }

    func icon(for app: AudioApp) -> NSImage { icons[app.id] ?? Self.placeholderIcon }

    // MARK: - Actions

    func setVolume(_ value: Double, for id: String) {
        var v = min(max(value, 0), Self.maxVolume)
        if abs(v - 1) < 0.03 { v = 1 }            // detent at 100 %
        let stored: Double? = (v == 1) ? nil : v
        guard volumes[id] != stored else { return }
        volumes[id] = stored
        userChanged([id])
    }

    func toggleMute(_ id: String) {
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        userChanged([id])
    }

    func reset(_ id: String) {
        volumes[id] = nil
        muted.remove(id)
        userChanged([id])
    }

    /// One click: mute every app that is currently playing; click again to unmute everything.
    func toggleMuteAll() {
        if isAllMuted {
            muted.removeAll()
        } else {
            muted.formUnion(apps.filter(\.isPlaying).map(\.id))
        }
        userChanged(nil)
    }

    /// One click: every app back to 100 %, unmuted, all taps removed.
    func resetAll() {
        volumes.removeAll()
        muted.removeAll()
        userChanged(nil)
    }

    func requestPermissionAgain() {
        permission = AudioCapturePermission.status()
        if permission == .denied { AudioCapturePermission.openSystemSettings() }
        pushTargets(retryAll: true)
    }

    /// Safety net while the panel is on screen, for any process whose listener couldn't be installed.
    /// (Normally Core Audio listeners push every change, and a scan costs a single property read.)
    func setPanelVisible(_ visible: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        guard visible, engineEnabled else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// `ids == nil` means "all apps".
    private func userChanged(_ ids: Set<String>?) {
        if let ids {
            for id in ids where errors[id] != nil { errors[id] = nil }
        } else if !errors.isEmpty {
            errors.removeAll()
        }
        scheduleSave()
        pushTargets(retry: ids ?? [], retryAll: ids == nil)
    }

    // MARK: - Scanning

    /// Scan in the background; results are applied on the main queue. Overlapping requests collapse.
    func refresh() {
        guard !scanInFlight else { scanAgain = true; return }
        scanInFlight = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let result = self.scanOnQueue()
            DispatchQueue.main.async {
                self.apply(result)
                self.scanInFlight = false
                if self.scanAgain {
                    self.scanAgain = false
                    self.refresh()
                }
            }
        }
    }

    /// Synchronous scan, for moments that need fresh data right now (opening the panel or the menu).
    func refreshNow() {
        apply(scanQueue.sync { scanOnQueue() })
    }

    private struct ScanResult {
        let apps: [AudioApp]
        let device: AudioDeviceID
        let deviceName: String
    }

    private func scanOnQueue() -> ScanResult {
        let device = (try? CA.defaultOutputDevice()) ?? CA.unknown
        let name = device == CA.unknown ? "No output device" : CA.name(device)
        return ScanResult(apps: catalog.scan(), device: device, deviceName: name)
    }

    private func apply(_ result: ScanResult) {
        if result.device != outputDevice { outputDevice = result.device }
        if result.deviceName != outputName { outputName = result.deviceName }
        for app in result.apps where app.isApp && icons[app.id] == nil {
            icons[app.id] = NSRunningApplication(processIdentifier: app.pid)?.icon
        }
        if result.apps != apps { apps = result.apps }
        if permission != .authorized && !requestingPermission {
            let s = AudioCapturePermission.status()
            if s != permission { permission = s }
        }
        pushTargets()
    }

    // MARK: - Engine

    private func gain(_ id: String) -> Float {
        if muted.contains(id) { return 0 }
        let v = Float(volume(id))
        return v * v   // perceptual-ish curve: 50 % ≈ -12 dB, 150 % ≈ +7 dB
    }

    /// Sends the desired gain of every live app to the engine (cheap; the engine diffs).
    private func pushTargets(retry: Set<String> = [], retryAll: Bool = false) {
        guard engineEnabled else { return }
        let wantsTap = apps.contains { abs(gain($0.id) - 1) > 0.0001 }
        guard !wantsTap || ensurePermission() else {
            engine.update(targets: [:], outputDevice: outputDevice)
            return
        }
        var targets: [String: TapEngine.Target] = [:]
        for app in apps {
            targets[app.id] = TapEngine.Target(name: app.name, objectIDs: app.objectIDs, gain: gain(app.id))
        }
        engine.update(targets: targets, outputDevice: outputDevice, retry: retry, retryAll: retryAll)
    }

    /// Never create a (muting) tap before "System Audio Recording" is granted.
    private func ensurePermission() -> Bool {
        switch permission {
        case .authorized, .unavailable:
            return true
        case .denied:
            return false
        case .notDetermined:
            if !requestingPermission {
                requestingPermission = true
                AudioCapturePermission.request { [weak self] granted in
                    guard let self else { return }
                    self.requestingPermission = false
                    self.permission = granted ? .authorized : .denied
                    self.pushTargets(retryAll: true)
                }
            }
            return false
        }
    }

    private func installListeners() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList] {
            var address = CA.address(selector)
            AudioObjectAddPropertyListenerBlock(CA.systemObject, &address, .main) { [weak self] _, _ in
                self?.refresh()
            }
        }
    }

    // MARK: - Persistence (debounced: a slider drag fires dozens of changes per second)

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        defaults.set(volumes, forKey: Keys.volumes)
        defaults.set(Array(muted), forKey: Keys.muted)
    }
}
