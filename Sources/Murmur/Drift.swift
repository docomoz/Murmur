import AVFoundation

/// Living Mix: shared on/off switch for every channel's level drift.
/// Written on the main thread, read on the audio thread (a single aligned word; a stale read
/// for one buffer is harmless because every channel glides toward the new state anyway).
final class DriftSwitch {
    var enabled = true
}

/// Slow, bounded wandering of one channel's level around the user's volume: rain gradually
/// intensifies and calms, the café fills up and empties. It is a multiplier on top of the channel
/// gain — sliders and saved mixes never see it.
///
/// The offset (in dB) is a sum of three sines with random, incommensurate periods (≈ 1–5 min)
/// and random phases, normalised so it never leaves ±`depthDB`. The mix therefore averages out
/// to exactly what the user set and never repeats. Switching the feature off (or on) glides the
/// depth over `toggleTime`, so nothing jumps. Allocation-free; safe on the audio thread.
struct Drift {
    /// Periods (s) of the three components: a slow swell, a medium one, and a quicker ripple —
    /// the shortest still a full minute. Only read when a channel is created (main thread).
    static let periods: [ClosedRange<Double>] = [150...300, 80...150, 60...90]
    /// Relative weights (stored inline, not in an array, so the audio thread never retains anything).
    private static let w0 = 1.0, w1 = 0.6, w2 = 0.3
    /// Seconds for the drift to fade in/out when Living Mix is toggled.
    static let toggleTime = 6.0

    let depthDB: Double
    private var phase: (Double, Double, Double)
    private let omega: (Double, Double, Double)   // radians per second
    private var amount: Double                     // 0…1, glides toward the switch state

    init(depthDB: Double, enabled: Bool = true) {
        var random = FastRandom()
        self.depthDB = max(depthDB, 0)
        phase = (random.next() * 2 * .pi, random.next() * 2 * .pi, random.next() * 2 * .pi)
        omega = (2 * .pi / random.next(in: Self.periods[0]),
                 2 * .pi / random.next(in: Self.periods[1]),
                 2 * .pi / random.next(in: Self.periods[2]))
        amount = enabled ? 1 : 0
    }

    var isStatic: Bool { depthDB == 0 }

    /// Current offset in dB, always within ±`depthDB`.
    var offsetDB: Double {
        guard depthDB > 0, amount > 0 else { return 0 }
        let s = Self.w0 * sin(phase.0) + Self.w1 * sin(phase.1) + Self.w2 * sin(phase.2)
        return depthDB * amount * s / (Self.w0 + Self.w1 + Self.w2)
    }

    /// Current linear gain multiplier. Exactly 1 when off or for sounds without drift.
    var gain: Float {
        let db = offsetDB
        return db == 0 ? 1 : Float(pow(10, db / 20))
    }

    /// Move time forward by `seconds` and return the new gain.
    mutating func advance(_ seconds: Double, enabled: Bool) -> Float {
        guard depthDB > 0 else { return 1 }
        phase.0 = (phase.0 + omega.0 * seconds).truncatingRemainder(dividingBy: 2 * .pi)
        phase.1 = (phase.1 + omega.1 * seconds).truncatingRemainder(dividingBy: 2 * .pi)
        phase.2 = (phase.2 + omega.2 * seconds).truncatingRemainder(dividingBy: 2 * .pi)
        let step = seconds / Self.toggleTime
        amount = enabled ? min(1, amount + step) : max(0, amount - step)
        return gain
    }
}

/// Wraps a real-time generator and applies its channel's `Drift`, interpolating the gain linearly
/// across each render buffer so there is no zipper noise.
final class DriftingGenerator: RealtimeGenerator {
    private let inner: RealtimeGenerator
    private let toggle: DriftSwitch
    private var drift: Drift
    private var last: Float

    init(_ inner: RealtimeGenerator, depthDB: Double, toggle: DriftSwitch) {
        self.inner = inner
        self.toggle = toggle
        drift = Drift(depthDB: depthDB, enabled: toggle.enabled)
        last = drift.gain
    }

    func render(frames: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        inner.render(frames: frames, into: list)
        let next = drift.advance(Double(frames) / TextureGenerator.sampleRate, enabled: toggle.enabled)
        defer { last = next }
        if last == 1 && next == 1 { return }
        // `last + step·i`, not a running sum: summing ~1e-7 steps onto 1.0 in Float loses them to
        // rounding and the buffer would end off-target, stepping at the next buffer.
        let step = (next - last) / Float(max(frames, 1))
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frames { out[i] *= last + step * Float(i + 1) }
        }
    }
}
