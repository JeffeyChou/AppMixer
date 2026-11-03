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
/// app never change, so they are resolved once and cached. With a `listenQueue`, each object's
/// `IsRunningOutput` is pushed to us by a Core Audio listener instead of being read on every scan, so a
/// warm scan is a single property read. Not thread-safe: use it only on `listenQueue`.
final class AudioProcessCatalog {
    private struct Owner {
        let key: String
        let name: String
        let pid: pid_t
        let isApp: Bool
    }

    /// Called on `listenQueue` when some process starts or stops playing.
    var onPlayingChange: (() -> Void)?

    /// nil owner = excluded (AppMixer itself).
    private var owners: [AudioObjectID: Owner?] = [:]
    private var playing: [AudioObjectID: Bool] = [:]
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private let listenQueue: DispatchQueue?
    private let excludedPID: pid_t
    private let excludedBundleID: String?
    private static var runningAddress = CA.address(kAudioProcessPropertyIsRunningOutput)

    init(listenQueue: DispatchQueue? = nil,
         excludingPID pid: pid_t = getpid(), bundleID: String? = Bundle.main.bundleIdentifier) {
        self.listenQueue = listenQueue
        excludedPID = pid
        excludedBundleID = bundleID
    }

    deinit {
        for (id, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(id, &Self.runningAddress, listenQueue, block)
        }
    }

    private static func readPlaying(_ id: AudioObjectID) -> Bool {
        ((try? CA.get(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
    }

    /// Cached when a listener keeps it current; otherwise read now.
    private func isPlaying(_ id: AudioObjectID) -> Bool {
        if listeners[id] != nil, let cached = playing[id] { return cached }
        return Self.readPlaying(id)
    }

    private func startListening(_ id: AudioObjectID) {
        guard let listenQueue else { return }
        playing[id] = Self.readPlaying(id)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.listeners[id] != nil else { return }
            let now = Self.readPlaying(id)
            if self.playing[id] != now {
                self.playing[id] = now
                self.onPlayingChange?()
            }
        }
        if AudioObjectAddPropertyListenerBlock(id, &Self.runningAddress, listenQueue, block) == noErr {
            listeners[id] = block
        }
    }

    private func forget(_ id: AudioObjectID) {
        if let block = listeners.removeValue(forKey: id) {
            AudioObjectRemovePropertyListenerBlock(id, &Self.runningAddress, listenQueue, block)
        }
        playing[id] = nil
        owners[id] = nil
    }

    func scan() -> [AudioApp] {
        guard let ids = try? CA.getObjectIDs(CA.systemObject, kAudioHardwarePropertyProcessObjectList) else { return [] }
        let live = Set(ids)
        for id in Array(owners.keys) where !live.contains(id) { forget(id) }

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

            let playing = isPlaying(id)
            if var app = byKey[owner.key] {
                app.objectIDs.append(id)
                app.isPlaying = app.isPlaying || playing
                byKey[owner.key] = app
            } else {
                byKey[owner.key] = AudioApp(id: owner.key, name: owner.name, pid: owner.pid,
                                            objectIDs: [id], isPlaying: playing, isApp: owner.isApp)
                order.append(owner.key)
            }
        }
        return order.compactMap { key in
            guard var app = byKey[key] else { return nil }
            app.objectIDs.sort()
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
