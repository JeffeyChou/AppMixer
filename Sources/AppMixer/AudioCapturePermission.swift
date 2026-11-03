import AppKit

/// "System Audio Recording" (kTCCServiceAudioCapture) permission.
///
/// There is no public API to check or request it ahead of time; the system only prompts once a tap
/// starts. We use the private TCC SPI (same approach as the open-source AudioCap sample) so we never
/// create a muting tap without permission. If the SPI is missing we report `.unavailable` and simply
/// try, letting the system prompt.
enum AudioCapturePermission {
    enum Status { case authorized, denied, notDetermined, unavailable }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    // The completion block is stored by TCC and called later, so it must be @escaping
    // (a non-escaping block trips Swift's "non-escaping closure has escaped" check and crashes).
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let preflight: PreflightFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }()

    private static let request: RequestFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFn.self)
    }()

    static func status() -> Status {
        guard let preflight else { return .unavailable }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt (first time only). Completion is called on the main queue.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let request else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        request(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}
