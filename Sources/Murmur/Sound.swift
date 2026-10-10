import SwiftUI

enum NoiseColor: Hashable {
    case white, pink, brown
}

enum SoundSource: Hashable {
    case file(String)
    case noise(NoiseColor)
    case tone(Float)
    case heartbeat
}

enum SoundCategory: String, CaseIterable, Identifiable {
    case water = "Дождь и вода"
    case nature = "Природа"
    case city = "Город и дорога"
    case rhythm = "Ритм"
    case noise = "Шумы и тоны"

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

    static func == (a: Sound, b: Sound) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

extension Sound {
    static let all: [Sound] = [
        // Дождь и вода
        Sound(id: "rain", name: "Дождь", symbol: "cloud.rain", category: .water, tint: Color(hex: 0x4F8EF7), source: .file("rain")),
        Sound(id: "heavyrain", name: "Ливень", symbol: "cloud.heavyrain", category: .water, tint: Color(hex: 0x3D63DD), source: .file("heavyrain"),
              layers: [Layer(length: 3...7, fade: 1.5, rate: 0.97...1.03)]),
        Sound(id: "window", name: "Дождь в окно", symbol: "window.vertical.closed", category: .water, tint: Color(hex: 0x5BA4F5), source: .file("window"),
              layers: [Layer(length: 4...9, fade: 2, rate: 0.98...1.02)]),
        Sound(id: "storm", name: "Гроза", symbol: "cloud.bolt.rain", category: .water, tint: Color(hex: 0x7C6CF2), source: .file("storm"),
              layers: [Layer(length: 6...14, fade: 3, rate: 0.95...1.05),
                       // Distant rolls of thunder: lower, quieter, now and then.
                       Layer(length: 5...10, fade: 2.5, rate: 0.78...0.9, gainDB: -8, pan: 0.6, gap: 6...20)]),
        Sound(id: "waves", name: "Морской прибой", symbol: "water.waves", category: .water, tint: Color(hex: 0x14A9D6), source: .file("waves"),
              layers: [Layer(length: 8...16, fade: 3, rate: 0.97...1.03)]),
        Sound(id: "river", name: "Ручей", symbol: "drop", category: .water, tint: Color(hex: 0x1FBFB0), source: .file("river")),
        Sound(id: "waterfall", name: "Водопад", symbol: "humidity", category: .water, tint: Color(hex: 0x2B9CC9), source: .file("waterfall"),
              layers: [Layer(length: 3...7, fade: 1.5, rate: 0.97...1.03)]),

        // Природа
        Sound(id: "campfire", name: "Костёр", symbol: "flame", category: .nature, tint: Color(hex: 0xFF7438), source: .file("campfire"), boost: 1.8,
              layers: [Layer(length: 6...14, rate: 0.97...1.03)]),
        Sound(id: "wind", name: "Зимний ветер", symbol: "wind.snow", category: .nature, tint: Color(hex: 0x7FA7C4), source: .file("wind"),
              layers: [Layer(length: 6...14, fade: 3.5, rate: 0.95...1.05)]),
        Sound(id: "trees", name: "Ветер в листве", symbol: "leaf", category: .nature, tint: Color(hex: 0x3FBF68), source: .file("trees"),
              layers: [Layer(length: 5...12, rate: 0.96...1.04)]),
        Sound(id: "birds", name: "Птицы в парке", symbol: "bird", category: .nature, tint: Color(hex: 0x8DC63F), source: .file("birds"),
              layers: [Layer(length: 6...14, rate: 0.97...1.03),
                       // A few more birds, singing from different sides.
                       Layer(length: 3...7, fade: 1.5, rate: 1.0...1.08, gainDB: -6, pan: 0.7, gap: 3...12)]),
        Sound(id: "crickets", name: "Сверчки", symbol: "moon.stars", category: .nature, tint: Color(hex: 0x6875DB), source: .file("crickets"),
              layers: [Layer(length: 8...16, rate: 0.98...1.02)]),
        Sound(id: "whale", name: "Киты", symbol: "fish", category: .nature, tint: Color(hex: 0x2A72C8), source: .file("whale"),
              layers: [Layer(length: 6...12, fade: 2.5, rate: 0.93...1.06, pan: 0.35),
                       // A distant pod: deeper voices, from far left/right, with pauses.
                       Layer(length: 4...9, fade: 2, rate: 0.78...0.9, gainDB: -7, pan: 0.8, gap: 2...10),
                       // The ocean itself, so there is never dead silence between songs.
                       Layer(file: "underwater", length: 8...16, fade: 3, rate: 0.97...1.03, gainDB: -9)]),

        // Город и дорога
        Sound(id: "city", name: "Улица", symbol: "building.2", category: .city, tint: Color(hex: 0xF0A030), source: .file("city")),
        Sound(id: "cafe", name: "Кафе", symbol: "cup.and.saucer", category: .city, tint: Color(hex: 0xC27C48), source: .file("cafe"),
              layers: [Layer(length: 8...16, rate: 0.99...1.01)]),
        Sound(id: "subway", name: "Метро", symbol: "tram", category: .city, tint: Color(hex: 0xE5534B), source: .file("subway")),
        Sound(id: "train", name: "В поезде", symbol: "lightrail", category: .city, tint: Color(hex: 0xD9663F), source: .file("train"),
              layers: [Layer(length: 6...12, fade: 2)]),
        Sound(id: "sailboat", name: "Парусник", symbol: "sailboat", category: .city, tint: Color(hex: 0x3398D6), source: .file("sailboat")),
        Sound(id: "library", name: "Библиотека", symbol: "books.vertical", category: .city, tint: Color(hex: 0xA6774E), source: .file("library")),

        // Ритм
        Sound(id: "keyboard", name: "Клавиатура", symbol: "keyboard", category: .rhythm, tint: Color(hex: 0x8A8AA3), source: .file("keyboard"), defaultVolume: 0.45,
              layers: [Layer(length: 1...3, fade: 0.12, rate: 0.97...1.03, gainJitterDB: 2)]),
        Sound(id: "typewriter", name: "Печатная машинка", symbol: "doc.text", category: .rhythm, tint: Color(hex: 0x9C8468), source: .file("typewriter"), defaultVolume: 0.45,
              layers: [Layer(length: 1.5...4, fade: 0.15, rate: 0.98...1.02)]),
        Sound(id: "clock", name: "Часы", symbol: "clock", category: .rhythm, tint: Color(hex: 0xB89B62), source: .file("clock"),
              crossfade: 0.03, region: LoopRegion(start: 0.45, length: 15.005), defaultVolume: 0.4),
        Sound(id: "heartbeat", name: "Сердцебиение", symbol: "heart", category: .rhythm, tint: Color(hex: 0xEF4B6C), source: .heartbeat, defaultVolume: 0.5),
        Sound(id: "chimes", name: "Колокольчики", symbol: "sparkles", category: .rhythm, tint: Color(hex: 0xB98AF0), source: .file("chimes"), defaultVolume: 0.4,
              layers: [Layer(length: 5...12, fade: 3, rate: 0.995...1.005),
                       Layer(length: 4...8, fade: 2.5, rate: 0.995...1.005, gainDB: -7, pan: 0.7, gap: 4...14)]),

        // Шумы — генерируются в реальном времени и никогда не повторяются
        Sound(id: "white", name: "Белый шум", symbol: "waveform", category: .noise, tint: Color(hex: 0x8F9AB3), source: .noise(.white), defaultVolume: 0.35),
        Sound(id: "pink", name: "Розовый шум", symbol: "waveform.path", category: .noise, tint: Color(hex: 0xF07AAA), source: .noise(.pink), defaultVolume: 0.4),
        Sound(id: "brown", name: "Коричневый шум", symbol: "speaker.wave.2", category: .noise, tint: Color(hex: 0xA2704A), source: .noise(.brown), defaultVolume: 0.45),
        Sound(id: "tone432", name: "Тон 432 Гц", symbol: "tuningfork", category: .noise, tint: Color(hex: 0x49EEC8), source: .tone(432), defaultVolume: 0.3),
        Sound(id: "tone528", name: "Тон 528 Гц", symbol: "tuningfork", category: .noise, tint: Color(hex: 0x52D2F0), source: .tone(528), defaultVolume: 0.3),
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
