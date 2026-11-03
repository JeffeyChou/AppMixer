import CoreAudio
import Foundation

/// Owns the live process taps on its own serial queue. Creating or destroying a tap is a synchronous
/// round trip to coreaudiod (tens of ms), which must never run on the UI thread while a slider is
/// being dragged. The UI pushes the desired state with `update`; bursts of updates (slider drags)
/// are coalesced so only the latest state is applied.
final class TapEngine {
    struct Target: Equatable {
        let name: String
        let objectIDs: [AudioObjectID]
        let gain: Float
    }

    /// Called on the main queue with (app id, error text or nil when cleared).
    var onError: ((String, String?) -> Void)?

    /// A tap whose volume went back to 100 % is kept this long before teardown, so dragging the
    /// slider through 100 % doesn't destroy and rebuild it (each rebuild is an audible glitch).
    private static let unityGrace: TimeInterval = 3

    private let queue = DispatchQueue(label: "AppMixer.TapEngine", qos: .userInteractive)

    // Hand-off from the main thread (guarded by `lock`).
    private let lock = NSLock()
    private var pendingTargets: [String: Target]?
    private var pendingDevice = CA.unknown
    private var pendingRetry: Set<String> = []
    private var pendingRetryAll = false
    private var drainScheduled = false

    // Engine-queue state.
    private var targets: [String: Target] = [:]
    private var outputDevice = CA.unknown
    private var taps: [String: ProcessTap] = [:]
    private var failedSignature: [String: String] = [:]
    private var reportedError: [String: String] = [:]
    private var unitySince: [String: Date] = [:]
    private var graceCheckScheduled = false

    /// `targets`: every live app (including ones at 100 %). `retry`: ids whose previous failure should
    /// be retried (the user touched them).
    func update(targets: [String: Target], outputDevice: AudioDeviceID,
                retry: Set<String> = [], retryAll: Bool = false) {
        lock.lock()
        pendingTargets = targets
        pendingDevice = outputDevice
        pendingRetry.formUnion(retry)
        pendingRetryAll = pendingRetryAll || retryAll
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { queue.async { self.drain() } }
    }

    /// Synchronously removes every tap (app quit).
    func shutdown() {
        queue.sync {
            taps.values.forEach { $0.invalidate() }
            taps.removeAll()
        }
    }

    private func drain() {
        lock.lock()
        let newTargets = pendingTargets
        let device = pendingDevice
        let retry = pendingRetry
        let retryAll = pendingRetryAll
        pendingTargets = nil
        pendingRetry = []
        pendingRetryAll = false
        drainScheduled = false
        lock.unlock()

        if let newTargets { targets = newTargets }
        outputDevice = device
        if retryAll {
            failedSignature.removeAll()
            reportedError.removeAll()
        } else {
            for id in retry {
                failedSignature[id] = nil
                reportedError[id] = nil
            }
        }
        reconcile()
    }

    private func reconcile() {
        for id in Array(taps.keys) where targets[id] == nil || outputDevice == CA.unknown {
            remove(id)
        }
        guard outputDevice != CA.unknown else { return }

        let now = Date()
        for (id, target) in targets {
            if abs(target.gain - 1) < 0.0001 {
                guard let tap = taps[id] else { continue }
                tap.setGain(1)
                let since = unitySince[id] ?? now
                unitySince[id] = since
                if now.timeIntervalSince(since) >= Self.unityGrace {
                    remove(id)
                } else {
                    scheduleGraceCheck()
                }
                continue
            }
            unitySince[id] = nil

            let signature = ProcessTap.signature(objectIDs: target.objectIDs, outputDevice: outputDevice)
            if let tap = taps[id], tap.signature == signature {
                tap.setGain(target.gain)
                continue
            }
            if failedSignature[id] == signature { continue }   // don't hammer a broken setup

            remove(id)
            do {
                taps[id] = try ProcessTap(name: target.name, processObjectIDs: target.objectIDs,
                                          outputDevice: outputDevice, gain: target.gain)
                report(id, nil)
            } catch {
                failedSignature[id] = signature
                report(id, "\(error)")
                NSLog("AppMixer: tap for \(target.name) failed: \(error)")
            }
        }
    }

    private func remove(_ id: String) {
        taps.removeValue(forKey: id)?.invalidate()
        unitySince[id] = nil
    }

    private func scheduleGraceCheck() {
        guard !graceCheckScheduled else { return }
        graceCheckScheduled = true
        queue.asyncAfter(deadline: .now() + Self.unityGrace + 0.05) { [weak self] in
            self?.graceCheckScheduled = false
            self?.reconcile()
        }
    }

    private func report(_ id: String, _ message: String?) {
        guard reportedError[id] != message else { return }
        reportedError[id] = message
        DispatchQueue.main.async { [weak self] in self?.onError?(id, message) }
    }
}
