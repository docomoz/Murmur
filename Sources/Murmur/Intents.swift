import AppIntents
import AppKit

// App Intents: Shortcuts actions, Spotlight, Siri and a Focus filter.
//
// Everything that ends up in `Metadata.appintents` (titles, descriptions, parameter titles,
// App Shortcut phrases) must be a plain string literal: build.sh extracts it at compile time
// (`-emit-const-values` + `appintentsmetadataprocessor`), so the `L(…)` helper can't be used here.
// The literals are the Russian text; English comes from Resources/Localization/en.lproj
// (`Localizable.strings` for titles, `AppShortcuts.strings` for phrases) — keep them in sync.
//
// Intents run inside the menu bar app itself (no extension): the system launches Murmur in the
// background if it isn't running, and `perform()` reaches the app's `MixStore` on the main actor.

enum MurmurIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case mixNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: "Murmur ещё не запустился, попробуйте ещё раз."
        case .mixNotFound: "Такого микса больше нет."
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
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Микс"
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
    static let title: LocalizedStringResource = "Включить микс"
    static let description = IntentDescription("Включает готовый или сохранённый микс Murmur.")
    static let openAppWhenRun = false

    @Parameter(title: "Микс", requestValueDialog: "Какой микс включить?")
    var mix: MixEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Включить микс \(\.$mix)")
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
    static let title: LocalizedStringResource = "Наугад"
    static let description = IntentDescription("Включает случайный, но правдоподобный микс: главный звук и один-два подходящих к нему.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().randomMix()
        return .result()
    }
}

struct TogglePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Пауза / Играть"
    static let description = IntentDescription("Ставит звук на паузу или продолжает играть. Если ничего не выбрано, включает микс наугад.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().togglePlay()
        return .result()
    }
}

struct PlayIntent: AppIntent {
    static let title: LocalizedStringResource = "Играть"
    static let description = IntentDescription("Продолжает играть текущий микс. Если ничего не выбрано, включает микс наугад.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().play()
        return .result()
    }
}

struct PauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Пауза"
    static let description = IntentDescription("Ставит звук на паузу; микс сохраняется.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().pause()
        return .result()
    }
}

struct StopIntent: AppIntent {
    static let title: LocalizedStringResource = "Остановить"
    static let description = IntentDescription("Выключает все звуки и таймер сна.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().stopAll()
        return .result()
    }
}

struct SleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Таймер сна"
    static let description = IntentDescription("Через заданное время звук плавно стихнет. Если ничего не играет, включится текущий микс.")
    static let openAppWhenRun = false

    @Parameter(title: "Минуты", default: 30, inclusiveRange: (1, 720))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Таймер сна на \(\.$minutes) мин")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().startTimer(minutes: minutes)
        return .result()
    }
}

struct CancelSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Выключить таймер сна"
    static let description = IntentDescription("Отменяет таймер сна; звук продолжает играть.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try MixStore.forIntents().cancelTimer()
        return .result()
    }
}

struct SetVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Громкость Murmur"
    static let description = IntentDescription("Устанавливает общую громкость Murmur.")
    static let openAppWhenRun = false

    @Parameter(title: "Громкость", default: 60, controlStyle: .slider, inclusiveRange: (0, 100))
    var percent: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Громкость Murmur: \(\.$percent)")
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
    static let title: LocalizedStringResource = "Микс Murmur"
    static let description: IntentDescription? = IntentDescription("Включает микс, когда включается режим фокусирования.")

    @Parameter(title: "Микс")
    var mix: MixEntity?

    @Parameter(title: "Пауза, когда режим выключится", default: true)
    var pauseWhenOff: Bool

    var displayRepresentation: DisplayRepresentation {
        guard let mix else { return DisplayRepresentation(title: "Без микса") }
        return pauseWhenOff
            ? DisplayRepresentation(title: "\(mix.name)", subtitle: "Пауза, когда режим выключится")
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
                "Включи \(\.$mix) в \(.applicationName)",
                "Включи микс в \(.applicationName)",
            ],
            shortTitle: "Включить микс",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: ShuffleIntent(),
            phrases: [
                "\(.applicationName) наугад",
                "Включи что-нибудь в \(.applicationName)",
            ],
            shortTitle: "Наугад",
            systemImageName: "dice"
        )
        AppShortcut(
            intent: PauseIntent(),
            phrases: ["Пауза в \(.applicationName)", "Поставь \(.applicationName) на паузу"],
            shortTitle: "Пауза",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: PlayIntent(),
            phrases: ["Продолжи \(.applicationName)", "Играй в \(.applicationName)"],
            shortTitle: "Играть",
            systemImageName: "play"
        )
        AppShortcut(
            intent: StopIntent(),
            phrases: ["Выключи \(.applicationName)", "Останови \(.applicationName)"],
            shortTitle: "Остановить",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: SleepTimerIntent(),
            phrases: ["Таймер сна в \(.applicationName)", "Включи таймер сна в \(.applicationName)"],
            shortTitle: "Таймер сна",
            systemImageName: "moon.zzz"
        )
    }
}
