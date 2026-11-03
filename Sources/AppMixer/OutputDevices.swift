import CoreAudio
import Foundation

/// A physical (or third-party virtual) output device the user can pick.
struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeAggregate: return "square.stack.3d.up"
        case kAudioDeviceTransportTypeVirtual: return "waveform"
        default: return "hifispeaker"
        }
    }
}

/// Device-level Core Audio calls: enumeration, default output, volume/mute, and the "Share Audio"
/// multi-output device.
enum AudioDevices {
    /// Everything AppMixer creates has a UID with this prefix (private tap aggregates, the share device).
    static let ownPrefix = "AppMixer."
    static let sharePrefix = "AppMixer.share."
    static let shareName = "AppMixer Shared Output"

    /// kAudioHardwareServiceDeviceProperty_VirtualMainVolume ('vmvc'): the same "master" volume the
    /// volume keys change, available even on devices that only have per-channel volume controls.
    static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    static func allDeviceIDs() -> [AudioDeviceID] {
        (try? CA.getObjectIDs(CA.systemObject, kAudioHardwarePropertyDevices)) ?? []
    }

    static func uid(_ id: AudioDeviceID) -> String? {
        try? CA.deviceUID(id)
    }

    static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// User-selectable outputs: has output streams, not hidden, not created by AppMixer.
    static func outputDevices() -> [OutputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasOutputStreams(id), let uid = uid(id), !uid.hasPrefix(ownPrefix) else { return nil }
            let hidden = (try? CA.get(id, kAudioDevicePropertyIsHidden, initial: UInt32(0))) ?? 0
            guard hidden == 0 else { return nil }
            let transport = (try? CA.get(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
            return OutputDevice(id: id, uid: uid, name: CA.name(id), transport: transport)
        }
    }

    /// Share devices left behind by a previous AppMixer run (e.g. after a crash).
    static func existingShareDevices() -> [AudioDeviceID] {
        allDeviceIDs().filter { uid($0)?.hasPrefix(sharePrefix) == true }
    }

    static func defaultOutput() -> AudioDeviceID? {
        let id = (try? CA.defaultOutputDevice()) ?? CA.unknown
        return id == CA.unknown ? nil : id
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        (try? CA.set(CA.systemObject, kAudioHardwarePropertyDefaultOutputDevice, value: id)) != nil
    }

    static func defaultInput() -> AudioDeviceID {
        (try? CA.get(CA.systemObject, kAudioHardwarePropertyDefaultInputDevice, initial: CA.unknown)) ?? CA.unknown
    }

    static func defaultSystemSound() -> AudioDeviceID {
        (try? CA.get(CA.systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice, initial: CA.unknown)) ?? CA.unknown
    }

    static func setDefaultInput(_ id: AudioDeviceID) {
        try? CA.set(CA.systemObject, kAudioHardwarePropertyDefaultInputDevice, value: id)
    }

    static func setDefaultSystemSound(_ id: AudioDeviceID) {
        try? CA.set(CA.systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice, value: id)
    }

    /// The physical device behind a UID: Bluetooth headsets expose "<address>:output" and
    /// "<address>:input" as separate devices.
    static func hardwareBase(_ uid: String) -> String {
        String(uid.split(separator: ":", maxSplits: 1).first ?? Substring(uid))
    }

    // MARK: Volume / mute

    static func volume(_ id: AudioDeviceID) -> Float? {
        try? CA.get(id, virtualMainVolume, scope: kAudioObjectPropertyScopeOutput, initial: Float32(0))
    }

    static func setVolume(_ id: AudioDeviceID, _ value: Float) {
        try? CA.set(id, virtualMainVolume, scope: kAudioObjectPropertyScopeOutput, value: Float32(min(max(value, 0), 1)))
    }

    static func isMuted(_ id: AudioDeviceID) -> Bool? {
        guard CA.has(id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput) else { return nil }
        return (try? CA.get(id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0))).map { $0 != 0 }
    }

    static func setMuted(_ id: AudioDeviceID, _ muted: Bool) {
        try? CA.set(id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(muted ? 1 : 0))
    }

    // MARK: Share Audio (multi-output device)

    /// UIDs of an aggregate's sub-devices, main device first.
    static func subdeviceUIDs(of aggregate: AudioDeviceID) -> [String] {
        var addr = CA.address(kAudioAggregateDevicePropertyFullSubDeviceList)
        var list: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioObjectGetPropertyData(aggregate, &addr, 0, nil, &size, &list) == noErr,
              let array = list?.takeRetainedValue() as? [String] else { return [] }
        return array
    }

    /// A public, stacked aggregate ("Multi-Output Device"): every sub-device plays the same audio.
    /// Public so it can become the system output; AppMixer removes it when sharing stops or on quit.
    static func createShareDevice(mainUID: String, extraUIDs: [String]) throws -> AudioDeviceID {
        var subdevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: mainUID]]
        for uid in extraUIDs {
            subdevices.append([kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: true])
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: shareName,
            kAudioAggregateDeviceUIDKey: sharePrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: mainUID,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
        ]
        var id = CA.unknown
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "create share device")
        return id
    }

    static func destroyAggregate(_ id: AudioDeviceID) {
        AudioHardwareDestroyAggregateDevice(id)
    }
}
