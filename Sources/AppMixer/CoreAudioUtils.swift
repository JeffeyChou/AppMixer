import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String
    var description: String { "\(what) failed (\(fourCC(status)))" }
}

/// Renders an OSStatus as a four-char code when it is printable ('!dev', 'who?' ...), else as a number.
func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: bytes, encoding: .ascii) {
        return "'\(s)'"
    }
    return "\(status)"
}

func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, what: what()) }
}

/// Thin helpers over the C property API (works on macOS 14.2+, unlike the macOS 15 Swift wrappers).
enum CA {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                        initial: T) throws -> T {
        var addr = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value),
                  "read \(fourCC(OSStatus(bitPattern: selector)))")
        return value
    }

    static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                        value: T) throws {
        var addr = address(selector, scope: scope)
        var v = value
        try check(AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v),
                  "write \(fourCC(OSStatus(bitPattern: selector)))")
    }

    static func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope: scope)
        return AudioObjectHasProperty(object, &addr)
    }

    static func getObjectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "size of object list")
        let stride = MemoryLayout<AudioObjectID>.stride
        guard size >= stride else { return [] }
        var ids = [AudioObjectID](repeating: unknown, count: Int(size) / stride)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids), "read object list")
        return Array(ids.prefix(Int(size) / stride))
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "read string")
        return value?.takeRetainedValue() as String?
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try get(systemObject, kAudioHardwarePropertyDefaultOutputDevice, initial: unknown)
    }

    static func deviceUID(_ device: AudioDeviceID) throws -> String {
        guard let uid = try getString(device, kAudioDevicePropertyDeviceUID), !uid.isEmpty else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, what: "read device UID")
        }
        return uid
    }

    static func name(_ object: AudioObjectID) -> String {
        ((try? getString(object, kAudioObjectPropertyName)) ?? nil) ?? "Unknown device"
    }
}
