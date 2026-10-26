// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import AudioToolbox
import AVFoundation
import IOKit

/// Audio inputs the Mac can hear through. An iPhone near the Mac (same Apple Account, Wi-Fi and Bluetooth on) shows up here
/// as a normal input through Continuity, which is how dictation keeps working with the lid closed and the Mac docked.
struct Microphone: Identifiable, Equatable, Sendable {
    let uid: String
    let name: String
    let isPhone: Bool
    let isBuiltIn: Bool
    var id: String { uid }
}

enum Microphones {
    /// What Settings stores when the user lets Moose choose.
    static let automatic = ""

    static func all() -> [Microphone] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(microphone)
    }

    /// Where the sound will come from for a stored choice. A missing device (phone out of range) falls back to automatic.
    static func resolve(_ choice: String, clamshell: Bool = lidClosed()) -> Microphone? {
        let list = all()
        if choice != automatic, let m = list.first(where: { $0.uid == choice }) { return m }
        // With the lid closed the built-in microphone is shut away, so prefer a phone, then anything that isn't built in.
        if clamshell { return list.first(where: \.isPhone) ?? list.first(where: { !$0.isBuiltIn }) }
        return nil   // nil = whatever macOS has selected
    }

    /// Points the engine's input at a device. Returns false if CoreAudio refused.
    static func route(_ engine: AVAudioEngine, to mic: Microphone) -> Bool {
        guard var dev = deviceID(uid: mic.uid), let unit = engine.inputNode.audioUnit else { return false }
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    /// True while the laptop lid is shut (the Mac is docked to a display).
    static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? Bool) == true
    }

    // MARK: CoreAudio plumbing

    private static func microphone(_ id: AudioDeviceID) -> Microphone? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0,
              let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
        var transport: UInt32 = 0
        var tsize = UInt32(MemoryLayout<UInt32>.size)
        var taddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport)
        // Aggregate and virtual devices (including the "CADefaultDeviceAggregate-…" one CoreAudio makes for every engine) aren't
        // real microphones and can't be routed to; picking one as the clamshell fallback is what broke the phone mic.
        if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual || name.hasPrefix("CADefaultDeviceAggregate") { return nil }
        // Continuity Camera microphones report the 'ccwd'/'ccwl' transports on recent macOS; the name is the fallback.
        let continuity: Set<UInt32> = [0x63637764, 0x6363776C]
        let phone = continuity.contains(transport) || name.localizedCaseInsensitiveContains("iphone")
        return Microphone(uid: uid, name: name, isPhone: phone, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr, let s = ref?.takeRetainedValue() else { return nil }
        return s as String
    }

    private static func deviceID(uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDeviceForUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var cf = uid as CFString
        // This property takes an AudioValueTranslation (UID in, device out), not a qualifier.
        let status = withUnsafeMutablePointer(to: &cf) { cfp in
            withUnsafeMutablePointer(to: &dev) { devp in
                var t = AudioValueTranslation(mInputData: UnsafeMutableRawPointer(cfp), mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                                              mOutputData: UnsafeMutableRawPointer(devp), mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size))
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &t)
            }
        }
        return status == noErr && dev != 0 ? dev : nil
    }
}
