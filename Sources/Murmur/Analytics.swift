import Foundation
import TelemetryDeck

// Anonymous usage statistics (TelemetryDeck). This is the only file that talks to the SDK: the rest of
// the app calls `Analytics.send`. Nothing personal goes out — no mix names, nothing about other apps;
// sounds and presets are sent by their internal ids. Event names and parameters:
// docs/superpowers/specs/2026-10-15-usage-analytics-design.md.

/// One signal as it goes to TelemetryDeck (also what `--selftest` captures).
struct AnalyticsSignal: Equatable {
    let name: String
    let parameters: [String: String]
    /// Durations, in minutes rounded to 0.1.
    let minutes: Double?
}

/// Where an action came from.
enum AnalyticsSource: String {
    case panel, intent, focusFilter
}

@MainActor
enum Analytics {
    private(set) static var isLive = false
    /// Test hook: receives every signal, live or not.
    static var capture: ((AnalyticsSignal) -> Void)?

    /// The App ID build.sh writes into Info.plist; nil means analytics is off for this build.
    static var appIDFromBundle: String? {
        Bundle.main.object(forInfoDictionaryKey: "TelemetryDeckAppID") as? String
    }

    /// Starts the SDK. A no-op without an App ID and in the test modes (`MixStore.sandboxed`).
    static func start(appID: String?) {
        guard !isLive, let appID, !appID.isEmpty, !MixStore.sandboxed else { return }
        let config = makeConfig(appID: appID)
        if ProcessInfo.processInfo.environment["MURMUR_ANALYTICS_LOG"] == "1" {
            config.logHandler = LogHandler(logLevel: .debug) { level, message in
                print("[TelemetryDeck] \(level): \(message)")
            }
        }
        TelemetryDeck.initialize(config: config)
        isLive = true
    }

    private static func makeConfig(appID: String) -> TelemetryDeck.Config {
        let config = TelemetryDeck.Config(appID: appID)
        // `App.launched` carries the same information plus the settings, so skip the SDK's own signal.
        config.sendNewSessionBeganSignal = false
        // Session stats run a 1 s main-thread timer that writes UserDefaults every tick, and on macOS it
        // only stops when the app resigns active — which a menu bar app may never do. That's the idle
        // wakeup kind of regression 1.11.1 fixed; the SDK's Retention.* parameters aren't worth it.
        config.sessionStatsEnabled = false
        // The SDK retries its upload every transmitInterval even with nothing to send; 5 min is plenty
        // (signals also go out at launch, and unsent ones are saved at quit).
        config.transmitInterval = 300
        return config
    }

    /// What the SDK will do while Murmur sits idle in the menu bar (checked by `--selftest`).
    static func idleBehaviour(appID: String) -> (sessionStats: Bool, transmitInterval: TimeInterval) {
        let config = makeConfig(appID: appID)
        return (config.sessionStatsEnabled, config.transmitInterval)
    }

    /// Uploads what's queued now instead of waiting for the next transmit interval (used once at launch).
    static func flush() {
        guard isLive else { return }
        TelemetryDeck.requestImmediateSync()
    }

    static func send(_ name: String, _ parameters: [String: String] = [:], minutes: Double? = nil) {
        let signal = AnalyticsSignal(name: name, parameters: parameters, minutes: minutes.map { ($0 * 10).rounded() / 10 })
        capture?(signal)
        guard isLive else { return }
        TelemetryDeck.signal(signal.name, parameters: signal.parameters, floatValue: signal.minutes)
    }
}
