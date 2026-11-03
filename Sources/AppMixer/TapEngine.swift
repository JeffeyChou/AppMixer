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
        let eq: [Double]?           // nil = EQ off
        let outputUIDs: [String]    // where the app should play
        let needsTap: Bool          // false = app is untouched (100 %, no EQ, system output)
    }

    /// Called on the main queue with (app id, error text or nil when cleared).
    var onError: ((String, String?) -> Void)?

    /// A tap that is no longer needed (back to 100 %, EQ off, system output) is kept this long before
    /// teardown, so dragging a slider through 100 % doesn't destroy and rebuild it (an audible glitch).
    private static let idleGrace: TimeInterval = 3

    private let queue = DispatchQueue(label: "AppMixer.TapEngine", qos: .userInteractive)

    // Hand-off from the main thread (guarded by `lock`).
    private let lock = NSLock()
    private var pendingTargets: [String: Target]?
    private var pendingRetry: Set<String> = []
    private var pendingRetryAll = false
    private var drainScheduled = false

    // Engine-queue state.
    private var targets: [String: Target] = [:]
    private var taps: [String: ProcessTap] = [:]
    private var failedSignature: [String: String] = [:]
    private var reportedError: [String: String] = [:]
    private var idleSince: [String: Date] = [:]
    private var graceCheckScheduled = false

    /// `targets`: every live app. `retry`: ids whose previous failure should be retried (the user
    /// touched them).
    func update(targets: [String: Target], retry: Set<String> = [], retryAll: Bool = false) {
        lock.lock()
        pendingTargets = targets
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
        let retry = pendingRetry
        let retryAll = pendingRetryAll
        pendingTargets = nil
        pendingRetry = []
        pendingRetryAll = false
        drainScheduled = false
        lock.unlock()

        if let newTargets { targets = newTargets }
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
        for id in Array(taps.keys) where targets[id] == nil { remove(id) }

        let now = Date()
        for (id, target) in targets {
            guard target.needsTap, !target.outputUIDs.isEmpty else {
                guard let tap = taps[id] else { continue }
                // Neutral settings while the grace period runs. If the destination changed (e.g. the app
                // was routed back to System Output) the tap must go now, or audio stays on the old device.
                tap.setGain(1)
                tap.setEQ(nil)
                let since = idleSince[id] ?? now
                idleSince[id] = since
                let sameRoute = tap.signature == ProcessTap.signature(objectIDs: target.objectIDs,
                                                                      outputUIDs: target.outputUIDs)
                if !sameRoute || target.outputUIDs.isEmpty || now.timeIntervalSince(since) >= Self.idleGrace {
                    remove(id)
                } else {
                    scheduleGraceCheck()
                }
                continue
            }
            idleSince[id] = nil

            let signature = ProcessTap.signature(objectIDs: target.objectIDs, outputUIDs: target.outputUIDs)
            if let tap = taps[id], tap.signature == signature {
                tap.setGain(target.gain)
                tap.setEQ(target.eq)
                continue
            }
            if failedSignature[id] == signature { continue }   // don't hammer a broken setup

            remove(id)
            do {
                taps[id] = try ProcessTap(name: target.name, processObjectIDs: target.objectIDs,
                                          outputUIDs: target.outputUIDs, gain: target.gain, eq: target.eq)
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
        idleSince[id] = nil
    }

    private func scheduleGraceCheck() {
        guard !graceCheckScheduled else { return }
        graceCheckScheduled = true
        queue.asyncAfter(deadline: .now() + Self.idleGrace + 0.05) { [weak self] in
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
