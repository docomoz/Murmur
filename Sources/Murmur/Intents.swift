import AppIntents
import AppKit

// App Intents: Shortcuts actions, Spotlight, Siri and a Focus filter.
//
// Everything that ends up in `Metadata.appintents` (titles, descriptions, parameter titles,
// App Shortcut phrases) must be a plain string literal: build.sh extracts it at compile time
// (`-emit-const-values` + `appintentsmetadataprocessor`), so the `L(…)` helper can't be used here.
// The literals are the English text; Russian comes from Resources/Localization/ru.lproj
// (`Localizable.strings` for titles, `AppShortcuts.strings` for phrases) — keep them in sync.
//
// Intents run inside the menu bar app itself (no extension): the system launches Murmur in the
// background if it isn't running, and `perform()` reaches the app's `MixStore` on the main actor.

enum MurmurIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case mixNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: "Murmur hasn't started yet, please try again."
        case .mixNotFound: "This mix no longer exists."
        }
    }
}

extension MixStore {
    /// The store of the running app; intents are always performed inside the app process.
    @MainActor
    static func forIntents() throws -> MixStore {
        guard let store = (NSApp.delegate as? AppDelegate)?.store else { throw MurmurIntentError.notRunning }
        return store
    }

    /// Mixes offered to the system: built-in presets plus the user's own.
    @MainActor
    static var mixesForIntents: [Mix] {
        (NSApp.delegate as? AppDelegate)?.store.allMixes ?? Mix.presets + savedUserMixes()
    }
}

// MARK: Mix entity

struct MixEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mix"
    static let defaultQuery = MixQuery()

    let id: String
    let name: String
    let sounds: String

    init(_ mix: Mix) {
        id = mix.id
        name = mix.name
        sounds = Sound.all.filter { mix.levels[$0.id] != nil }.map(\.name).joined(separator: ", ")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(sounds)")
    }
}

struct MixQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MixEntity] {
        let mixes = MixStore.mixesForIntents
        return identifiers.compactMap { id in mixes.first { $0.id == id }.map(MixEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MixEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return MixStore.mixesForIntents
            .filter { $0.name.localizedStandardContains(query) }
            .map(MixEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [MixEntity] {
        MixStore.mixesForIntents.map(MixEntity.init)
    }
}

// MARK: Playback

struct PlayMixIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Mix"
    static let description = IntentDescription("Plays a built-in or saved Murmur mix.")
    static let openAppWhenRun = false

    @Parameter(title: "Mix", requestValueDialog: "Which mix?")
    var mix: MixEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play mix \(\.$mix)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = try MixStore.forIntents()
        guard let found = store.allMixes.first(where: { $0.id == mix.id }) else { throw MurmurIntentError.mixNotFound }
        store.apply(found)
        return .result()
    }
}

struct ShuffleIntent: AppIntent {
    static let title: LocalizedStringResource = "Shuffle"
    static let description = IntentDescription("Plays a random but believable mix: one main sound plus one or two that belong with it.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().randomMix()
        return .result()
    }
}

struct TogglePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Play / Pause"
    static let description = IntentDescription("Pauses or resumes the sound. If nothing is selected, plays a random mix.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().togglePlay()
        return .result()
    }
}

struct PlayIntent: AppIntent {
    static let title: LocalizedStringResource = "Play"
    static let description = IntentDescription("Resumes the current mix. If nothing is selected, plays a random mix.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().play()
        return .result()
    }
}

struct PauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause"
    static let description = IntentDescription("Pauses the sound and keeps the mix.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().pause()
        return .result()
    }
}

struct StopIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop"
    static let description = IntentDescription("Turns off all sounds and the Pomodoro timer.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().stopAll()
        return .result()
    }
}

struct StartPomodoroIntent: AppIntent {
    static let title: LocalizedStringResource = "Pomodoro Timer"
    static let description = IntentDescription("Starts a Pomodoro: focus with the current mix, then a quiet break. If nothing is selected, the Focus mix starts.")
    static let openAppWhenRun = false

    @Parameter(title: "Focus Minutes", default: 25, inclusiveRange: (1, 180))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Pomodoro: \(\.$minutes) min focus")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().startPomodoro(minutes: minutes)
        return .result()
    }
}

struct StopPomodoroIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Pomodoro"
    static let description = IntentDescription("Stops the Pomodoro timer; the sound stays as it is.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().stopPomodoro()
        return .result()
    }
}

struct SetVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Murmur Volume"
    static let description = IntentDescription("Sets Murmur's overall volume.")
    static let openAppWhenRun = false

    @Parameter(title: "Volume", default: 60, controlStyle: .slider, inclusiveRange: (0, 100))
    var percent: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Murmur volume: \(\.$percent)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().setMaster(min(max(percent, 0), 100) / 100)
        return .result()
    }
}

// MARK: Focus filter

/// Settings → Focus → (a Focus) → Focus Filters → Murmur: start a mix when the Focus turns on,
/// optionally pause it when the Focus ends.
///
/// The system calls `perform()` when the Focus turns on (with the chosen values) and again when it
/// turns off (with default values, i.e. no mix) — so whether to pause is remembered at activation.
struct MurmurFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Murmur Mix"
    static let description: IntentDescription? = IntentDescription("Plays a mix when the Focus turns on.")

    @Parameter(title: "Mix")
    var mix: MixEntity?

    @Parameter(title: "Pause when the Focus ends", default: true)
    var pauseWhenOff: Bool

    var displayRepresentation: DisplayRepresentation {
        guard let mix else { return DisplayRepresentation(title: "No mix") }
        return pauseWhenOff
            ? DisplayRepresentation(title: "\(mix.name)", subtitle: "Pause when the Focus ends")
            : DisplayRepresentation(title: "\(mix.name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = try MixStore.forIntents()
        if let mix, let found = store.allMixes.first(where: { $0.id == mix.id }) {
            store.apply(found)
            FocusSession.started(mixID: found.id, pauseWhenOff: pauseWhenOff)
        } else if let session = FocusSession.end(), session.pauseWhenOff,
                  let started = store.allMixes.first(where: { $0.id == session.mixID }),
                  store.isPlaying, store.isCurrent(started) {
            // Only pause what the Focus itself started; if the user switched sounds since, leave them.
            store.pause()
        }
        return .result()
    }
}

/// What the Focus filter started, kept across app restarts until the Focus ends.
@MainActor
enum FocusSession {
    private static let key = "focusSession"

    static func started(mixID: String, pauseWhenOff: Bool) {
        guard !MixStore.sandboxed else { return }
        UserDefaults.standard.set(["mix": mixID, "pause": pauseWhenOff], forKey: key)
    }

    /// Clears the session and returns it, if there was one.
    static func end() -> (mixID: String, pauseWhenOff: Bool)? {
        guard let saved = UserDefaults.standard.dictionary(forKey: key), let mix = saved["mix"] as? String else { return nil }
        if !MixStore.sandboxed { UserDefaults.standard.removeObject(forKey: key) }
        return (mix, saved["pause"] as? Bool ?? false)
    }
}

// MARK: App Shortcuts (Spotlight / Siri without any setup)

struct MurmurShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMixIntent(),
            phrases: [
                "Play \(\.$mix) in \(.applicationName)",
                "Play a mix in \(.applicationName)",
            ],
            shortTitle: "Play Mix",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: ShuffleIntent(),
            phrases: [
                "Shuffle \(.applicationName)",
                "Play something in \(.applicationName)",
            ],
            shortTitle: "Shuffle",
            systemImageName: "dice"
        )
        AppShortcut(
            intent: PauseIntent(),
            phrases: ["Pause \(.applicationName)", "Pause sounds in \(.applicationName)"],
            shortTitle: "Pause",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: PlayIntent(),
            phrases: ["Resume \(.applicationName)", "Play \(.applicationName)"],
            shortTitle: "Play",
            systemImageName: "play"
        )
        AppShortcut(
            intent: StopIntent(),
            phrases: ["Turn off \(.applicationName)", "Stop \(.applicationName)"],
            shortTitle: "Stop",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: StartPomodoroIntent(),
            phrases: ["Pomodoro in \(.applicationName)", "Start a Pomodoro in \(.applicationName)"],
            shortTitle: "Pomodoro",
            systemImageName: "timer"
        )
    }
}
