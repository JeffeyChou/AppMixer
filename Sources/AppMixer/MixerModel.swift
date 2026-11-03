import AppKit
import Combine
import CoreAudio

/// UI state: apps, per-app settings (volume, mute, EQ, output device), system output (device, volume,
/// Share Audio), permission. Lives on the main thread but keeps it light: process scanning runs on
/// `scanQueue`, taps are created/destroyed by `TapEngine` on its own queue, and state changes arrive
/// through Core Audio listeners instead of polling.
final class MixerModel: ObservableObject {
    static let maxVolume = 1.5   // slider range 0…150 %
    static let placeholderIcon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()

    // Apps
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var volumes: [String: Double]
    @Published private(set) var muted: Set<String>
    @Published private(set) var eqGains: [String: [Double]]
    @Published private(set) var eqOff: Set<String>          // curve kept, but bypassed
    @Published private(set) var appOutputs: [String: String] // app id → device UID (absent = system output)
    /// The app whose EQ editor is open. While the panel is visible that app is tapped (even at 100 % with
    /// EQ off) so its spectrum can be shown.
    @Published var expandedEQ: String? {
        didSet {
            guard expandedEQ != oldValue else { return }
            analyzers = analyzers.filter { $0.key == expandedEQ }
            pushTargets()
        }
    }
    @Published var showAll: Bool { didSet { if engineEnabled { defaults.set(showAll, forKey: Keys.showAll) } } }

    // System output
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var systemDeviceUID: String?    // the physical device behind the system output
    @Published private(set) var shareUIDs: [String] = []    // extra devices while Share Audio is on
    @Published private(set) var systemVolume: Float?        // nil = device has no volume control
    @Published private(set) var systemMuted = false
    @Published private(set) var outputError: String?

    @Published private(set) var permission: AudioCapturePermission.Status

    private let defaults = UserDefaults.standard
    private let engine = TapEngine()
    private let scanQueue: DispatchQueue
    private let catalog: AudioProcessCatalog   // used only on scanQueue
    private var scanInFlight = false
    private var scanAgain = false
    private var icons: [String: NSImage] = [:]
    private var defaultDevice = CA.unknown
    private var shareDeviceID: AudioDeviceID?
    private var shareMainUID: String?
    private var shareActivating = false   // share device created, not yet the default output
    /// Apps that kept playing on the previous system output after it changed (they don't follow the
    /// default device by themselves, e.g. Zoom during a call). AppMixer routes them to the system output.
    private var followers: Set<String> = []
    private var followCheck: DispatchWorkItem?
    /// Bluetooth headphones (AirPods etc.) are "transient" devices for coreaudiod: whenever audio is
    /// active on them it prefers them as the default output, input and alert device, and re-applies that
    /// on every device change — including while AppMixer plays a single app there. While an app is routed
    /// to a device, such automatic switches of the system defaults to that device are undone.
    private struct SystemDefaults: Equatable { var output, input, sound: AudioDeviceID }
    private var knownDefaults = SystemDefaults(output: CA.unknown, input: CA.unknown, sound: CA.unknown)
    private var userPickedOutput: (uid: String, at: Date)?
    private var hardwareFirstSeen: [String: Date] = [:]   // hardware base → when it (re)connected
    private var undoTimes: [Date] = []
    private var volumeListener: (device: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?
    private var lastLocalVolumeChange = Date.distantPast
    private var requestingPermission = false
    private var pollTimer: Timer?
    private var panelVisible = false
    private var analyzers: [String: SpectrumAnalyzer] = [:]
    /// `--snapshot --demo` only: a ring filled with synthetic audio so the spectrum can be previewed.
    var demoRing: AnalysisRing?
    private var saveWork: DispatchWorkItem?
    /// false = UI-only model (`--snapshot`, benchmarks): never creates taps, changes devices, asks for
    /// permission or writes settings.
    private let engineEnabled: Bool

    private enum Keys {
        static let volumes = "volumes", muted = "muted", showAll = "showAll"
        static let eq = "eq", eqOff = "eqOff", outputs = "outputs"
    }

    init(engineEnabled: Bool = true) {
        self.engineEnabled = engineEnabled
        volumes = (defaults.dictionary(forKey: Keys.volumes) as? [String: Double]) ?? [:]
        muted = Set(defaults.stringArray(forKey: Keys.muted) ?? [])
        eqGains = (defaults.dictionary(forKey: Keys.eq) as? [String: [Double]]) ?? [:]
        eqOff = Set(defaults.stringArray(forKey: Keys.eqOff) ?? [])
        appOutputs = (defaults.dictionary(forKey: Keys.outputs) as? [String: String]) ?? [:]
        showAll = defaults.bool(forKey: Keys.showAll)
        permission = AudioCapturePermission.status()
        let queue = DispatchQueue(label: "AppMixer.scan", qos: .userInitiated)
        scanQueue = queue
        // "Is playing" changes are pushed by Core Audio listeners, so no polling is needed.
        catalog = AudioProcessCatalog(listenQueue: queue)
        catalog.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }

        if engineEnabled { adoptOrRemoveLeftoverShareDevices() }
        reloadDevices()
        refreshNow()
        guard engineEnabled else { return }

        knownDefaults = SystemDefaults(output: AudioDevices.defaultOutput() ?? CA.unknown,
                                       input: AudioDevices.defaultInput(), sound: AudioDevices.defaultSystemSound())
        engine.onError = { [weak self] id, message in
            guard let self, self.errors[id] != message else { return }
            self.errors[id] = message
        }
        installListeners()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.saveNow()
            self.engine.shutdown()
            self.stopSharing()
        }
    }

    // MARK: - Queries for the UI

    /// Apps producing sound right now.
    var playingApps: [AudioApp] {
        sortedForDisplay(apps.filter(\.isPlaying))
    }

    /// Silent apps: always the ones with custom settings, plus everything else when "show idle" is on.
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
    func eq(_ id: String) -> [Double] { eqGains[id] ?? EQ.flat }
    func isEQOn(_ id: String) -> Bool { !eqOff.contains(id) }
    func isEQActive(_ id: String) -> Bool { isEQOn(id) && !EQ.isFlat(eq(id)) }

    func isCustomized(_ id: String) -> Bool {
        volumes[id] != nil || muted.contains(id) || eqGains[id] != nil || appOutputs[id] != nil
    }

    var hasCustomizations: Bool {
        !volumes.isEmpty || !muted.isEmpty || !eqGains.isEmpty || !appOutputs.isEmpty
    }

    /// True when the "mute all" toggle is engaged: something is muted and nothing audible is left unmuted.
    var isAllMuted: Bool {
        !muted.isEmpty && apps.filter(\.isPlaying).allSatisfy { muted.contains($0.id) }
    }

    var canToggleMuteAll: Bool { isAllMuted || apps.contains(where: \.isPlaying) }

    func icon(for app: AudioApp) -> NSImage { icons[app.id] ?? Self.placeholderIcon }

    func device(uid: String?) -> OutputDevice? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    var systemDevice: OutputDevice? { device(uid: systemDeviceUID) }
    var isSharing: Bool { !shareUIDs.isEmpty }

    /// "MacBook Pro Speakers" or "MacBook Pro Speakers + AirPods Pro".
    var systemOutputName: String {
        let main = systemDevice?.name ?? "No output device"
        let extras = shareUIDs.compactMap { device(uid: $0)?.name }
        return ([main] + extras).joined(separator: " + ")
    }

    /// The device an app is routed to, if it isn't simply following the system output.
    func routedDevice(_ id: String) -> OutputDevice? {
        guard let uid = appOutputs[id], let d = device(uid: uid), d.uid != systemDeviceUID || isSharing else { return nil }
        return d
    }

    // MARK: - Spectrum

    /// Post-EQ audio of an app's tap, if it is currently tapped.
    func analysisRing(_ id: String) -> AnalysisRing? {
        demoRing ?? engine.analysisRing(for: id)
    }

    /// One analyser, kept only for the open EQ editor.
    func spectrumAnalyzer(for id: String) -> SpectrumAnalyzer {
        if let a = analyzers[id] { return a }
        let a = SpectrumAnalyzer()
        analyzers[id] = a
        return a
    }

    // MARK: - Per-app actions

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

    /// Everything for this app back to default: 100 %, unmuted, EQ flat, system output.
    func reset(_ id: String) {
        volumes[id] = nil
        muted.remove(id)
        eqGains[id] = nil
        eqOff.remove(id)
        appOutputs[id] = nil
        if expandedEQ == id { expandedEQ = nil }
        userChanged([id])
    }

    func setOutput(_ uid: String?, for id: String) {
        guard appOutputs[id] != uid else { return }
        appOutputs[id] = uid
        userChanged([id])
    }

    func toggleEQExpanded(_ id: String) {
        expandedEQ = (expandedEQ == id) ? nil : id
    }

    func setEQBand(_ band: Int, gain: Double, for id: String) {
        var gains = eq(id)
        let g = (min(max(gain, -EQ.maxGain), EQ.maxGain) * 2).rounded() / 2   // 0.5 dB steps
        guard band >= 0, band < gains.count, gains[band] != g else { return }
        gains[band] = g
        setEQ(gains, for: id)
    }

    func setEQ(_ gains: [Double], for id: String) {
        eqGains[id] = EQ.isFlat(gains) ? nil : gains
        eqOff.remove(id)
        userChanged([id])
    }

    func toggleEQOn(_ id: String) {
        if eqOff.contains(id) { eqOff.remove(id) } else { eqOff.insert(id) }
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

    /// One click: every app back to defaults (100 %, unmuted, EQ flat, system output).
    func resetAll() {
        volumes.removeAll()
        muted.removeAll()
        eqGains.removeAll()
        eqOff.removeAll()
        appOutputs.removeAll()
        expandedEQ = nil
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
        if panelVisible != visible {
            panelVisible = visible
            if expandedEQ != nil { pushTargets() }
        }
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

    // MARK: - System output

    func selectSystemOutput(_ uid: String) {
        guard engineEnabled, let target = device(uid: uid) else { return }
        userPickedOutput = (uid, Date())
        if isSharing { stopSharing() }
        if !AudioDevices.setDefaultOutput(target.id) { outputError = "Couldn't switch to \(target.name)" }
        refresh()
    }

    /// Adds/removes `uid` from the devices that also play the system output.
    func toggleShare(_ uid: String) {
        guard engineEnabled else { return }
        var extras = shareUIDs
        if let i = extras.firstIndex(of: uid) { extras.remove(at: i) } else { extras.append(uid) }
        applyShare(extras)
    }

    func stopSharing() {
        guard shareDeviceID != nil || isSharing else { return }
        applyShare([])
    }

    func setSystemVolume(_ value: Float) {
        guard engineEnabled else { return }
        let v = min(max(value, 0), 1)
        systemVolume = v
        lastLocalVolumeChange = Date()
        for id in systemPhysicalDeviceIDs() { AudioDevices.setVolume(id, v) }
        if systemMuted && v > 0 { toggleSystemMute() }
    }

    func toggleSystemMute() {
        guard engineEnabled else { return }
        let m = !systemMuted
        systemMuted = m
        lastLocalVolumeChange = Date()
        for id in systemPhysicalDeviceIDs() { AudioDevices.setMuted(id, m) }
    }

    private func systemPhysicalDeviceIDs() -> [AudioDeviceID] {
        systemOutputUIDs().compactMap { device(uid: $0)?.id }
    }

    /// Where "System Output" really plays: the default device, or the share members while sharing.
    private func systemOutputUIDs() -> [String] {
        if let shareDeviceID, defaultDevice == shareDeviceID, let shareMainUID {
            return [shareMainUID] + shareUIDs
        }
        return systemDeviceUID.map { [$0] } ?? []
    }

    private func applyShare(_ extras: [String]) {
        outputError = nil
        let mainUID = shareMainUID ?? systemDeviceUID
        let old = shareDeviceID
        if extras.isEmpty {
            if let mainUID, let main = device(uid: mainUID) { AudioDevices.setDefaultOutput(main.id) }
            if let old { AudioDevices.destroyAggregate(old) }
            shareDeviceID = nil
            shareMainUID = nil
            shareUIDs = []
        } else if let mainUID {
            do {
                let new = try AudioDevices.createShareDevice(mainUID: mainUID, extraUIDs: extras)
                shareDeviceID = new
                shareMainUID = mainUID
                shareUIDs = extras
                shareActivating = true
                makeDefault(new, attemptsLeft: 5)
                if let old { AudioDevices.destroyAggregate(old) }
            } catch {
                outputError = "Share Audio failed: \(error)"
            }
        }
        reloadDevices()
        refresh()
    }

    /// A freshly created aggregate can take a moment before it accepts becoming the default.
    private func makeDefault(_ id: AudioDeviceID, attemptsLeft: Int) {
        if AudioDevices.setDefaultOutput(id) {
            shareActivating = false
            updateSystemOutput()
            return
        }
        guard attemptsLeft > 0 else {
            shareActivating = false
            outputError = "Couldn't switch to the shared output"
            stopSharing()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.makeDefault(id, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// After a crash the share device may still exist. Keep it if it's the current output, else remove it.
    private func adoptOrRemoveLeftoverShareDevices() {
        let current = AudioDevices.defaultOutput()
        for id in AudioDevices.existingShareDevices() {
            let members = AudioDevices.subdeviceUIDs(of: id)
            if id == current, let main = members.first, members.count > 1 {
                shareDeviceID = id
                shareMainUID = main
                shareUIDs = Array(members.dropFirst())
            } else {
                AudioDevices.destroyAggregate(id)
            }
        }
    }

    private func reloadDevices() {
        let list = AudioDevices.outputDevices()
        if list != devices { devices = list }
        let bases = Set(list.map { AudioDevices.hardwareBase($0.uid) })
        hardwareFirstSeen = hardwareFirstSeen.filter { bases.contains($0.key) }   // disconnected → forget
        for base in bases where hardwareFirstSeen[base] == nil { hardwareFirstSeen[base] = Date() }
        // A shared member that disappeared (headphones switched off) ends sharing for it.
        let available = Set(list.map(\.uid))
        if isSharing, engineEnabled, shareUIDs.contains(where: { !available.contains($0) }) {
            applyShare(shareUIDs.filter { available.contains($0) })
            return
        }
        systemDefaultsChanged()   // device changes also make coreaudiod re-pick defaults
    }

    private func updateSystemOutput() {
        let current = AudioDevices.defaultOutput() ?? CA.unknown
        let previous = defaultDevice
        defaultDevice = current
        if engineEnabled, previous != CA.unknown, current != CA.unknown, previous != current {
            scheduleFollowCheck(previous: previous, current: current)
        }
        let uid: String?
        if let shareDeviceID, current == shareDeviceID {
            uid = shareMainUID
        } else {
            uid = AudioDevices.uid(current)
            if engineEnabled, !shareActivating, let old = shareDeviceID, isSharing {
                // The user picked another output elsewhere (e.g. Control Center): sharing is over.
                AudioDevices.destroyAggregate(old)
                shareDeviceID = nil
                shareMainUID = nil
                shareUIDs = []
            }
        }
        if uid != systemDeviceUID { systemDeviceUID = uid }
        bindVolumeListener()
        readSystemVolume()
        pushTargets()
    }

    /// Default output / input / alert device changed (by the user, macOS, or another app).
    private func systemDefaultsChanged() {
        let now = SystemDefaults(output: AudioDevices.defaultOutput() ?? CA.unknown,
                                 input: AudioDevices.defaultInput(), sound: AudioDevices.defaultSystemSound())
        if undoAutomaticSwitch(to: now) { return }
        knownDefaults = now
        updateSystemOutput()
    }

    /// Returns true when it put the previous defaults back.
    private func undoAutomaticSwitch(to now: SystemDefaults) -> Bool {
        guard engineEnabled else { return false }
        let routed = Set(apps.compactMap { routedDevice($0.id) }.map { AudioDevices.hardwareBase($0.uid) })
        guard !routed.isEmpty else { return false }
        let t = Date()
        undoTimes = undoTimes.filter { t.timeIntervalSince($0) < 15 }
        guard undoTimes.count < 4 else { return false }   // something keeps insisting: stop fighting

        func automatic(_ new: AudioDeviceID, _ old: AudioDeviceID) -> Bool {
            guard new != old, new != CA.unknown, old != CA.unknown, let uid = AudioDevices.uid(new) else { return false }
            let base = AudioDevices.hardwareBase(uid)
            guard routed.contains(base) else { return false }
            // The user chose it in AppMixer, or it just connected (macOS's normal "use headphones" switch).
            if let pick = userPickedOutput, AudioDevices.hardwareBase(pick.uid) == base,
               t.timeIntervalSince(pick.at) < 5 { return false }
            if let seen = hardwareFirstSeen[base], t.timeIntervalSince(seen) < 5 { return false }
            return true
        }
        var undone = false
        if automatic(now.output, knownDefaults.output) { AudioDevices.setDefaultOutput(knownDefaults.output); undone = true }
        if automatic(now.input, knownDefaults.input) { AudioDevices.setDefaultInput(knownDefaults.input); undone = true }
        if automatic(now.sound, knownDefaults.sound) { AudioDevices.setDefaultSystemSound(knownDefaults.sound); undone = true }
        if undone {
            undoTimes.append(t)
            NSLog("AppMixer: macOS switched the system defaults to a device an app is routed to; restored them")
        }
        return undone
    }

    /// Most apps move to the new system output on their own within a few hundred ms. Whatever is still
    /// playing on the *previous* system output after that didn't follow, so AppMixer takes it along.
    /// Apps playing to some other device (e.g. a virtual device on purpose) are left alone.
    private func scheduleFollowCheck(previous: AudioDeviceID, current: AudioDeviceID) {
        followCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.defaultDevice == current else { return }
            let stuck = self.apps.filter {
                $0.isPlaying && self.appOutputs[$0.id] == nil
                    && $0.outputDevices.contains(previous) && !$0.outputDevices.contains(current)
            }.map(\.id)
            guard !stuck.isEmpty else { return }
            self.followers.formUnion(stuck)
            self.pushTargets(retry: Set(stuck))
        }
        followCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Following app whose own device isn't the system output: AppMixer plays it on the system output.
    private func needsFollow(_ app: AudioApp) -> Bool {
        followers.contains(app.id) && appOutputs[app.id] == nil && !app.outputDevices.contains(defaultDevice)
    }

    private func readSystemVolume() {
        guard let main = systemPhysicalDeviceIDs().first else {
            if systemVolume != nil { systemVolume = nil }
            return
        }
        let v = AudioDevices.volume(main)
        if v != systemVolume { systemVolume = v }
        let m = AudioDevices.isMuted(main) ?? false
        if m != systemMuted { systemMuted = m }
    }

    /// Follow volume-key / Control Center changes of the current output device.
    private func bindVolumeListener() {
        guard engineEnabled else { return }
        let main = systemPhysicalDeviceIDs().first
        if volumeListener?.device == main { return }
        if let old = volumeListener {
            for selector in [AudioDevices.virtualMainVolume, kAudioDevicePropertyMute] {
                var addr = CA.address(selector, scope: kAudioObjectPropertyScopeOutput)
                AudioObjectRemovePropertyListenerBlock(old.device, &addr, .main, old.block)
            }
            volumeListener = nil
        }
        guard let main else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, Date().timeIntervalSince(self.lastLocalVolumeChange) > 0.4 else { return }
            self.readSystemVolume()
        }
        for selector in [AudioDevices.virtualMainVolume, kAudioDevicePropertyMute] {
            var addr = CA.address(selector, scope: kAudioObjectPropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(main, &addr, .main, block)
        }
        volumeListener = (main, block)
    }

    // MARK: - Scanning

    /// Scan in the background; results are applied on the main queue. Overlapping requests collapse.
    func refresh() {
        guard !scanInFlight else { scanAgain = true; return }
        scanInFlight = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let result = self.catalog.scan()
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

    /// Synchronous scan, for moments that need fresh data right now (the right-click menu).
    func refreshNow() {
        apply(scanQueue.sync { catalog.scan() })
    }

    private func apply(_ found: [AudioApp]) {
        for app in found where app.isApp && icons[app.id] == nil {
            icons[app.id] = NSRunningApplication(processIdentifier: app.pid)?.icon
        }
        if found != apps { apps = found }
        if !followers.isEmpty { followers.formIntersection(found.map(\.id)) }   // forget apps that quit
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

    /// Sends the desired state of every live app to the engine (cheap; the engine diffs).
    private func pushTargets(retry: Set<String> = [], retryAll: Bool = false) {
        guard engineEnabled else { return }
        let systemUIDs = systemOutputUIDs()
        var targets: [String: TapEngine.Target] = [:]
        var wantsTap = false
        for app in apps {
            let g = gain(app.id)
            let eq = isEQActive(app.id) ? eq(app.id) : nil
            var outputs = systemUIDs
            var routed = false
            if let d = routedDevice(app.id), [d.uid] != systemUIDs {
                outputs = [d.uid]
                routed = true
            } else if needsFollow(app) {
                routed = true   // outputs stay = system output
            }
            let analyzing = panelVisible && expandedEQ == app.id
            let needs = abs(g - 1) > 0.0001 || eq != nil || routed || analyzing
            wantsTap = wantsTap || needs
            targets[app.id] = TapEngine.Target(name: app.name, objectIDs: app.objectIDs, gain: g, eq: eq,
                                               outputUIDs: outputs, needsTap: needs)
        }
        guard !wantsTap || ensurePermission() else {
            engine.update(targets: [:])
            return
        }
        engine.update(targets: targets, retry: retry, retryAll: retryAll)
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
        var address = CA.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(CA.systemObject, &address, .main) { [weak self] _, _ in
            self?.refresh()
        }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultSystemOutputDevice] {
            address = CA.address(selector)
            AudioObjectAddPropertyListenerBlock(CA.systemObject, &address, .main) { [weak self] _, _ in
                self?.systemDefaultsChanged()
            }
        }
        address = CA.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(CA.systemObject, &address, .main) { [weak self] _, _ in
            self?.reloadDevices()
        }
    }

    // MARK: - Persistence (debounced: a slider drag fires dozens of changes per second)

    private func scheduleSave() {
        guard engineEnabled else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        guard engineEnabled else { return }
        saveWork?.cancel()
        saveWork = nil
        defaults.set(volumes, forKey: Keys.volumes)
        defaults.set(Array(muted), forKey: Keys.muted)
        defaults.set(eqGains, forKey: Keys.eq)
        defaults.set(Array(eqOff), forKey: Keys.eqOff)
        defaults.set(appOutputs, forKey: Keys.outputs)
    }
}
