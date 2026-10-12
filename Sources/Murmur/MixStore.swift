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
    @Published private(set) var isPlaying = false
    @Published private(set) var userMixes: [Mix]
    @Published private(set) var timerRemaining: TimeInterval?
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
    /// «Тише во время созвонов»: fade out while another app records from a microphone.
    @Published var duckDuringCalls: Bool {
        didSet {
            if !Self.sandboxed { defaults.set(duckDuringCalls, forKey: "duckDuringCalls") }
            updateCallWatch()
        }
    }
    /// A call is going on (or just ended) and Murmur has stepped back. The saved volumes, the mix
    /// and play state are untouched — the duck is a separate gain on top of `master`.
    @Published private(set) var isDucked = false

    private let audio = AudioEngine()
    private let defaults = UserDefaults.standard
    private var timerEnd: Date?
    private var timerTick: Timer?
    private var timerFade: Double = 1
    private var hotKey: HotKey?
    private var wakeObserver: NSObjectProtocol?
    private var duck = DuckEnvelope()
    private var duckTimer: Timer?
    private var mic: MicMonitor?

    static let timerOptions = [15, 30, 45, 60, 90, 120]
    static let timerFadeOut: TimeInterval = 45

    init() {
        active = (defaults.stringArray(forKey: "active") ?? ["rain"]).filter { Sound.byID[$0] != nil }
        volumes = defaults.dictionary(forKey: "volumes") as? [String: Double] ?? [:]
        master = defaults.object(forKey: "master") as? Double ?? 0.8
        theme = PanelTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        backdrop = PanelBackdrop(rawValue: defaults.string(forKey: "backdrop") ?? "") ?? .mix
        let savedAccent = AccentChoice(rawValue: defaults.string(forKey: "accent") ?? "") ?? .system
        accent = savedAccent
        Theme.accent = savedAccent
        duckDuringCalls = defaults.object(forKey: "duckDuringCalls") as? Bool ?? true
        if let data = defaults.data(forKey: "userMixes"), let mixes = try? JSONDecoder().decode([Mix].self, from: data) {
            userMixes = mixes
        } else {
            userMixes = []
        }
        audio.masterVolume = Self.curve(master)

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.togglePlay() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.audio.recover() }
        }
        // Test modes must not change their own output level because someone is on a call.
        if !Self.sandboxed {
            mic = MicMonitor { [weak self] inUse in
                MainActor.assumeIsolated { self?.micChanged(inUse) }
            }
            updateCallWatch()
        }
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

    var timerLabel: String? {
        guard let left = timerRemaining else { return nil }
        let s = Int(left.rounded(.up))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Playback

    func toggle(_ sound: Sound) {
        if let i = active.firstIndex(of: sound.id) {
            active.remove(at: i)
            if active.isEmpty { isPlaying = false }
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

    func stopAll() {
        isPlaying = false
        active = []
        sync(fade: 0.6)
        cancelTimer()
        persist()
    }

    func apply(_ mix: Mix) {
        active = Sound.all.map(\.id).filter { mix.levels[$0] != nil }
        for (id, level) in mix.levels { volumes[id] = level }
        isPlaying = true
        sync(fade: 1.4)
        persist()
    }

    /// «Наугад»: a random but believable scene — one main sound plus 1–2 that belong with it.
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
        Scene(anchors: ["rain"], extras: ["cafe", "vinyl", "keyboard", "clock", "cat"]),         // дождливый день
        Scene(anchors: ["cafe"], extras: ["rain", "city", "vinyl", "keyboard"]),                // кафе
        Scene(anchors: ["city"], extras: ["rain", "cafe"]),                                     // город
        Scene(anchors: ["campfire"], extras: ["crickets", "wind", "river"]),                    // костёр ночью
        Scene(anchors: ["crickets"], extras: ["river", "wind", "campfire"]),                    // летняя ночь
        Scene(anchors: ["birds", "river"], extras: ["wind", "river", "birds", "bowl"]),         // лес днём
        Scene(anchors: ["waves"], extras: ["wind", "rain"]),                                    // море
        Scene(anchors: ["underwater", "whale"], extras: ["whale", "underwater"]),               // глубина
        Scene(anchors: ["storm"], extras: ["rain", "wind", "cat", "clock"]),                    // гроза за окном
        Scene(anchors: ["train"], extras: ["rain", "heartbeat", "vinyl"]),                      // ночной поезд
        Scene(anchors: ["bowl"], extras: ["river", "wind", "birds"]),                           // медитация
        Scene(anchors: ["library"], extras: ["clock", "keyboard", "rain"]),                     // библиотека
        Scene(anchors: ["white"], extras: ["rain", "keyboard"]),                                // фокус
        Scene(anchors: ["cat"], extras: ["vinyl", "rain", "clock", "heartbeat", "campfire"]),   // уют
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
    }

    private func applyMaster() {
        audio.masterVolume = Self.curve(master) * Float(timerFade) * duck.gain
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
    }

    /// Snapshot-only: show sample saved mixes without touching the user's data.
    func previewUserMixes(_ mixes: [Mix]) { userMixes = mixes }

    func delete(_ mix: Mix) {
        userMixes.removeAll { $0.id == mix.id }
        persist()
    }

    var suggestedMixName: String {
        active.prefix(2).compactMap { Sound.byID[$0]?.name }.joined(separator: " + ")
    }

    // MARK: Sleep timer

    func startTimer(minutes: Int) {
        timerEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        if !isPlaying { togglePlay() }
        timerTick?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickTimer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        timerTick = timer
        tickTimer()
    }

    func cancelTimer() {
        timerTick?.invalidate()
        timerTick = nil
        timerEnd = nil
        timerRemaining = nil
        timerFade = 1
        applyMaster()
    }

    private func tickTimer() {
        guard let end = timerEnd else { return }
        let left = end.timeIntervalSinceNow
        if left <= 0 {
            isPlaying = false
            sync(fade: 0.3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.cancelTimer() }
            }
            timerTick?.invalidate()
            timerTick = nil
            timerEnd = nil
            timerRemaining = nil
            return
        }
        timerRemaining = left
        // Drift off gently instead of cutting the sound.
        timerFade = min(1, left / Self.timerFadeOut)
        applyMaster()
    }

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
