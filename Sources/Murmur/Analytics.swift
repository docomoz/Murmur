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
        let config = TelemetryDeck.Config(appID: appID)
        // `App.launched` carries the same information plus the settings, so skip the SDK's own signal.
        config.sendNewSessionBeganSignal = false
        if ProcessInfo.processInfo.environment["MURMUR_ANALYTICS_LOG"] == "1" {
            config.logHandler = LogHandler(logLevel: .debug) { level, message in
                print("[TelemetryDeck] \(level): \(message)")
            }
        }
        TelemetryDeck.initialize(config: config)
        isLive = true
    }

    static func send(_ name: String, _ parameters: [String: String] = [:], minutes: Double? = nil) {
        let signal = AnalyticsSignal(name: name, parameters: parameters, minutes: minutes.map { ($0 * 10).rounded() / 10 })
        capture?(signal)
        guard isLive else { return }
        TelemetryDeck.signal(signal.name, parameters: signal.parameters, floatValue: signal.minutes)
    }
}
