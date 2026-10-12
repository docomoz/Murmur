import CoreAudio
import Foundation

/// «Тише во время созвонов»: watches whether any other app is recording from a microphone
/// (Zoom, Meet in a browser, Telegram, FaceTime…) — without ever opening the mic itself, so no
/// microphone permission is involved.
///
/// The truth comes from the HAL's per-process objects (macOS 14+): a process with
/// `kAudioProcessPropertyIsRunningInput` is capturing audio — the same thing that lights the
/// orange dot in the menu bar. Device-level `kAudioDevicePropertyDeviceIsRunningSomewhere` can't
/// be the signal on its own: headsets and AirPods are one device for input and output, so
/// Murmur's own playback would keep "the mic device" running. Those device flags are only used
/// as an extra wake-up to re-check the processes.
///
/// Calls `onChange` on the main thread. All methods must be called on the main thread.
final class MicMonitor {
    private(set) var inUse = false
    private let onChange: (Bool) -> Void
    private var watched: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var listener: AudioObjectPropertyListenerBlock?
    private var recheck: DispatchWorkItem?

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    deinit { unwatchAll() }

    var isRunning: Bool { listener != nil }

    func start() {
        guard listener == nil else { return }
        listener = { [weak self] _, _ in self?.changed() }
        rewatch()
        refresh()
    }

    func stop() {
        recheck?.cancel()
        unwatchAll()
        listener = nil
        if inUse {
            inUse = false
            onChange(false)
        }
    }

    // MARK: State

    /// Whether any process other than Murmur is capturing audio right now.
    static func someoneIsRecording() -> Bool { !recorders().isEmpty }

    /// HAL process objects of everyone but Murmur that is capturing audio right now.
    static func recorders() -> [AudioObjectID] {
        let me = getpid()
        return processes().filter { process in
            pid(of: process) != me && flag(process, kAudioProcessPropertyIsRunningInput)
        }
    }

    /// Debug: who is recording, by bundle ID (or pid when there is none).
    static func recorderNames() -> [String] {
        recorders().map { process in
            var address = address(kAudioProcessPropertyBundleID)
            var name: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(process, &address, 0, nil, &size, &name) == noErr,
               let id = name?.takeRetainedValue() as String?, !id.isEmpty {
                return id
            }
            return "pid \(pid(of: process))"
        }
    }

    private func refresh() {
        let now = Self.someoneIsRecording()
        guard now != inUse else { return }
        inUse = now
        onChange(now)
    }

    /// Something moved: re-check now and once more a moment later, in case the device and process
    /// flags don't update in the same instant.
    private func changed() {
        rewatch()
        refresh()
        recheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        recheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Listeners

    /// (Re)attaches listeners: the lists of processes and devices on the system object, input
    /// state on every process, running state on every input-capable device.
    private func rewatch() {
        guard let listener else { return }
        unwatchAll()
        let system = AudioObjectID(kAudioObjectSystemObject)
        watch(system, kAudioHardwarePropertyProcessObjectList, listener)
        watch(system, kAudioHardwarePropertyDevices, listener)
        watch(system, kAudioHardwarePropertyDefaultInputDevice, listener)
        for process in Self.processes() {
            watch(process, kAudioProcessPropertyIsRunningInput, listener)
        }
        for device in Self.ids(system, kAudioHardwarePropertyDevices) where Self.hasInput(device) {
            watch(device, kAudioDevicePropertyDeviceIsRunningSomewhere, listener)
        }
    }

    private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = Self.address(selector)
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            watched.append((object, address))
        }
    }

    private func unwatchAll() {
        guard let listener else { return }
        for (object, address) in watched {
            var address = address
            // Fails harmlessly for processes and devices that are already gone.
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, listener)
        }
        watched = []
    }

    // MARK: HAL helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func processes() -> [AudioObjectID] {
        ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        !ids(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty
    }

    private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func pid(of process: AudioObjectID) -> pid_t {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr ? value : -1
    }
}

/// The duck itself, as a pure function of time so `--selftest` can check it without a mic.
///
/// The mic goes live → the level glides to silence over `fadeOut`. The mic is released → after
/// `hold` (brief mute/unmute toggles don't make the sound pump) it glides back over `fadeIn`.
/// `gain` is a smoothstep of the linear position, so both ends of a fade are soft.
struct DuckEnvelope {
    var fadeOut = 1.5
    var fadeIn = 3.0
    var hold = 2.5

    /// 1 = full volume, 0 = fully ducked (linear position along the fade).
    private(set) var level = 1.0
    /// Heading for silence: the mic is in use, or was released less than `hold` ago.
    private(set) var ducked = false
    private var releasedAt: Double?
    private var time: Double?

    var gain: Float { Float(level * level * (3 - 2 * level)) }

    /// Fully silent and staying so — the engine may rest.
    var isSilent: Bool { ducked && level == 0 }

    /// Nothing will change until the mic does.
    var isSettled: Bool { releasedAt == nil && level == (ducked ? 0 : 1) }

    mutating func update(micInUse: Bool, at now: Double) {
        advance(to: now)
        if micInUse {
            ducked = true
            releasedAt = nil
        } else if ducked, releasedAt == nil {
            releasedAt = now
        }
    }

    /// Feature switched off: come back right away, no hold.
    mutating func cancel(at now: Double) {
        advance(to: now)
        ducked = false
        releasedAt = nil
    }

    mutating func advance(to now: Double) {
        let dt = max(0, now - (time ?? now))
        time = now
        if let released = releasedAt, now - released >= hold {
            ducked = false
            releasedAt = nil
        }
        if ducked {
            level = max(0, level - dt / fadeOut)
        } else {
            level = min(1, level + dt / fadeIn)
        }
    }

    /// `--selftest`: walks the envelope through a call, a release and a brief mic toggle.
    /// Returns failures (empty = all good).
    static func selfCheck() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        func run(_ e: inout DuckEnvelope, from: Double, to: Double) {
            var t = from
            while t < to - 1e-9 { t = min(to, t + 1.0 / 60); e.advance(to: t) }
        }

        var e = DuckEnvelope()
        e.update(micInUse: false, at: 0)
        run(&e, from: 0, to: 1)
        expect(e.gain == 1 && e.isSettled, "idle: full volume, settled")

        e.update(micInUse: true, at: 1)
        run(&e, from: 1, to: 1.75)
        expect(e.gain > 0.2 && e.gain < 0.8, "half-way through the fade-out (gain \(e.gain))")
        run(&e, from: 1.75, to: 2.6)
        expect(e.gain == 0 && e.isSilent && e.isSettled, "silent \(e.fadeOut) s after the mic went live")

        e.update(micInUse: false, at: 10)
        run(&e, from: 10, to: 12.4)
        expect(e.gain == 0 && !e.isSettled, "still silent during the \(e.hold) s hold")
        run(&e, from: 12.4, to: 14)
        expect(e.gain > 0 && e.gain < 1 && !e.ducked, "coming back after the hold (gain \(e.gain))")
        run(&e, from: 14, to: 15.6)
        expect(e.gain == 1 && e.isSettled, "full volume \(e.hold + e.fadeIn) s after release")

        // Mute/unmute in a call: released for 1 s, then live again — no pumping.
        e.update(micInUse: true, at: 20)
        run(&e, from: 20, to: 22)
        e.update(micInUse: false, at: 22)
        run(&e, from: 22, to: 23)
        e.update(micInUse: true, at: 23)
        run(&e, from: 23, to: 30)
        expect(e.gain == 0 && e.isSettled, "a brief toggle never lets the sound back in")

        // Switched off mid-call: back without waiting for the hold.
        e.cancel(at: 30)
        run(&e, from: 30, to: 30 + e.fadeIn + 0.1)
        expect(e.gain == 1 && e.isSettled, "turning the feature off restores the volume")
        return failures
    }
}
