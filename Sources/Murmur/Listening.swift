import Foundation

/// One continuous stretch of listening, for analytics: how long it lasted and how long each sound played.
/// `MixStore` advances it on every playback change and saves it while it's open, so a quit or a crash
/// doesn't lose it — the next launch sends what was saved.
struct ListeningSession: Codable, Equatable {
    var start: Date
    var lastUpdate: Date
    /// Sounds playing since `lastUpdate` (sorted ids).
    var playing: [String]
    /// Seconds each sound has played so far.
    var seconds: [String: Double] = [:]
    /// Set when the session was saved at quit; nil for the periodic save (a crash, if found at launch).
    var endedBy: String?

    /// Shorter sessions, and shorter shares of a sound in a session, aren't sent.
    static let minimum: TimeInterval = 30

    init(start: Date, playing: Set<String>) {
        self.start = start
        lastUpdate = start
        self.playing = playing.sorted()
    }

    /// Credits the time since the last update to what was playing, then switches to `playing`.
    mutating func advance(to now: Date, playing new: Set<String>) {
        let elapsed = max(now.timeIntervalSince(lastUpdate), 0)
        for id in playing { seconds[id, default: 0] += elapsed }
        playing = new.sorted()
        lastUpdate = now
    }

    /// `Listening.ended`, then one `Sound.listened` per sound that played long enough.
    func signals(endedBy reason: String) -> [AnalyticsSignal] {
        let total = lastUpdate.timeIntervalSince(start)
        guard total >= Self.minimum else { return [] }
        let counted = seconds.filter { $0.value >= Self.minimum }.keys.sorted()
        let ended = AnalyticsSignal(
            name: "Listening.ended",
            parameters: ["endedBy": reason, "soundCount": String(counted.count), "sounds": counted.joined(separator: ",")],
            minutes: total / 60
        )
        return [ended] + counted.map {
            AnalyticsSignal(name: "Sound.listened", parameters: ["sound": $0], minutes: seconds[$0]! / 60)
        }
    }
}
