import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct Mix: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var emoji: String
    var levels: [String: Double]
    var builtIn = false

    static let presets: [Mix] = [
        Mix(id: "b.cafe", name: L("Дождливое кафе", "Rainy Café"), emoji: "☕️", levels: ["rain": 0.55, "cafe": 0.5, "city": 0.2, "vinyl": 0.15], builtIn: true),
        Mix(id: "b.focus", name: L("Фокус", "Focus"), emoji: "🎧", levels: ["rain": 0.5, "library": 0.35, "white": 0.2], builtIn: true),
        Mix(id: "b.fire", name: L("У костра", "Campfire"), emoji: "🔥", levels: ["campfire": 0.7, "crickets": 0.35, "wind": 0.2], builtIn: true),
        Mix(id: "b.sea", name: L("Море", "Sea"), emoji: "🌊", levels: ["waves": 0.7, "wind": 0.2], builtIn: true),
        Mix(id: "b.storm", name: L("Гроза", "Storm"), emoji: "⛈️", levels: ["storm": 0.6, "rain": 0.5, "wind": 0.25], builtIn: true),
        Mix(id: "b.train", name: L("Ночной поезд", "Night Train"), emoji: "🚆", levels: ["train": 0.6, "rain": 0.3, "heartbeat": 0.15], builtIn: true),
        Mix(id: "b.library", name: L("Библиотека", "Library"), emoji: "📚", levels: ["library": 0.5, "clock": 0.3, "keyboard": 0.15, "rain": 0.25], builtIn: true),
    ]
}

/// Light/dark look of the panel.
enum PanelTheme: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: L("Как в системе", "System")
        case .light: L("Светлая", "Light")
        case .dark: L("Тёмная", "Dark")
        }
    }
}

/// What the glass under the panel looks like.
enum PanelBackdrop: String, CaseIterable {
    /// Glass tinted with soft light in the colors of what's playing (the default).
    case mix
    /// Standard system glass — follows the Liquid Glass setting in System Settings.
    case system

    var title: String {
        switch self {
        case .mix: L("В цветах микса", "Mix Colors")
        case .system: L("Системная", "System Glass")
        }
    }
}

/// Accent color of the controls: Play, sliders, selected preset, links.
enum AccentChoice: String, CaseIterable {
    case system, lavender, lilac, rose, raspberry, coral, tangerine, amber, sand, lime, emerald, graphite

    var title: String {
        switch self {
        case .system: L("Как в системе", "System")
        case .lavender: L("Лаванда", "Lavender")
        case .lilac: L("Сирень", "Lilac")
        case .rose: L("Роза", "Rose")
        case .raspberry: L("Малина", "Raspberry")
        case .coral: L("Коралл", "Coral")
        case .tangerine: L("Мандарин", "Tangerine")
        case .amber: L("Янтарь", "Amber")
        case .sand: L("Песок", "Sand")
        case .lime: L("Лайм", "Lime")
        case .emerald: L("Изумруд", "Emerald")
        case .graphite: L("Графит", "Graphite")
        }
    }

    /// Gradient pair (top/leading → bottom/trailing).
    var colors: (NSColor, NSColor) {
        func hex(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        switch self {
        case .system:
            let accent = NSColor.controlAccentColor
            return (accent, accent.blended(withFraction: 0.35, of: .white) ?? accent)
        case .lavender: return (hex(0x8B6CFF), hex(0xB49BFF))
        case .lilac: return (hex(0xB46CF0), hex(0xD9A6FF))
        case .rose: return (hex(0xF0508C), hex(0xFF85B3))
        case .raspberry: return (hex(0xD61F5C), hex(0xF2507E))
        case .coral: return (hex(0xFF6B5E), hex(0xFF9A76))
        case .tangerine: return (hex(0xF97316), hex(0xFDA154))
        case .amber: return (hex(0xF59E0B), hex(0xFBBF57))
        case .sand: return (hex(0xB8935A), hex(0xD9BC8A))
        case .lime: return (hex(0x65B320), hex(0x9AD94A))
        case .emerald: return (hex(0x0E9F6E), hex(0x3CCB94))
        case .graphite: return (hex(0x5B6270), hex(0x8A93A3))
        }
    }
}

@MainActor
final class MixStore: ObservableObject {
    @Published private(set) var active: [String]
    @Published private(set) var volumes: [String: Double]
    @Published private(set) var master: Double
    @Published private(set) var isPlaying = false {
        didSet { if isPlaying != oldValue, !pomodoroDriving { playbackChangedByUser() } }
    }
    @Published private(set) var userMixes: [Mix]
    /// Running Pomodoro (nil = off).
    @Published private(set) var pomodoro: PomodoroState?
    @Published private(set) var pomodoroRemaining: TimeInterval?
    /// The focus length offered first and used by Start without a choice.
    @Published private(set) var pomodoroPlan: PomodoroPlan
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var theme: PanelTheme {
        didSet { if !Self.sandboxed { defaults.set(theme.rawValue, forKey: "theme") } }
    }
    @Published var backdrop: PanelBackdrop {
        didSet { if !Self.sandboxed { defaults.set(backdrop.rawValue, forKey: "backdrop") } }
    }
    @Published var accent: AccentChoice {
        didSet {
            if !Self.sandboxed { defaults.set(accent.rawValue, forKey: "accent") }
            Theme.accent = accent
        }
    }
    /// Quiet During Calls: fade out while another app is in a call (records and plays).
    @Published var duckDuringCalls: Bool {
        didSet {
            if !Self.sandboxed { defaults.set(duckDuringCalls, forKey: "duckDuringCalls") }
            updateCallWatch()
        }
    }
    /// A call is going on (or just ended) and Murmur has stepped back. The saved volumes, the mix
    /// and play state are untouched — the duck is a separate gain on top of `master`.
    @Published private(set) var isDucked = false

    /// Living Mix: levels slowly wander around the sliders (see `Drift`). On by default.
    @Published var livingMix: Bool {
        didSet {
            if !Self.sandboxed { defaults.set(livingMix, forKey: "livingMix") }
            audio.livingMix = livingMix
        }
    }

    /// Now, for Pomodoro and listening time; tests move it by hand.
    var clock: () -> Date = Date.init
    /// Where the open listening session is saved; nil in the test modes unless a check sets a suite.
    var listeningDefaults: UserDefaults? = MixStore.sandboxed ? nil : .standard
    private var listening: ListeningSession?
    private var listeningSaveTimer: Timer?
    /// Why the next end of a session happens, when it isn't a plain pause or a Pomodoro break.
    private var listeningEndReason: String?
    private var systemAsleep = false
    private var sleepObserver: NSObjectProtocol?

    private let audio = AudioEngine()
    private let defaults = UserDefaults.standard
    private var pomodoroTick: Timer?
    /// Set while Pomodoro itself plays or silences the mix, so that isn't taken for the user's play/pause.
    private var pomodoroDriving = false
    /// Off in tests: no singing bowl at phase changes.
    var cuesEnabled = true
    private var hotKey: HotKey?
    private var wakeObserver: NSObjectProtocol?
    private var duck = DuckEnvelope()
    private var duckTimer: Timer?
    private var mic: MicMonitor?

    /// Focus mix ⇄ break mix crossfade, seconds.
    /// The mix glides out after the break's bowl strike and back in after the focus one.
    static let pomodoroFadeOut: Double = 8
    static let pomodoroFadeIn: Double = 4

    init() {
        active = (defaults.stringArray(forKey: "active") ?? ["rain"]).filter { Sound.byID[$0] != nil }
        volumes = defaults.dictionary(forKey: "volumes") as? [String: Double] ?? [:]
        master = defaults.object(forKey: "master") as? Double ?? 0.8
        theme = PanelTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        backdrop = PanelBackdrop(rawValue: defaults.string(forKey: "backdrop") ?? "") ?? .mix
        let savedAccent = AccentChoice(rawValue: defaults.string(forKey: "accent") ?? "") ?? .system
        accent = savedAccent
        Theme.accent = savedAccent
        livingMix = defaults.object(forKey: "livingMix") as? Bool ?? true
        userMixes = Self.savedUserMixes()
        pomodoroPlan = PomodoroPlan.byID(defaults.string(forKey: "pomodoroPlan"))
        duckDuringCalls = defaults.object(forKey: "duckDuringCalls") as? Bool ?? true
        audio.masterVolume = Self.curve(master)
        audio.livingMix = livingMix

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.togglePlay() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }
        // Test modes must not change their own output level because someone is on a call.
        if !Self.sandboxed {
            mic = MicMonitor { [weak self] inUse in
                MainActor.assumeIsolated { self?.micChanged(inUse) }
            }
            updateCallWatch()
        }
    }

    /// The user's saved mixes as stored in UserDefaults.
    static func savedUserMixes() -> [Mix] {
        guard let data = UserDefaults.standard.data(forKey: "userMixes"),
              let mixes = try? JSONDecoder().decode([Mix].self, from: data) else { return [] }
        return mixes
    }

    // MARK: Queries

    var allMixes: [Mix] { Mix.presets + userMixes }

    func isActive(_ sound: Sound) -> Bool { active.contains(sound.id) }

    func volume(_ sound: Sound) -> Double { volumes[sound.id] ?? sound.defaultVolume }

    func isCurrent(_ mix: Mix) -> Bool { Set(mix.levels.keys) == Set(active) }

    var statusLine: String {
        let names = active.compactMap { Sound.byID[$0]?.name }
        guard !names.isEmpty else { return L("Выберите звуки для микса", "Choose sounds for your mix") }
        var line = names.prefix(2).joined(separator: ", ")
        if names.count > 2 { line += L(" и ещё \(names.count - 2)", " and \(names.count - 2) more") }
        return isPlaying ? line : L("Пауза · ", "Paused · ") + line
    }

    var pomodoroLabel: String? { pomodoroRemaining.map(countdownLabel) }

    // MARK: Playback

    func toggle(_ sound: Sound) {
        if let i = active.firstIndex(of: sound.id) {
            active.remove(at: i)
            if active.isEmpty {
                listeningEndReason = "stop"
                isPlaying = false
            }
        } else {
            active.append(sound.id)
            isPlaying = true
        }
        sync(fade: 0.7)
        persist()
    }

    func setVolume(_ sound: Sound, _ value: Double) {
        volumes[sound.id] = value
        if !active.contains(sound.id) {
            // Dragging a dimmed row's slider switches the sound on, like tapping it.
            active.append(sound.id)
            isPlaying = true
            sync(fade: 0.5)
            persist()
            return
        }
        sync(fade: 0.06)
        persist()
    }

    func setMaster(_ value: Double) {
        master = value
        applyMaster()
        persist()
    }

    func togglePlay() {
        if active.isEmpty {
            randomMix()
            return
        }
        isPlaying.toggle()
        sync(fade: isPlaying ? 1.0 : 0.6)
    }

    /// Resumes the current mix (or picks one at random when nothing is selected).
    func play() {
        if active.isEmpty { return randomMix() }
        guard !isPlaying else { return }
        isPlaying = true
        sync(fade: 1.0)
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        sync(fade: 0.6)
    }

    func stopAll() {
        endPomodoro()
        listeningEndReason = "stop"
        isPlaying = false
        active = []
        sync(fade: 0.6)
        persist()
    }

    func apply(_ mix: Mix) {
        active = Sound.all.map(\.id).filter { mix.levels[$0] != nil }
        for (id, level) in mix.levels { volumes[id] = level }
        isPlaying = true
        sync(fade: 1.4)
        persist()
    }

    /// Shuffle: a random but believable scene — one main sound plus 1–2 that belong with it.
    func randomMix() {
        apply(Mix(id: "random", name: "", emoji: "", levels: Self.randomLevels(avoiding: Set(active))))
    }

    /// A place you could actually be in: the anchor is the main sound, extras only ever join
    /// anchors they make sense with (no campfire under water on a train).
    struct Scene {
        let anchors: [String]
        let extras: [String]
    }

    static let scenes: [Scene] = [
        Scene(anchors: ["rain"], extras: ["cafe", "vinyl", "keyboard", "clock", "cat"]),         // rainy day
        Scene(anchors: ["cafe"], extras: ["rain", "city", "vinyl", "keyboard"]),                // café
        Scene(anchors: ["city"], extras: ["rain", "cafe"]),                                     // city
        Scene(anchors: ["campfire"], extras: ["crickets", "wind", "river"]),                    // campfire at night
        Scene(anchors: ["crickets"], extras: ["river", "wind", "campfire"]),                    // summer night
        Scene(anchors: ["birds", "river"], extras: ["wind", "river", "birds", "bowl"]),         // forest by day
        Scene(anchors: ["waves"], extras: ["wind", "rain"]),                                    // sea
        Scene(anchors: ["underwater", "whale"], extras: ["whale", "underwater"]),               // the deep
        Scene(anchors: ["storm"], extras: ["rain", "wind", "cat", "clock"]),                    // storm outside
        Scene(anchors: ["train"], extras: ["rain", "heartbeat", "vinyl"]),                      // night train
        Scene(anchors: ["bowl"], extras: ["river", "wind", "birds"]),                           // meditation
        Scene(anchors: ["library"], extras: ["clock", "keyboard", "rain"]),                     // library
        Scene(anchors: ["white"], extras: ["rain", "keyboard"]),                                // focus
        Scene(anchors: ["cat"], extras: ["vinyl", "rain", "clock", "heartbeat", "campfire"]),   // cozy
    ]

    static func randomLevels(avoiding current: Set<String> = []) -> [String: Double] {
        for _ in 0..<8 {
            let scene = scenes.randomElement()!
            let anchor = scene.anchors.randomElement()!
            let pool = scene.extras.filter { $0 != anchor }.shuffled()
            let extras = pool.prefix(min(pool.count, Int.random(in: 1...2)))
            var levels = [anchor: Double.random(in: 0.55...0.8)]
            for id in extras { levels[id] = Double.random(in: 0.2...0.45) }
            if Set(levels.keys) != current { return levels }
        }
        return ["rain": 0.6, "cafe": 0.4]
    }

    private func sync(fade: Double) {
        for sound in Sound.all {
            let on = isPlaying && active.contains(sound.id)
            audio.setTarget(sound, gain: on ? Self.curve(volume(sound)) : 0, fade: fade)
        }
        updateListening()
    }

    // MARK: Listening time (analytics)

    /// Opens, advances or ends the listening session after any playback change.
    private func updateListening() {
        let now = clock()
        let open = isPlaying && !active.isEmpty && !systemAsleep
        let playing = open ? Set(active.filter { id in Sound.byID[id].map { volume($0) > 0 } ?? false }) : []
        let reason = listeningEndReason ?? (pomodoroDriving ? "pomodoroBreak" : "pause")
        listeningEndReason = nil
        if var session = listening {
            session.advance(to: now, playing: playing)
            listening = session
            if !open { endListening(reason) }
        } else if open {
            listening = ListeningSession(start: now, playing: playing)
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveListening() }
            }
            RunLoop.main.add(timer, forMode: .common)
            listeningSaveTimer = timer
        }
    }

    private func endListening(_ reason: String) {
        guard let session = listening else { return }
        listening = nil
        listeningSaveTimer?.invalidate()
        listeningSaveTimer = nil
        listeningDefaults?.removeObject(forKey: Self.listeningKey)
        for signal in session.signals(endedBy: reason) {
            Analytics.send(signal.name, signal.parameters, minutes: signal.minutes)
        }
    }

    private static let listeningKey = "listeningSession"

    /// Saves the open session (once a minute while playing), so a crash loses at most a minute.
    func saveListening(endedBy reason: String? = nil) {
        guard var session = listening else { return }
        session.advance(to: clock(), playing: Set(session.playing))
        session.endedBy = reason
        listening = session
        if let data = try? JSONEncoder().encode(session) {
            listeningDefaults?.set(data, forKey: Self.listeningKey)
        }
    }

    /// At quit: the SDK may not get to send anything now, so the session waits for the next launch.
    func saveListeningForQuit() {
        saveListening(endedBy: "quit")
        listening = nil
        listeningSaveTimer?.invalidate()
        listeningSaveTimer = nil
    }

    /// At launch: sends a session saved at quit (`quit`) or left behind by a crash (`recovered`).
    func sendRecoveredListening() {
        guard let defaults = listeningDefaults, let data = defaults.data(forKey: Self.listeningKey) else { return }
        defaults.removeObject(forKey: Self.listeningKey)
        guard let saved = try? JSONDecoder().decode(ListeningSession.self, from: data) else { return }
        for signal in saved.signals(endedBy: saved.endedBy ?? "recovered") {
            Analytics.send(signal.name, signal.parameters, minutes: signal.minutes)
        }
    }

    /// The Mac goes to sleep: the session ends here; waking up while playing starts a new one.
    func systemWillSleep() {
        systemAsleep = true
        listeningEndReason = "sleep"
        updateListening()
    }

    func systemDidWake() {
        systemAsleep = false
        audio.recover()
        updateListening()
    }

    private func applyMaster() {
        audio.masterVolume = Self.curve(master) * duck.gain
    }

    /// Ears hear loudness logarithmically; a power curve makes sliders feel even.
    private static func curve(_ v: Double) -> Float { Float(pow(v, 1.6)) }

    // MARK: Mixes

    func saveCurrentMix(named name: String) {
        guard !active.isEmpty else { return }
        let emojis = ["✨", "🌙", "🍃", "🪐", "🌿", "☁️", "🫧", "🌌"]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let mix = Mix(
            id: UUID().uuidString,
            name: trimmed.isEmpty ? suggestedMixName : trimmed,
            emoji: emojis[userMixes.count % emojis.count],
            levels: Dictionary(uniqueKeysWithValues: active.map { ($0, volumes[$0] ?? Sound.byID[$0]!.defaultVolume) })
        )
        userMixes.append(mix)
        persist()
        mixesChanged()
    }

    /// Snapshot-only: show sample saved mixes without touching the user's data.
    func previewUserMixes(_ mixes: [Mix]) { userMixes = mixes }

    func delete(_ mix: Mix) {
        userMixes.removeAll { $0.id == mix.id }
        persist()
        mixesChanged()
    }

    /// Lets Siri / Spotlight phrases like "Play <mix> in Murmur" learn about new and deleted mixes.
    private func mixesChanged() {
        guard !Self.sandboxed else { return }
        MurmurShortcuts.updateAppShortcutParameters()
    }

    var suggestedMixName: String {
        active.prefix(2).compactMap { Sound.byID[$0]?.name }.joined(separator: " + ")
    }

    // MARK: Pomodoro

    /// Starts (or restarts) Pomodoro with a fresh focus round, `minutes` long or the last length chosen.
    /// The current mix plays; with nothing chosen, the built-in Focus mix starts. No cue at the start.
    func startPomodoro(minutes: Int? = nil) {
        if let minutes {
            pomodoroPlan = PomodoroPlan(focus: min(max(minutes, PomodoroPlan.allowed.lowerBound), PomodoroPlan.allowed.upperBound))
            if !Self.sandboxed { defaults.set(pomodoroPlan.id, forKey: "pomodoroPlan") }
        }
        endPomodoro()
        pomodoro = PomodoroState(plan: pomodoroPlan, start: clock())
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickPomodoro() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pomodoroTick = timer
        setPlayingForPomodoro(true, fade: 1.4)
        tickPomodoro()
    }

    /// Stops Pomodoro and leaves the sound as it is (a break stays quiet).
    func stopPomodoro() {
        endPomodoro()
    }

    /// Ends the current phase now: Take a Break Now / Skip Break.
    func skipPomodoroPhase() {
        guard let state = pomodoro else { return }
        enter(state.advanced(at: clock()))
        tickPomodoro()
    }

    private func endPomodoro() {
        pomodoroTick?.invalidate()
        pomodoroTick = nil
        pomodoro = nil
        pomodoroRemaining = nil
    }

    func tickPomodoro() {
        guard let state = pomodoro else { return }
        let now = clock()
        if !state.isPaused, state.remaining(at: now) <= 0 {
            enter(state.advanced(at: now))
        }
        pomodoroRemaining = pomodoro?.remaining(at: now)
    }

    /// A bowl strike marks every phase change; the mix then fades out for a break and back in for focus.
    private func enter(_ next: PomodoroState) {
        pomodoro = next
        cue(for: next.phase)
        setPlayingForPomodoro(!next.phase.isBreak, fade: next.phase.isBreak ? Self.pomodoroFadeOut : Self.pomodoroFadeIn)
    }

    /// Plays or silences the mix on Pomodoro's behalf — not counted as the user's play/pause.
    private func setPlayingForPomodoro(_ on: Bool, fade: Double) {
        pomodoroDriving = true
        defer { pomodoroDriving = false }
        if on, active.isEmpty, let focus = Mix.presets.first(where: { $0.id == "b.focus" }) {
            apply(focus)
            return
        }
        isPlaying = on
        sync(fade: fade)
    }

    /// The user's play/pause steers a running Pomodoro: pausing during focus freezes the countdown
    /// (focus without sound isn't focus), playing during a break ends the break early.
    private func playbackChangedByUser() {
        guard let state = pomodoro else { return }
        let now = clock()
        if state.phase.isBreak {
            if isPlaying { enter(state.advanced(at: now)) }
        } else if isPlaying, state.isPaused {
            pomodoro = state.resumed(at: now)
        } else if !isPlaying, !state.isPaused {
            pomodoro = state.paused(at: now)
        }
        pomodoroRemaining = pomodoro?.remaining(at: now)
    }

    /// One singing-bowl strike: lower for a break, brighter back to focus.
    private func cue(for phase: PomodoroPhase) {
        guard cuesEnabled, !SelfTest.isRendering else { return }
        audio.playCue(pitch: phase.isBreak ? 0.84 : 1.0)
    }

    /// `--playtest`: the phase-change strike on its own.
    func debugCue() { audio.playCue(pitch: 1.0) }

    func debugMeasure(after delay: Double, seconds: Double, completion: @escaping (Float, Int) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [audio] in
            audio.measureOutput(seconds: seconds, completion: completion)
        }
    }

    // MARK: Calls

    private func updateCallWatch() {
        guard let mic else { return }
        if duckDuringCalls {
            mic.start()
        } else {
            mic.stop()
            duck.cancel(at: Self.now)
            runDuck()
        }
    }

    private func micChanged(_ inUse: Bool) {
        guard duckDuringCalls else { return }
        duck.update(micInUse: inUse, at: Self.now)
        runDuck()
    }

    /// Glides the duck gain at 60 Hz while it's moving (or waiting out the hold), then sleeps.
    private func runDuck() {
        stepDuck()
        guard !duck.isSettled, duckTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepDuck() }
        }
        RunLoop.main.add(timer, forMode: .common)
        duckTimer = timer
    }

    private func stepDuck() {
        duck.advance(to: Self.now)
        if isDucked != duck.ducked { isDucked = duck.ducked }
        // Resume before the fade-in starts; pause only once fully silent.
        audio.isPaused = duck.isSilent
        applyMaster()
        if duck.isSettled {
            duckTimer?.invalidate()
            duckTimer = nil
        }
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: System

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Murmur: login item change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Test modes (`--snapshot`, `--playtest`) run in a sandbox: they read the user's settings
    /// but never write anything back.
    static var sandboxed = false

    private func persist() {
        guard !Self.sandboxed else { return }
        defaults.set(active, forKey: "active")
        defaults.set(volumes, forKey: "volumes")
        defaults.set(master, forKey: "master")
        if let data = try? JSONEncoder().encode(userMixes) {
            defaults.set(data, forKey: "userMixes")
        }
    }
}

/// System-wide shortcut via Carbon — works without Accessibility permissions.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x4D52_4D52), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
