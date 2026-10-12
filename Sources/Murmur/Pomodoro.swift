import Foundation

/// One Pomodoro rhythm: focus, a short break, and a long break after every `longEvery` focus rounds.
struct PomodoroPlan: Hashable, Identifiable {
    let id: String
    /// Minutes.
    let focus: Int
    let shortBreak: Int
    let longBreak: Int

    /// Every 4th break is a long one.
    static let longEvery = 4

    static let presets: [PomodoroPlan] = [
        PomodoroPlan(id: "25", focus: 25, shortBreak: 5, longBreak: 15),
        PomodoroPlan(id: "50", focus: 50, shortBreak: 10, longBreak: 30),
        PomodoroPlan(id: "90", focus: 90, shortBreak: 20, longBreak: 30),
    ]
    static let standard = presets[0]
    static func byID(_ id: String?) -> PomodoroPlan { presets.first { $0.id == id } ?? standard }

    var title: String {
        L("Фокус \(focus) · перерыв \(shortBreak) мин", "Focus \(focus) · break \(shortBreak) min")
    }

    /// Phases run focus, break, focus, break… — even indices are focus, odd ones are breaks,
    /// and break number `longEvery`, `2 × longEvery`, … is long.
    func phase(at index: Int) -> PomodoroPhase {
        if index % 2 == 0 { return .focus }
        return ((index + 1) / 2) % Self.longEvery == 0 ? .longBreak : .shortBreak
    }

    func duration(of phase: PomodoroPhase) -> TimeInterval {
        let minutes = switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
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

    var symbol: String { self == .focus ? "brain.head.profile" : "cup.and.saucer" }
}

/// Where a running Pomodoro is: which phase and when it ends. Pure value — `MixStore` drives it
/// with a timer, `--selftest` checks the sequence and the timing math.
struct PomodoroState: Equatable {
    let plan: PomodoroPlan
    /// 0 = first focus, 1 = first break, …
    private(set) var index: Int
    private(set) var end: Date

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

    func remaining(at now: Date) -> TimeInterval { max(end.timeIntervalSince(now), 0) }

    /// The next phase, begun at the old phase's end — or now, if that was long ago (sleep) or
    /// hasn't come yet (the phase is skipped).
    func advanced(at now: Date) -> PomodoroState {
        var next = self
        next.index += 1
        let start = (0...Self.catchUp).contains(now.timeIntervalSince(end)) ? end : now
        next.end = start.addingTimeInterval(plan.duration(of: next.phase))
        return next
    }
}

/// `m:ss` below an hour, `h:mm:ss` above — shared by the sleep timer and Pomodoro.
func countdownLabel(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.up))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}
