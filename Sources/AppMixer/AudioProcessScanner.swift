import AppKit
import CoreAudio
import Darwin

/// One Core Audio client process (kAudioHardwarePropertyProcessObjectList entry).
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

/// Audio processes grouped under the app the user sees (Chrome + its helpers, Safari + WebKit GPU process, ...).
struct AudioApp: Identifiable, Equatable {
    let id: String          // grouping key; also the key volumes are saved under
    let name: String
    let pid: pid_t          // pid of the owning app, used for the icon
    var objectIDs: [AudioObjectID]
    var isPlaying: Bool
    let isApp: Bool         // owned by a real .app bundle (has a proper icon), not a bare daemon
    var outputDevices: [AudioDeviceID] = []   // devices the app's processes are playing to right now
}

enum AudioProcessScanner {
    static func scan() -> [AudioProcess] {
        guard let ids = try? CA.getObjectIDs(CA.systemObject, kAudioHardwarePropertyProcessObjectList) else { return [] }
        return ids.compactMap { id -> AudioProcess? in
            guard let pid = try? CA.get(id, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { return nil }
            let bundle = (try? CA.getString(id, kAudioProcessPropertyBundleID)) ?? nil
            let running = (try? CA.get(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcess(objectID: id, pid: pid,
                                bundleID: (bundle?.isEmpty ?? true) ? nil : bundle,
                                isRunningOutput: running != 0)
        }
    }

    static func group(_ processes: [AudioProcess]) -> [AudioApp] {
        let runningApps = NSWorkspace.shared.runningApplications
        var byKey: [String: AudioApp] = [:]
        var order: [String] = []

        for p in processes {
            let owner = owningApp(for: p, runningApps: runningApps)
            let key = owner?.bundleIdentifier ?? p.bundleID ?? "pid:\(p.pid)"
            if var app = byKey[key] {
                app.objectIDs.append(p.objectID)
                app.isPlaying = app.isPlaying || p.isRunningOutput
                byKey[key] = app
            } else {
                let isApp = owner?.bundleURL?.pathExtension == "app"
                let name = isApp
                    ? (owner?.localizedName ?? p.bundleID ?? "PID \(p.pid)")
                    : (processName(p.pid) ?? owner?.localizedName ?? p.bundleID ?? "PID \(p.pid)")
                byKey[key] = AudioApp(id: key, name: name, pid: owner?.processIdentifier ?? p.pid,
                                      objectIDs: [p.objectID], isPlaying: p.isRunningOutput, isApp: isApp)
                order.append(key)
            }
        }
        return order.compactMap { key in
            guard var app = byKey[key] else { return nil }
            app.objectIDs.sort()
            return app
        }
    }

    /// Find the GUI app that "owns" an audio process. Browsers play audio from helper/XPC processes,
    /// so we ask the kernel who is responsible for the pid, then fall back to bundle-ID prefixes.
    static func owningApp(for p: AudioProcess, runningApps: [NSRunningApplication]) -> NSRunningApplication? {
        if let rpid = Responsibility.responsiblePID(for: p.pid),
           let app = NSRunningApplication(processIdentifier: rpid), app.bundleIdentifier != nil {
            return app
        }
        if let app = NSRunningApplication(processIdentifier: p.pid), app.bundleIdentifier != nil {
            return app
        }
        if let bid = p.bundleID {
            // e.g. com.google.Chrome.helper -> com.google.Chrome
            return runningApps
                .filter { app in app.bundleIdentifier.map { bid.hasPrefix($0 + ".") } ?? false }
                .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
        }
        return nil
    }

    static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}

/// Incremental version of scan()+group() used by the app. A process object's pid, bundle ID and owning
/// app never change, so they are resolved once and cached. With a `listenQueue`, each object's playing
/// state and output devices are refreshed from Core Audio notifications instead of being read on every
/// scan, so a warm scan is a single property read. Not thread-safe: use it only on `listenQueue`.
///
/// Note: Core Audio does not notify `IsRunningOutput` changes for other processes' objects, but it does
/// notify `IsRunning` and `Devices`; we listen to those and re-read `IsRunningOutput` (verified with
/// a test player that starts and stops output).
final class AudioProcessCatalog {
    private struct Owner {
        let key: String
        let name: String
        let pid: pid_t
        let isApp: Bool
    }

    private struct LiveState: Equatable {
        var playing: Bool
        var devices: [AudioDeviceID]
    }

    /// Called on `listenQueue` when a process starts/stops playing or changes output device.
    var onChange: (() -> Void)?

    /// nil owner = excluded (AppMixer itself).
    private var owners: [AudioObjectID: Owner?] = [:]
    private var live: [AudioObjectID: LiveState] = [:]
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private let listenQueue: DispatchQueue?
    private let excludedPID: pid_t
    private let excludedBundleID: String?
    private static let watchedAddresses = [
        CA.address(kAudioProcessPropertyIsRunning),
        CA.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput),
    ]

    init(listenQueue: DispatchQueue? = nil,
         excludingPID pid: pid_t = getpid(), bundleID: String? = Bundle.main.bundleIdentifier) {
        self.listenQueue = listenQueue
        excludedPID = pid
        excludedBundleID = bundleID
    }

    deinit {
        for (id, block) in listeners { removeListeners(id, block) }
    }

    private static func read(_ id: AudioObjectID) -> LiveState {
        let playing = ((try? CA.get(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
        var addr = CA.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        var devices: [AudioDeviceID] = []
        if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 {
            devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &devices) != noErr { devices = [] }
        }
        return LiveState(playing: playing, devices: devices.sorted())
    }

    /// Cached when listeners keep it current; otherwise read now.
    private func state(_ id: AudioObjectID) -> LiveState {
        if listeners[id] != nil, let cached = live[id] { return cached }
        return Self.read(id)
    }

    private func startListening(_ id: AudioObjectID) {
        guard let listenQueue else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.listeners[id] != nil else { return }
            let now = Self.read(id)
            if self.live[id] != now {
                self.live[id] = now
                self.onChange?()
            }
        }
        var ok = true
        for var addr in Self.watchedAddresses {
            ok = ok && AudioObjectAddPropertyListenerBlock(id, &addr, listenQueue, block) == noErr
        }
        if ok {
            listeners[id] = block
        } else {
            removeListeners(id, block)
        }
        // Read after subscribing so a change in between can't be missed (callbacks run on this queue).
        live[id] = Self.read(id)
    }

    private func removeListeners(_ id: AudioObjectID, _ block: @escaping AudioObjectPropertyListenerBlock) {
        for var addr in Self.watchedAddresses {
            AudioObjectRemovePropertyListenerBlock(id, &addr, listenQueue, block)
        }
    }

    private func forget(_ id: AudioObjectID) {
        if let block = listeners.removeValue(forKey: id) { removeListeners(id, block) }
        live[id] = nil
        owners[id] = nil
    }

    func scan() -> [AudioApp] {
        guard let ids = try? CA.getObjectIDs(CA.systemObject, kAudioHardwarePropertyProcessObjectList) else { return [] }
        let present = Set(ids)
        for id in Array(owners.keys) where !present.contains(id) { forget(id) }

        var runningApps: [NSRunningApplication]?   // only fetched when a new process shows up
        var byKey: [String: AudioApp] = [:]
        var order: [String] = []

        for id in ids {
            let owner: Owner?
            if let cached = owners[id] {
                owner = cached
            } else {
                guard let pid = try? CA.get(id, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { continue }
                let raw = (try? CA.getString(id, kAudioProcessPropertyBundleID)) ?? nil
                let bundle = (raw?.isEmpty ?? true) ? nil : raw
                if pid == excludedPID || (excludedBundleID != nil && bundle == excludedBundleID) {
                    owner = nil
                } else {
                    if runningApps == nil { runningApps = NSWorkspace.shared.runningApplications }
                    owner = Self.resolveOwner(pid: pid, bundleID: bundle, runningApps: runningApps!)
                }
                owners[id] = .some(owner)
                if owner != nil { startListening(id) }
            }
            guard let owner else { continue }

            let st = state(id)
            if var app = byKey[owner.key] {
                app.objectIDs.append(id)
                app.isPlaying = app.isPlaying || st.playing
                app.outputDevices += st.devices
                byKey[owner.key] = app
            } else {
                byKey[owner.key] = AudioApp(id: owner.key, name: owner.name, pid: owner.pid,
                                            objectIDs: [id], isPlaying: st.playing, isApp: owner.isApp,
                                            outputDevices: st.devices)
                order.append(owner.key)
            }
        }
        return order.compactMap { key in
            guard var app = byKey[key] else { return nil }
            app.objectIDs.sort()
            app.outputDevices = Array(Set(app.outputDevices)).sorted()
            return app
        }
    }

    private static func resolveOwner(pid: pid_t, bundleID: String?, runningApps: [NSRunningApplication]) -> Owner {
        let p = AudioProcess(objectID: CA.unknown, pid: pid, bundleID: bundleID, isRunningOutput: false)
        let app = AudioProcessScanner.owningApp(for: p, runningApps: runningApps)
        let isApp = app?.bundleURL?.pathExtension == "app"
        let name = isApp
            ? (app?.localizedName ?? bundleID ?? "PID \(pid)")
            : (AudioProcessScanner.processName(pid) ?? app?.localizedName ?? bundleID ?? "PID \(pid)")
        return Owner(key: app?.bundleIdentifier ?? bundleID ?? "pid:\(pid)", name: name,
                     pid: app?.processIdentifier ?? pid, isApp: isApp)
    }
}

/// `responsibility_get_pid_responsible_for_pid` is a private libsystem symbol (what Activity Monitor
/// uses to attribute XPC helpers to their app). Looked up dynamically; if missing we just skip it.
enum Responsibility {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let fn else { return nil }
        let r = fn(pid)
        return r > 0 ? r : nil
    }
}
