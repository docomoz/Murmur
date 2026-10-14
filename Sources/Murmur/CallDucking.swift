import CoreAudio
import Foundation

/// «Тише во время созвонов»: watches whether another app is in a call (Zoom, Meet in a browser,
/// Telegram, FaceTime…) — without ever opening the mic itself, so no microphone permission is
/// involved.
///
/// The truth comes from the HAL's per-process objects (macOS 14+): which processes are capturing
/// (`kAudioProcessPropertyIsRunningInput`, the orange dot) and which are playing
/// (`kAudioProcessPropertyIsRunningOutput`). A call both listens and speaks, so only an app that
/// records *and* plays counts (`CallDetector`); a recorder alone (Plaud, dictation tools) doesn't.
/// Device-level `kAudioDevicePropertyDeviceIsRunningSomewhere` can't be the signal: headsets and
/// AirPods are one device for input and output, so Murmur's own playback would keep "the mic
/// device" running. Those device flags are only an extra wake-up to re-check the processes.
///
/// Calls `onChange` on the main thread. All methods must be called on the main thread.
final class MicMonitor {
    private(set) var inUse = false
    private let onChange: (Bool) -> Void
    /// HAL objects carrying our listener, and for which properties.
    private var watched: [AudioObjectID: [AudioObjectPropertySelector]] = [:]
    private var relay: Relay?
    private var check: DispatchWorkItem?
    private var settle: DispatchWorkItem?
    private var needsRelist = false
    /// `--selftest`: listener calls received so far.
    private(set) var callbacks = 0

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    deinit { detach() }

    var isRunning: Bool { relay != nil }

    func start() {
        guard relay == nil else { return }
        relay = Relay(self)
        watch(AudioObjectID(kAudioObjectSystemObject), [
            kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
        ])
        relist()
        refresh()
    }

    func stop() {
        detach()
        if inUse {
            inUse = false
            onChange(false)
        }
    }

    private func detach() {
        check?.cancel()
        settle?.cancel()
        check = nil
        settle = nil
        needsRelist = false
        guard let relay else { return }
        for (object, selectors) in watched { Self.unwatch(object, selectors, relay) }
        watched = [:]
        relay.monitor = nil
        self.relay = nil
        // A HAL thread may be inside `listen` with this relay right now; let it finish first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withExtendedLifetime(relay) {} }
    }

    // MARK: State

    /// Everyone but Murmur that talks to the HAL, with what they are doing right now.
    static func clients() -> [CallDetector.Client] {
        let me = getpid()
        return processes().compactMap { process in
            let pid = pid(of: process)
            guard pid != me else { return nil }
            return CallDetector.Client(
                bundleID: bundleID(of: process) ?? "",
                input: flag(process, kAudioProcessPropertyIsRunningInput),
                output: flag(process, kAudioProcessPropertyIsRunningOutput))
        }
    }

    /// Debug: who is capturing audio right now, by bundle ID.
    static func recorderNames() -> [String] {
        clients().filter(\.input).map { $0.bundleID.isEmpty ? "?" : $0.bundleID }
    }

    /// Debug: the apps that would duck Murmur right now.
    static func callNames() -> [String] {
        CallDetector.callApps(clients(), me: Bundle.main.bundleIdentifier ?? "")
    }

    private func refresh() {
        let now = !Self.callNames().isEmpty
        guard now != inUse else { return }
        inUse = now
        onChange(now)
    }

    /// Something moved. One sound anywhere arrives as a burst of notifications (a process appears,
    /// starts output, its device starts…), and each check walks every audio process over IPC, so
    /// a burst is checked once, a moment later — and once more after it has died down, in case
    /// the device and process flags don't update in the same instant.
    fileprivate func changed(relist: Bool) {
        callbacks += 1
        needsRelist = needsRelist || relist
        if check == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.check = nil
                if self.needsRelist {
                    self.needsRelist = false
                    self.relist()
                }
                self.refresh()
            }
            check = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: Listeners

    /// Brings the listeners in line with the processes and devices there are now: input and output
    /// state on every other process, running state on every input-capable device. Newcomers get a
    /// listener, the vanished lose theirs, everyone else keeps the one they have.
    private func relist() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let me = getpid()
        var wanted: [AudioObjectID: [AudioObjectPropertySelector]] = [:]
        for process in Self.processes() {
            if let selectors = watched[process] {
                wanted[process] = selectors
            } else if Self.pid(of: process) != me { // Murmur's own play/pause isn't news.
                wanted[process] = [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput]
            }
        }
        for device in Self.ids(system, kAudioHardwarePropertyDevices) {
            if let selectors = watched[device] {
                wanted[device] = selectors
            } else if Self.hasInput(device) {
                wanted[device] = [kAudioDevicePropertyDeviceIsRunningSomewhere]
            }
        }
        if let relay {
            for (object, selectors) in watched where object != system && wanted[object] == nil {
                Self.unwatch(object, selectors, relay)
                watched[object] = nil
            }
        }
        for (object, selectors) in wanted where watched[object] == nil {
            watch(object, selectors)
        }
    }

    private func watch(_ object: AudioObjectID, _ selectors: [AudioObjectPropertySelector]) {
        guard let relay else { return }
        let context = Unmanaged.passUnretained(relay).toOpaque()
        let added = selectors.filter { selector in
            var address = Self.address(selector)
            return AudioObjectAddPropertyListener(object, &address, Self.listen, context) == noErr
        }
        if !added.isEmpty { watched[object] = added }
    }

    private static func unwatch(_ object: AudioObjectID, _ selectors: [AudioObjectPropertySelector], _ relay: Relay) {
        let context = Unmanaged.passUnretained(relay).toOpaque()
        for selector in selectors {
            var address = address(selector)
            // Fails harmlessly for processes and devices that are already gone.
            AudioObjectRemovePropertyListener(object, &address, listen, context)
        }
    }

    /// Runs on a HAL thread. Listeners go through the C API on purpose: it adds and removes them
    /// by (function, context), while `AudioObjectRemovePropertyListenerBlock` called from Swift
    /// silently removes nothing (and still returns noErr) — every re-subscription used to stack
    /// another copy of each listener, and each copy re-scanned all audio processes on every sound.
    private static let listen: AudioObjectPropertyListenerProc = { _, count, addresses, context in
        guard let context else { return noErr }
        let relay = Unmanaged<Relay>.fromOpaque(context).takeUnretainedValue()
        // Only a new or vanished process/device needs fresh listeners; flag flips just re-check.
        let relist = (0..<Int(count)).contains {
            let selector = addresses[$0].mSelector
            return selector == kAudioHardwarePropertyProcessObjectList || selector == kAudioHardwarePropertyDevices
        }
        DispatchQueue.main.async { relay.monitor?.changed(relist: relist) }
        return noErr
    }

    /// The listeners' context: lets a late HAL callback find out the monitor is gone.
    private final class Relay {
        weak var monitor: MicMonitor?
        init(_ monitor: MicMonitor) { self.monitor = monitor }
    }

    /// `--selftest`: switches the monitor off and on many times, then lets another process play a
    /// silent sound. Listeners must not pile up (one copy each → a handful of calls, not hundreds),
    /// and none may survive `stop()`. Returns failures (empty = all good).
    static func selfCheckListeners() -> (calls: Int, failures: [String]) {
        let player = URL(fileURLWithPath: "/usr/bin/afplay")
        let sound = "/System/Library/Sounds/Tink.aiff"
        guard FileManager.default.isExecutableFile(atPath: player.path) else { return (0, []) }
        func soundElsewhere(then wait: Double) {
            let p = Process()
            p.executableURL = player
            p.arguments = ["-v", "0", sound]
            try? p.run()
            p.waitUntilExit()
            RunLoop.main.run(until: Date().addingTimeInterval(wait))
        }
        var failures: [String] = []
        let monitor = MicMonitor { _ in }
        for _ in 0..<20 {
            monitor.start()
            monitor.stop()
        }
        monitor.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let before = monitor.callbacks
        soundElsewhere(then: 1.5)
        let calls = monitor.callbacks - before
        if calls == 0 { failures.append("no listener call for a sound elsewhere") }
        if calls > 12 { failures.append("\(calls) listener calls for one sound elsewhere — listeners pile up") }
        monitor.stop()
        let after = monitor.callbacks
        soundElsewhere(then: 1.5)
        if monitor.callbacks != after { failures.append("listeners outlive stop()") }
        return (calls, failures)
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

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}

/// "Is somebody in a call?" as a pure function over the HAL's audio clients, so `--selftest`
/// can check it without a mic or a call.
///
/// A call listens and speaks: an app counts when it captures input *and* plays output. Many apps
/// split that between processes (`kontur.talk` records, `kontur.talk.helper` plays; Chrome runs
/// Meet's audio in `com.google.Chrome.helper` next to `com.google.Chrome`), so processes whose
/// bundle IDs nest — one is the other plus `.something` — are treated as one app. Siblings that
/// merely share a vendor prefix (`com.apple.VoiceMemos` and `com.apple.Music`) are not. Safari's
/// WebRTC records and plays in the same `com.apple.WebKit.GPU` process. Recorders alone (Plaud,
/// dictation tools) never duck, and Murmur itself never counts.
enum CallDetector {
    struct Client {
        var bundleID: String
        var input: Bool
        var output: Bool
    }

    /// Bundle IDs of the recording processes that are in a call; empty = no call.
    static func callApps(_ clients: [Client], me: String) -> [String] {
        let others = clients.filter { me.isEmpty || !sameApp($0.bundleID, me) }
        let players = others.filter(\.output).map(\.bundleID).filter { !$0.isEmpty }
        return others.filter { recorder in
            recorder.input && (recorder.output || players.contains { sameApp($0, recorder.bundleID) })
        }.map { $0.bundleID.isEmpty ? "?" : $0.bundleID }
    }

    /// `kontur.talk` ~ `kontur.talk.helper`; `com.apple.Music` ≁ `com.apple.VoiceMemos`.
    static func sameApp(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let a = a.lowercased(), b = b.lowercased()
        return a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
    }

    /// `--selftest`: returns failures (empty = all good).
    static func selfCheck() -> [String] {
        typealias C = Client
        let me = "app.murmur.mac"
        let cases: [(String, [Client], Bool)] = [
            ("nobody", [], false),
            ("Plaud records only", [C(bundleID: "ai.plaud.desktop.plaud", input: true, output: false)], false),
            ("Plaud records, its own idle helper", [
                C(bundleID: "ai.plaud.desktop.plaud", input: true, output: false),
                C(bundleID: "ai.plaud.desktop.plaud.helper", input: false, output: false)], false),
            ("kontur.talk records + kontur.talk.helper plays", [
                C(bundleID: "kontur.talk", input: true, output: false),
                C(bundleID: "kontur.talk.helper", input: false, output: true)], true),
            ("one process records and plays", [C(bundleID: "us.zoom.xos", input: true, output: true)], true),
            ("one process without a bundle ID records and plays", [C(bundleID: "", input: true, output: true)], true),
            ("Murmur plays + Plaud records", [
                C(bundleID: me, input: false, output: true),
                C(bundleID: "ai.plaud.desktop.plaud", input: true, output: false)], false),
            ("Murmur itself records and plays", [C(bundleID: me, input: true, output: true)], false),
            ("browser helper records + browser helper plays", [
                C(bundleID: "com.google.Chrome.helper", input: true, output: false),
                C(bundleID: "com.google.Chrome.helper", input: false, output: true),
                C(bundleID: "com.google.Chrome", input: false, output: false)], true),
            ("Chrome helper records, Chrome plays", [
                C(bundleID: "com.google.Chrome.helper", input: true, output: false),
                C(bundleID: "com.google.Chrome", input: false, output: true)], true),
            ("Safari WebRTC in the GPU process", [C(bundleID: "com.apple.WebKit.GPU", input: true, output: true)], true),
            ("Voice Memos records while Music plays", [
                C(bundleID: "com.apple.VoiceMemos", input: true, output: false),
                C(bundleID: "com.apple.Music", input: false, output: true)], false),
            ("dictation records, someone else plays", [
                C(bundleID: "com.example.dictation", input: true, output: false),
                C(bundleID: "com.spotify.client", input: false, output: true)], false),
            ("unnamed recorder + unnamed player stay apart", [
                C(bundleID: "", input: true, output: false),
                C(bundleID: "", input: false, output: true)], false),
        ]
        return cases.compactMap { name, clients, expected in
            !callApps(clients, me: me).isEmpty == expected ? nil : "\(name): expected \(expected ? "duck" : "no duck")"
        }
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
