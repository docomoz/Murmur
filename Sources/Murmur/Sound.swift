import SwiftUI

/// Interface language: Russian when it's the first language on the Mac, English otherwise.
enum Lang {
    static let isRussian = Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") ?? false
}

/// Picks the Russian or English variant of a UI string.
func L(_ ru: String, _ en: String) -> String { Lang.isRussian ? ru : en }

enum SoundSource: Hashable {
    case file(String)
    case whiteNoise
    case heartbeat
}

enum SoundCategory: String, CaseIterable, Identifiable {
    case water = "Дождь и вода"
    case nature = "Природа"
    case city = "Город"
    case rhythm = "Дом"
    case noise = "Шум"

    var id: String { rawValue }
}

/// One stream of grains cut from a recording. Grains of random length start at random places,
/// play at a slightly random speed (= pitch), and crossfade into each other, so the sound never
/// repeats the way a loop does.
struct Layer {
    /// Recording to cut from; `nil` = the sound's own file.
    var file: String? = nil
    /// Grain length, seconds.
    var length: ClosedRange<Double> = 8...16
    /// Equal-power crossfade between grains, seconds.
    var fade: Double = 2.5
    /// Playback speed per grain (1.03 = 3 % faster and higher).
    var rate: ClosedRange<Double> = 0.985...1.015
    var gainDB: Double = 0
    var gainJitterDB: Double = 1.5
    /// Max random stereo offset per grain, 0…1.
    var pan: Double = 0
    /// Randomly mirror left/right per grain (stereo recordings only).
    var swapChannels = true
    /// Silence between grains, seconds. Non-zero makes a sparse layer of occasional events.
    var gap: ClosedRange<Double> = 0...0
    /// Event mode for one-shot recordings (a singing bowl strike): the whole recording plays from
    /// its start every `events` seconds, overlapping the previous ring-out. `length`/`fade`/`gap` are ignored.
    var events: ClosedRange<Double>? = nil
}

/// Exact loop window for rhythmic recordings, where a long crossfade would double the beats.
struct LoopRegion: Hashable {
    var start: Double
    var length: Double
}

struct Sound: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let category: SoundCategory
    let tint: Color
    let source: SoundSource
    var crossfade: Double = 2.5
    var region: LoopRegion? = nil
    var defaultVolume: Double = 0.6
    /// Extra gain for recordings whose loud transients make them sound quieter than their peers.
    var boost: Float = 1
    /// How the recording is turned into an endless texture (ignored for loops with a `region`).
    var layers: [Layer] = [Layer()]
    /// «Живой микс»: how far (±dB) the level slowly wanders around the slider over minutes.
    /// 0 = steady (the clock's exact rhythm, the heartbeat). See `Drift`.
    var drift: Double = 2

    static func == (a: Sound, b: Sound) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

extension Sound {
    static let all: [Sound] = [
        // Дождь и вода
        Sound(id: "rain", name: L("Дождь", "Rain"), symbol: "cloud.rain", category: .water, tint: Color(hex: 0x4F8EF7), source: .file("rain"), drift: 2.5),
        Sound(id: "storm", name: L("Гроза", "Thunderstorm"), symbol: "cloud.bolt.rain", category: .water, tint: Color(hex: 0x7C6CF2), source: .file("storm"),
              layers: [Layer(length: 6...14, fade: 3, rate: 0.95...1.05),
                       // Distant rolls of thunder: lower, quieter, now and then.
                       Layer(length: 5...10, fade: 2.5, rate: 0.78...0.9, gainDB: -8, pan: 0.6, gap: 6...20)],
              drift: 2.5),
        Sound(id: "waves", name: L("Морской прибой", "Ocean Waves"), symbol: "water.waves", category: .water, tint: Color(hex: 0x14A9D6), source: .file("waves"),
              layers: [Layer(length: 8...16, fade: 3, rate: 0.97...1.03)]),
        Sound(id: "river", name: L("Ручей", "Stream"), symbol: "drop", category: .water, tint: Color(hex: 0x1FBFB0), source: .file("river"), drift: 1.5),
        Sound(id: "underwater", name: L("Под водой", "Underwater"), symbol: "bubbles.and.sparkles", category: .water, tint: Color(hex: 0x2F7FD0), source: .file("underwater"),
              layers: [Layer(length: 8...16, fade: 3, rate: 0.97...1.03)]),

        // Природа
        Sound(id: "campfire", name: L("Костёр", "Campfire"), symbol: "flame", category: .nature, tint: Color(hex: 0xFF7438), source: .file("campfire"), boost: 1.8,
              layers: [Layer(length: 6...14, rate: 0.97...1.03)]),
        Sound(id: "wind", name: L("Ветер", "Wind"), symbol: "wind.snow", category: .nature, tint: Color(hex: 0x7FA7C4), source: .file("wind"),
              layers: [Layer(length: 6...14, fade: 3.5, rate: 0.95...1.05)], drift: 3),
        Sound(id: "birds", name: L("Птицы", "Birds"), symbol: "bird", category: .nature, tint: Color(hex: 0x8DC63F), source: .file("birds"),
              layers: [Layer(length: 6...14, rate: 0.97...1.03),
                       // A few more birds, singing from different sides.
                       Layer(length: 3...7, fade: 1.5, rate: 1.0...1.08, gainDB: -6, pan: 0.7, gap: 3...12)],
              drift: 2.5),
        Sound(id: "crickets", name: L("Сверчки", "Crickets"), symbol: "moon.stars", category: .nature, tint: Color(hex: 0x6875DB), source: .file("crickets"),
              layers: [Layer(length: 8...16, rate: 0.98...1.02)]),
        Sound(id: "whale", name: L("Киты", "Whales"), symbol: "fish", category: .nature, tint: Color(hex: 0x2A72C8), source: .file("whale"),
              layers: [Layer(length: 6...12, fade: 2.5, rate: 0.93...1.06, pan: 0.35),
                       // A distant pod: deeper voices, from far left/right, with pauses.
                       Layer(length: 4...9, fade: 2, rate: 0.78...0.9, gainDB: -7, pan: 0.8, gap: 2...10),
                       // The ocean itself, so there is never dead silence between songs.
                       Layer(file: "underwater", length: 8...16, fade: 3, rate: 0.97...1.03, gainDB: -9)]),

        // Город и дорога
        Sound(id: "city", name: L("Улица", "Street"), symbol: "building.2", category: .city, tint: Color(hex: 0xF0A030), source: .file("city"), drift: 2.5),
        Sound(id: "cafe", name: L("Кафе", "Café"), symbol: "cup.and.saucer", category: .city, tint: Color(hex: 0xC27C48), source: .file("cafe"),
              layers: [Layer(length: 8...16, rate: 0.99...1.01)], drift: 2.5),
        Sound(id: "train", name: L("Поезд", "Train"), symbol: "lightrail", category: .city, tint: Color(hex: 0xD9663F), source: .file("train"),
              layers: [Layer(length: 6...12, fade: 2)], drift: 1.5),
        Sound(id: "library", name: L("Библиотека", "Library"), symbol: "books.vertical", category: .city, tint: Color(hex: 0xA6774E), source: .file("library"), drift: 1.5),

        // Ритм
        Sound(id: "keyboard", name: L("Клавиатура", "Keyboard"), symbol: "keyboard", category: .rhythm, tint: Color(hex: 0x8A8AA3), source: .file("keyboard"), defaultVolume: 0.45,
              layers: [Layer(length: 1...3, fade: 0.12, rate: 0.97...1.03, gainJitterDB: 2)], drift: 2.5),
        Sound(id: "clock", name: L("Часы", "Clock"), symbol: "clock", category: .rhythm, tint: Color(hex: 0xB89B62), source: .file("clock"),
              crossfade: 0.03, region: LoopRegion(start: 0.45, length: 15.005), defaultVolume: 0.4, drift: 0),
        Sound(id: "heartbeat", name: L("Сердцебиение", "Heartbeat"), symbol: "heart", category: .rhythm, tint: Color(hex: 0xEF4B6C), source: .heartbeat, defaultVolume: 0.5, drift: 0),
        Sound(id: "cat", name: L("Мурлыканье кота", "Purring Cat"), symbol: "cat", category: .rhythm, tint: Color(hex: 0xE0915A), source: .file("cat"), defaultVolume: 0.4,
                            // Slower and lower than the recording: a calm, deep purr instead of a busy one.
              layers: [Layer(length: 6...12, fade: 1.5, rate: 0.86...0.92)], drift: 1),
        Sound(id: "vinyl", name: L("Виниловая пластинка", "Vinyl Record"), symbol: "opticaldisc", category: .rhythm, tint: Color(hex: 0xB0656E), source: .file("vinyl"), defaultVolume: 0.45,
              layers: [Layer(length: 4...9, fade: 1.5, rate: 0.99...1.01)], drift: 1),
        Sound(id: "bowl", name: L("Поющая чаша", "Singing Bowl"), symbol: "bell", category: .rhythm, tint: Color(hex: 0xD4A040), source: .file("bowl"), defaultVolume: 0.45,
              // Each strike is a different bowl: new pitch, new side, ringing over the last one.
              layers: [Layer(rate: 0.94...1.06, gainDB: -4, gainJitterDB: 2, pan: 0.5, events: 12...24)], drift: 1),

        // Шум — генерируется в реальном времени и никогда не повторяется
        Sound(id: "white", name: L("Белый шум", "White Noise"), symbol: "waveform", category: .noise, tint: Color(hex: 0x8F9AB3), source: .whiteNoise, defaultVolume: 0.35, drift: 0.75),
    ]

    static let byID: [String: Sound] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
