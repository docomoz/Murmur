import AVFoundation

/// Anything that fills a stereo, 48 kHz, deinterleaved buffer on the real-time audio thread.
/// Implementations must not allocate, lock or touch Swift collections they mutate.
protocol RealtimeGenerator: AnyObject {
    func render(frames: Int, into list: UnsafeMutablePointer<AudioBufferList>)
}

/// Tiny xorshift RNG that is safe to use on the audio thread.
struct FastRandom {
    private var state = UInt64.random(in: 1...UInt64.max)

    /// Uniform in [0, 1).
    mutating func next() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return Double((state &* 2_685_821_657_736_338_717) >> 11) / Double(1 << 53)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * next()
    }
}

/// Endless, never-repeating texture built from a recording: several layers of overlapping grains.
final class TextureGenerator: RealtimeGenerator {
    static let sampleRate = 48_000.0

    private let layers: ContiguousArray<GrainLayer>

    init(layers: [(Layer, AVAudioPCMBuffer)]) {
        self.layers = ContiguousArray(layers.map { GrainLayer(spec: $0.0, source: $0.1) })
    }

    /// Decodes (or takes from `cache`) every recording the sound's layers need. Blocking; call off the main thread.
    static func load(_ sound: Sound, cache: NSCache<NSString, AVAudioPCMBuffer>?) throws -> TextureGenerator {
        guard case .file(let own) = sound.source else { throw LoopBuilder.Failure.missing }
        var pairs: [(Layer, AVAudioPCMBuffer)] = []
        for layer in sound.layers {
            let file = layer.file ?? own
            let boost = file == own ? sound.boost : 1
            let key = "src:\(file):\(boost)" as NSString
            if let cached = cache?.object(forKey: key) {
                pairs.append((layer, cached))
                continue
            }
            let buffer = try SourceLoader.load(file, boost: boost)
            let bytes = Int(buffer.frameLength) * Int(buffer.format.channelCount) * 4
            cache?.setObject(buffer, forKey: key, cost: bytes)
            pairs.append((layer, buffer))
        }
        return TextureGenerator(layers: pairs)
    }

    func render(frames: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        for layer in layers { layer.render(left, right, frames) }
    }
}

/// One layer: a chain (or sparse sprinkle) of grains read from a single recording.
final class GrainLayer {
    private struct Grain {
        var position: Double = 0
        var step: Double = 1
        var age = 0
        var length = 0
        var fadeIn = 1
        var fadeOut = 1
        var gainL: Float = 1
        var gainR: Float = 1
        var swap = false
        var active = false
    }

    private static let slots = 4

    private let spec: Layer
    private let source: AVAudioPCMBuffer   // keeps the sample memory alive
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let frames: Int
    private let baseStep: Double
    private let grains = UnsafeMutablePointer<Grain>.allocate(capacity: GrainLayer.slots)
    private var untilNext = 0
    private var nextFadeIn = 0
    private var recent: (Double, Double, Double) = (-1e12, -1e12, -1e12)
    private var random = FastRandom()
    private var isFirst = true

    init(spec: Layer, source: AVAudioPCMBuffer) {
        self.spec = spec
        self.source = source
        let data = source.floatChannelData!
        left = data[0]
        right = source.format.channelCount > 1 ? data[1] : data[0]
        frames = Int(source.frameLength)
        baseStep = source.format.sampleRate / TextureGenerator.sampleRate
        grains.initialize(repeating: Grain(), count: GrainLayer.slots)
        if spec.gap.upperBound > 0 {
            // Sparse layers enter after a pause instead of all at once.
            untilNext = Int(random.next(in: spec.gap) * TextureGenerator.sampleRate)
        }
    }

    deinit { grains.deallocate() }

    func render(_ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, _ count: Int) {
        var done = 0
        while done < count {
            if untilNext <= 0 { spawn() }
            let chunk = min(count - done, untilNext)
            for i in 0..<GrainLayer.slots where grains[i].active {
                play(&grains[i], outL + done, outR + done, chunk)
            }
            untilNext -= chunk
            done += chunk
        }
    }

    private func spawn() {
        if let events = spec.events {
            spawnEvent(every: events)
            return
        }
        let sr = TextureGenerator.sampleRate
        let step = baseStep * random.next(in: spec.rate)
        var length = Int(random.next(in: spec.length) * sr)
        length = max(min(length, Int(Double(frames - 2) / step)), 256)
        let fade = max(min(Int(spec.fade * sr), length / 2), 32)
        let fadeIn: Int
        if isFirst {
            fadeIn = min(Int(0.02 * sr), length / 2)   // the channel's own fade-in covers the start
        } else if spec.gap.upperBound > 0 {
            fadeIn = fade
        } else {
            fadeIn = max(min(nextFadeIn, length / 2), 32)  // match the outgoing grain's fade-out
        }

        // Start somewhere new: not where the last few grains came from.
        let span = Double(length) * step
        let maxStart = max(Double(frames - 2) - span, 0)
        let minDistance = min(span * 0.75, maxStart / 4)
        var start = random.next() * maxStart
        for _ in 0..<8 {
            if abs(start - recent.0) > minDistance, abs(start - recent.1) > minDistance, abs(start - recent.2) > minDistance { break }
            start = random.next() * maxStart
        }
        recent = (start, recent.0, recent.1)

        let gain = Float(pow(10, (spec.gainDB + random.next(in: -spec.gainJitterDB...spec.gainJitterDB)) / 20))
        let pan = random.next(in: -spec.pan...spec.pan)

        var grain = Grain()
        grain.position = start
        grain.step = step
        grain.length = length
        grain.fadeIn = fadeIn
        grain.fadeOut = fade
        grain.gainL = gain * Float(min(1, 1 - pan))
        grain.gainR = gain * Float(min(1, 1 + pan))
        grain.swap = spec.swapChannels && random.next() < 0.5
        grain.active = true
        for i in 0..<GrainLayer.slots where !grains[i].active {
            grains[i] = grain
            break
        }

        isFirst = false
        nextFadeIn = fade
        let gap = spec.gap.upperBound > 0 ? Int(random.next(in: spec.gap) * sr) : 0
        untilNext = max(length - fade + (gap > 0 ? fade + gap : 0), 1)
    }

    /// One whole recording from its start (a bowl strike), ringing over whatever is still sounding.
    private func spawnEvent(every interval: ClosedRange<Double>) {
        let sr = TextureGenerator.sampleRate
        let step = baseStep * random.next(in: spec.rate)
        let length = max(Int(Double(frames - 2) / step), 256)
        let gain = Float(pow(10, (spec.gainDB + random.next(in: -spec.gainJitterDB...spec.gainJitterDB)) / 20))
        let pan = random.next(in: -spec.pan...spec.pan)

        var grain = Grain()
        grain.position = 0
        grain.step = step
        grain.length = length
        grain.fadeIn = min(Int(0.005 * sr), length / 2)
        grain.fadeOut = min(Int(1.0 * sr), length / 2)
        grain.gainL = gain * Float(min(1, 1 - pan))
        grain.gainR = gain * Float(min(1, 1 + pan))
        grain.swap = spec.swapChannels && random.next() < 0.5
        grain.active = true
        // Reuse a free slot, or replace the oldest (quietest by now) ring-out.
        var slot = 0
        for i in 0..<GrainLayer.slots {
            if !grains[i].active { slot = i; break }
            if grains[i].age > grains[slot].age { slot = i }
        }
        grains[slot] = grain
        isFirst = false
        untilNext = max(Int(random.next(in: interval) * sr), 1)
    }

    @inline(__always)
    private func play(_ g: inout Grain, _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, _ count: Int) {
        let n = min(count, g.length - g.age)
        let fadeOutStart = g.length - g.fadeOut
        let last = frames - 2
        for i in 0..<n {
            var env: Float = 1
            if g.age < g.fadeIn {
                env = Float(sin(Double(g.age) / Double(g.fadeIn) * .pi / 2))
            } else if g.age >= fadeOutStart {
                env = Float(cos(Double(g.age - fadeOutStart) / Double(g.fadeOut) * .pi / 2))
            }
            let index = min(Int(g.position), last)
            let frac = Float(g.position - Double(index))
            let a = left[index] + (left[index + 1] - left[index]) * frac
            let b = right[index] + (right[index + 1] - right[index]) * frac
            outL[i] += (g.swap ? b : a) * env * g.gainL
            outR[i] += (g.swap ? a : b) * env * g.gainR
            g.position += g.step
            g.age += 1
        }
        if g.age >= g.length { g.active = false }
    }
}

/// A resting heartbeat with natural heart-rate variability: the tempo drifts slowly between
/// ~54 and ~64 bpm, every beat lands a little early or late and hits a little softer or harder.
final class HeartbeatGenerator: RealtimeGenerator {
    private let beat: UnsafeMutablePointer<Float>
    private let beatLength: Int
    private var playhead = -1
    private var untilNext = Int(0.3 * TextureGenerator.sampleRate)
    private var bpm = 58.0
    private var amplitude: Float = 1
    private var random = FastRandom()

    init() {
        let sr = TextureGenerator.sampleRate
        beatLength = Int(0.8 * sr)
        beat = .allocate(capacity: beatLength)
        beat.initialize(repeating: 0, count: beatLength)

        func thump(at onset: Double, from f0: Double, to f1: Double, decay: Double, amp: Double) {
            var phase = 0.0
            let first = Int(onset * sr)
            for i in first..<beatLength {
                let t = Double(i - first) / sr
                if t > decay * 8 { break }
                let f = f1 + (f0 - f1) * exp(-t / 0.03)
                phase += 2 * .pi * f / sr
                let env = (1 - exp(-t / 0.004)) * exp(-t / decay)
                let tone = sin(phase) + 0.45 * sin(2 * phase) + 0.18 * sin(3 * phase)
                beat[i] += Float(amp * env * tone)
            }
        }
        thump(at: 0.02, from: 110, to: 58, decay: 0.055, amp: 1.0)   // lub
        thump(at: 0.31, from: 130, to: 70, decay: 0.040, amp: 0.65)  // dub

        var peak: Float = 0
        for i in 0..<beatLength { peak = max(peak, abs(beat[i])) }
        for i in 0..<beatLength { beat[i] *= 0.9 / max(peak, 1e-5) }
    }

    deinit { beat.deallocate() }

    func render(frames: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        for i in 0..<frames {
            if untilNext <= 0 {
                playhead = 0
                amplitude = Float(random.next(in: 0.82...1.0))
                // Slow random walk of the tempo, gently pulled back toward 58 bpm.
                bpm += random.next(in: -0.8...0.8) + (58 - bpm) * 0.05
                bpm = min(max(bpm, 54), 64)
                let interval = 60 / bpm * random.next(in: 0.975...1.025)
                untilNext = Int(interval * TextureGenerator.sampleRate)
            }
            if playhead >= 0 {
                out[i] = beat[playhead] * amplitude
                playhead += 1
                if playhead >= beatLength { playhead = -1 }
            } else {
                out[i] = 0
            }
            untilNext -= 1
        }
        for buffer in buffers.dropFirst() {
            buffer.mData?.assumingMemoryBound(to: Float.self).update(from: out, count: frames)
        }
    }
}

/// Decodes a recording into a trimmed, loudness-matched source buffer for grains (no loop crossfade).
enum SourceLoader {
    static let maxSeconds: Double = 120

    static func load(_ name: String, boost: Float) throws -> AVAudioPCMBuffer {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Sounds") else {
            throw LoopBuilder.Failure.missing
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        let wanted = min(AVAudioFramePosition((maxSeconds + 2) * sr), file.length)
        guard wanted > 0, let src = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wanted)) else {
            throw LoopBuilder.Failure.empty
        }
        try file.read(into: src, frameCount: AVAudioFrameCount(wanted))
        guard let data = src.floatChannelData else { throw LoopBuilder.Failure.empty }

        let channels = Int(format.channelCount)
        var (start, end) = LoopBuilder.audibleRange(data, channels: channels, frames: Int(src.frameLength), sampleRate: sr)
        end = min(end, start + Int(maxSeconds * sr))
        let length = end - start
        guard length > Int(sr), let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
              let dst = out.floatChannelData else { throw LoopBuilder.Failure.empty }
        out.frameLength = AVAudioFrameCount(length)

        let gain = LoopBuilder.loudnessGain(data, channels: channels, start: start, length: length) * boost
        for c in 0..<channels {
            let s = data[c] + start
            let o = dst[c]
            for i in 0..<length { o[i] = LoopBuilder.softClip(s[i] * gain) }
        }
        return out
    }
}
