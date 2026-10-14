import Foundation

/// One Pomodoro rhythm: focus of the chosen length, a 5-minute break, and a 15-minute one after every
/// `longEvery` focus rounds. Breaks are the same for every focus length.
struct PomodoroPlan: Hashable, Identifiable {
    /// Minutes.
    let focus: Int

    static let shortBreak = 5
    static let longBreak = 15
    /// Every 4th break is a long one.
    static let longEvery = 4

    /// Focus lengths offered in the menu; Shortcuts may ask for any length in `allowed`.
    static let presets = [15, 20, 25, 30, 45].map(PomodoroPlan.init(focus:))
    static let standard = PomodoroPlan(focus: 25)
    static let allowed = 1...180

    var id: String { String(focus) }
    static func byID(_ id: String?) -> PomodoroPlan {
        guard let minutes = id.flatMap(Int.init), allowed.contains(minutes) else { return standard }
        return PomodoroPlan(focus: minutes)
    }

    var title: String { L("Фокус \(focus) мин", "Focus \(focus) min") }

    /// Phases run focus, break, focus, break… — even indices are focus, odd ones are breaks,
    /// and break number `longEvery`, `2 × longEvery`, … is long.
    func phase(at index: Int) -> PomodoroPhase {
        if index % 2 == 0 { return .focus }
        return ((index + 1) / 2) % Self.longEvery == 0 ? .longBreak : .shortBreak
    }

    func duration(of phase: PomodoroPhase) -> TimeInterval {
        let minutes = switch phase {
        case .focus: focus
        case .shortBreak: Self.shortBreak
        case .longBreak: Self.longBreak
        }
        return TimeInterval(minutes * 60)
    }
}

enum PomodoroPhase: Equatable {
    case focus, shortBreak, longBreak

    var isBreak: Bool { self != .focus }

    var title: String {
        switch self {
        case .focus: L("Фокус", "Focus")
        case .shortBreak: L("Перерыв", "Break")
        case .longBreak: L("Длинный перерыв", "Long break")
        }
    }

    /// Short word for the footer pill.
    var shortTitle: String { self == .focus ? L("Фокус", "Focus") : L("Перерыв", "Break") }

    var symbol: String { self == .focus ? "scope" : "cup.and.saucer" }
}

/// Where a running Pomodoro is: which phase and when it ends. Pure value — `MixStore` drives it
/// with a timer, `--selftest` checks the sequence and the timing math.
struct PomodoroState: Equatable {
    let plan: PomodoroPlan
    /// 0 = first focus, 1 = first break, …
    private(set) var index: Int
    private(set) var end: Date
    /// Time left when the user paused the mix during focus; the countdown stands still meanwhile.
    private(set) var pausedLeft: TimeInterval?

    /// A phase that ended up to this late (timer jitter, a busy main thread) still hands its exact
    /// end time to the next one; later than that (the Mac slept) the next phase starts now.
    static let catchUp: TimeInterval = 5

    init(plan: PomodoroPlan, start: Date) {
        self.plan = plan
        index = 0
        end = start.addingTimeInterval(plan.duration(of: .focus))
    }

    var phase: PomodoroPhase { plan.phase(at: index) }
    /// Focus round within the current set of `longEvery`, 1-based.
    var round: Int { index / 2 % PomodoroPlan.longEvery + 1 }

    var isPaused: Bool { pausedLeft != nil }

    func remaining(at now: Date) -> TimeInterval { pausedLeft ?? max(end.timeIntervalSince(now), 0) }

    /// Freezes the countdown at what's left now.
    func paused(at now: Date) -> PomodoroState {
        var next = self
        next.pausedLeft = remaining(at: now)
        return next
    }

    /// Continues the countdown from where it was frozen.
    func resumed(at now: Date) -> PomodoroState {
        guard let left = pausedLeft else { return self }
        var next = self
        next.pausedLeft = nil
        next.end = now.addingTimeInterval(left)
        return next
    }

    /// The next phase, begun at the old phase's end — or now, if that was long ago (sleep) or
    /// hasn't come yet (the phase is skipped).
    func advanced(at now: Date) -> PomodoroState {
        var next = self
        next.index += 1
        next.pausedLeft = nil
        let start = (0...Self.catchUp).contains(now.timeIntervalSince(end)) ? end : now
        next.end = start.addingTimeInterval(plan.duration(of: next.phase))
        return next
    }
}

/// `m:ss` below an hour, `h:mm:ss` above.
func countdownLabel(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.up))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}
