// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreAudio
import IOKit

/// The Core Audio half of the microphone choice: which input devices exist, which one
/// the system uses, and whether a MacBook's lid is closed. The decision itself is
/// `MicrophoneResolution` (MicrophoneChoice.swift), pure and in both targets.
enum AudioInputDevices {
    /// Every device with at least one input stream, in Core Audio's order.
    static func all() -> [AudioInputDevice] {
        let lidClosed = isLidClosed()
        return deviceIDs().compactMap { id -> AudioInputDevice? in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            // The aggregate Core Audio builds behind an app's back is not a microphone.
            guard !name.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            let transport = transport(of: id)
            return AudioInputDevice(uid: uid, name: name, transport: transport,
                                    canHear: !(transport == .builtIn && lidClosed))
        }
    }

    static func defaultInputUID() -> String? {
        var id = AudioDeviceID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, into: &id),
              id != kAudioObjectUnknown else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func nominalSampleRate(of id: AudioDeviceID) -> Double? {
        var rate = Float64(0)
        return read(id, kAudioDevicePropertyNominalSampleRate, into: &rate) ? rate : nil
    }

    /// False once the device is gone — unplugged, or switched off — though its ID may
    /// still answer for a moment.
    static func isAlive(_ id: AudioDeviceID) -> Bool {
        var alive = UInt32(0)
        return read(id, kAudioDevicePropertyDeviceIsAlive, into: &alive) && alive != 0
    }

    /// The choice as it stands with the devices connected now.
    static func resolve(_ choice: MicrophoneChoice) -> MicrophoneResolution {
        MicrophoneResolution.resolve(choice, devices: all(), defaultUID: defaultInputUID())
    }

    /// A closed lid disconnects a MacBook's microphone in hardware, though Core Audio
    /// still lists it — recording from it would be silence. Desktops report nothing.
    static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    // MARK: - Core Audio reads

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                into value: inout T) -> Bool {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func transport(of id: AudioDeviceID) -> AudioInputDevice.Transport {
        var type = UInt32(0)
        guard read(id, kAudioDevicePropertyTransportType, into: &type) else { return .other }
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        default: return .other
        }
    }
}

/// The input devices and the system's choice, kept current for Settings: a headset
/// connecting or the default moving in System Settings updates the picker while it is open.
@Observable
final class AudioInputMonitor {
    private(set) var devices: [AudioInputDevice] = []
    private(set) var defaultUID: String?

    private var listener: AudioObjectPropertyListenerBlock?
    private static let watched = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    init() {
        refresh()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        listener = block
        for selector in Self.watched {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
    }

    deinit {
        guard let listener else { return }
        for selector in Self.watched {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        }
    }

    func refresh() {
        devices = AudioInputDevices.all()
        defaultUID = AudioInputDevices.defaultInputUID()
    }
}
