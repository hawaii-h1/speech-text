// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// Where `SpeechEngine` takes the microphone's audio from. Two sources behind one shape,
/// so the tap, the writer and the session see no difference:
///
/// - `EngineCapture`, `AVAudioEngine`'s input node on the system's input — the path the
///   app always took, kept for System Default and for Automatic when it substitutes
///   nothing.
/// - `DeviceCapture`, a bare AUHAL bound to one device, for every resolution that names
///   one. `AVAudioEngine` cannot be pointed at a device without first opening the
///   system's: touching `inputNode` builds `CADefaultDeviceAggregate` from the default
///   input and output and binds the I/O unit to it, and with Bluetooth headphones that
///   input is the headset's microphone — the headset dropped to its call profile and the
///   music stopped for seconds, though `setDeviceID` moved the unit to the Mac's own
///   microphone a moment later. The move also left the tap holding the headset's 48 kHz
///   format against the microphone's 44.1 kHz, and the start failed with -10868.
///
/// `start`, `stop` and `removeTap` run on `SpeechEngine`'s `engineQueue`; `format`,
/// `installTap` and `onConfigurationChange` are used from main.
protocol AudioCapture: AnyObject {
    /// The hardware format the tap delivers.
    var format: AVAudioFormat { get }
    var isRunning: Bool { get }
    /// The device changed under the capture (it went away, or its format changed),
    /// delivered on main. A change that leaves `isRunning` true needs nothing.
    var onConfigurationChange: (() -> Void)? { get set }
    func installTap(_ block: @escaping (AVAudioPCMBuffer) -> Void)
    /// Returns once no tap callback is running or can run again.
    func removeTap()
    func start() throws
    func stop()
}

// MARK: - The system's input

final class EngineCapture: AudioCapture {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    var onConfigurationChange: (() -> Void)?

    init() {
        // Device plugged or unplugged, AirPods switching: AVAudioEngine stops itself and
        // says so here.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var format: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }
    var isRunning: Bool { engine.isRunning }

    func installTap(_ block: @escaping (AVAudioPCMBuffer) -> Void) {
        // nil: the hardware's own format, which avoids "format mismatch" ObjC exceptions
        // that Swift cannot catch.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            block(buffer)
        }
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() { engine.stop() }
}

// MARK: - One device

enum DeviceCaptureError: LocalizedError {
    case noInput

    var errorDescription: String? { "The microphone offers no input" }
}

final class DeviceCapture: AudioCapture {
    let deviceID: AudioDeviceID
    let format: AVAudioFormat
    var onConfigurationChange: (() -> Void)?

    private let unit: AUAudioUnit
    /// Tap callbacks run here, in order, off the HAL's real-time I/O thread: the tap
    /// converts audio and takes the writer's and the stream's locks, none of which may
    /// hold up the device. `AVAudioEngine`'s tap is off that thread too.
    private let tapQueue = DispatchQueue(label: "SpeechText.DeviceCapture.tap", qos: .userInitiated)
    private let lock = NSLock()
    private var tap: ((AVAudioPCMBuffer) -> Void)?
    private var running = false
    private var reportedRenderFailure = false
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// The AUHAL's input element. Element 0 is the output side, unused here.
    private static let inputBus = 1

    init(deviceID: AudioDeviceID) throws {
        self.deviceID = deviceID
        unit = try AUAudioUnit(componentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
        // Input only: with output enabled the unit would open the default output device too.
        unit.isInputEnabled = true
        unit.isOutputEnabled = false
        try unit.setDeviceID(deviceID)

        // The device side of the input element is the hardware's format; the client side
        // takes the same rate and channel count, so the AUHAL converts nothing — a rate
        // it resampled to would reach the writer as a speed-up or a slow-down.
        let hardware = unit.inputBusses[Self.inputBus].format
        guard hardware.channelCount > 0, hardware.sampleRate > 0,
              let client = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                         channels: hardware.channelCount)
        else { throw DeviceCaptureError.noInput }
        try unit.outputBusses[Self.inputBus].setFormat(client)
        format = client
        // The default (512) is the built-in microphone's I/O buffer; a device running a
        // larger one would fail every render with -10874 and record silence.
        unit.maximumFramesToRender = 4096

        let render = unit.renderBlock
        unit.inputHandler = { [weak self] flags, timestamp, frames, _ in
            guard let self, let block = self.currentTap() else { return }
            // A fresh buffer each time: Apple's recognition request keeps the buffers it
            // is fed, as it keeps AVAudioEngine's.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: client, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            let status = render(flags, timestamp, frames, Self.inputBus, buffer.mutableAudioBufferList, nil)
            guard status == noErr else {
                // Said once: a render that fails keeps failing, and the recording would
                // otherwise be silent with nothing in the Debug Log.
                if !self.lock.withLock({ defer { self.reportedRenderFailure = true }; return self.reportedRenderFailure }) {
                    dlog("Engine", "⚠ microphone render failed: \(status) (\(frames) frames)")
                }
                return
            }
            self.tapQueue.async { block(buffer) }
        }
        watchDevice()
    }

    deinit {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        }
    }

    var isRunning: Bool { lock.withLock { running } }

    func installTap(_ block: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.withLock { tap = block }
    }

    func removeTap() {
        lock.withLock { tap = nil }
        // Whatever was queued before the tap went has run once this returns.
        tapQueue.sync {}
    }

    func start() throws {
        try unit.allocateRenderResources()
        try unit.startHardware()
        lock.withLock { running = true }
    }

    func stop() {
        lock.withLock { running = false }
        unit.stopHardware()
    }

    private func currentTap() -> ((AVAudioPCMBuffer) -> Void)? {
        lock.withLock { tap }
    }

    /// AVAudioEngine's configuration-change notification, rebuilt for one device: it
    /// went away (unplugged, the lid closed), or its rate or channels changed. The
    /// capture counts as stopped from then on, as AVAudioEngine does, so `isRunning`
    /// tells the owner the change was real; the hardware itself is stopped by the owner's
    /// teardown, on its own queue.
    private func watchDevice() {
        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        ]
        for (selector, scope) in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.deviceChanged()
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    private func deviceChanged() {
        let alive = AudioInputDevices.isAlive(deviceID)
        let rate = AudioInputDevices.nominalSampleRate(of: deviceID)
        let changed = !alive || (rate.map { $0 != format.sampleRate } ?? true)
            || unit.inputBusses[Self.inputBus].format.channelCount != format.channelCount
        guard changed else { return }
        dlog("Engine", "microphone changed under the capture (alive: \(alive), rate: \(rate.map { "\(Int($0)) Hz" } ?? "?"))")
        lock.withLock { running = false }
        onConfigurationChange?()
    }
}
