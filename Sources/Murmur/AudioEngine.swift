import AVFoundation
import AudioToolbox

/// Owns the AVAudioEngine graph. Every sound is a channel (a never-repeating texture generator,
/// a live white-noise/heartbeat generator, or — for the clock — an exact loop) whose gain glides
/// toward a target, so nothing ever clicks on/off.
/// All methods must be called on the main thread.
final class AudioEngine {
    private final class Channel {
        let sound: Sound
        var node: AVAudioNode?
        var buffer: AVAudioPCMBuffer?
        var gain: Float = 0
        var target: Float = 0
        var rate: Float = 1
        var ready = false

        init(sound: Sound) { self.sound = sound }
        var mixing: AVAudioMixing? { node as? AVAudioMixing }
    }

    private let engine = AVAudioEngine()
    private let limiter: AVAudioUnitEffect
    private var channels: [String: Channel] = [:]
    private var rampTimer: Timer?
    private var idleStop: DispatchWorkItem?
    private let cache = NSCache<NSString, AVAudioPCMBuffer>()
    private var observers: [NSObjectProtocol] = []
    private let driftSwitch = DriftSwitch()
    /// One-shot cues (Pomodoro bowl strikes) still ringing; they keep the engine awake.
    private var cues: [AVAudioPlayerNode] = []
    private var cueBuffers: [Double: AVAudioPCMBuffer] = [:]

    init() {
        cache.totalCostLimit = 400 * 1024 * 1024

        limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
        engine.attach(limiter)
        wireOutput()

        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.recover() })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Public

    /// Living Mix: each generator channel's level slowly wanders around its target
    /// (`Sound.drift`). Toggling glides in/out on the audio thread; no timer is involved.
    var livingMix: Bool {
        get { driftSwitch.enabled }
        set { driftSwitch.enabled = newValue }
    }

    var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// Paused while a call keeps Murmur fully ducked: no audio IO, no CPU, no hold on a headset
    /// that just switched to its call profile. Channels keep their state; resuming goes through
    /// `recover()`, since the output device often changes during a call (AirPods → headset mode).
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused {
                if engine.isRunning { engine.pause() }
            } else {
                recover()
            }
        }
    }

    /// Glide `sound` to `gain` over `fade` seconds, loading it on first use.
    func setTarget(_ sound: Sound, gain: Float, fade: Double) {
        let ch: Channel
        if let existing = channels[sound.id] {
            ch = existing
        } else {
            guard gain > 0 else { return }
            ch = Channel(sound: sound)
            channels[sound.id] = ch
            load(ch)
        }
        ch.target = gain
        ch.rate = max(abs(gain - ch.gain), 0.02) / Float(max(fade, 0.016))
        startRamp()
    }

    /// Plays one singing-bowl strike over the mix (through the master volume), then lets it go.
    func playCue(pitch: Double, gain: Float = 0.22) {
        if let buffer = cueBuffers[pitch] {
            startCue(buffer, gain: gain)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let buffer = try? Chime.buffer(pitch: pitch) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cueBuffers[pitch] = buffer
                self.startCue(buffer, gain: gain)
            }
        }
    }

    private func startCue(_ buffer: AVAudioPCMBuffer, gain: Float) {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        player.volume = gain
        ensureRunning()
        cues.append(player)
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.finishCue(player) }
        }
        player.play()
    }

    private func finishCue(_ player: AVAudioPlayerNode) {
        guard let i = cues.firstIndex(where: { $0 === player }) else { return }
        cues.remove(at: i)
        player.stop()
        engine.detach(player)
        if channels.isEmpty && cues.isEmpty { scheduleIdleStop() }
    }

    /// Restart output after sleep, device switches (AirPods in/out) and the like.
    func recover() {
        // A cue cut off by the restart is simply dropped.
        let ringing = cues
        cues = []
        for player in ringing {
            player.stop()
            engine.detach(player)
        }
        guard !channels.isEmpty, !isPaused else { return }
        engine.stop()
        wireOutput()
        do { try engine.start() } catch { return }
        for ch in channels.values {
            guard let player = ch.node as? AVAudioPlayerNode, let buffer = ch.buffer else { continue }
            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
        }
    }

    /// Debug: RMS of what the mixer actually outputs over the next `seconds`.
    func measureOutput(seconds: Double, completion: @escaping (Float, Int) -> Void) {
        var sum: Double = 0
        var count = 0
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            for i in 0..<Int(buffer.frameLength) { sum += Double(data[0][i] * data[0][i]) }
            count += Int(buffer.frameLength)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            mixer.removeTap(onBus: 0)
            completion(Float(sqrt(sum / Double(max(count, 1)))) / max(mixer.outputVolume, 1e-4), self.channels.count)
        }
    }

    // MARK: Graph

    private func wireOutput() {
        let hw = engine.outputNode.outputFormat(forBus: 0)
        let rate = hw.sampleRate > 0 ? hw.sampleRate : 48_000
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
        engine.connect(engine.mainMixerNode, to: limiter, format: format)
        engine.connect(limiter, to: engine.outputNode, format: format)
    }

    private func ensureRunning() {
        idleStop?.cancel()
        idleStop = nil
        if !engine.isRunning && !isPaused {
            engine.prepare()
            try? engine.start()
        }
    }

    private func load(_ ch: Channel) {
        let sound = ch.sound
        switch sound.source {
        case .whiteNoise:
            attach(ch, node: makeNode(NoiseGenerator(), for: sound), buffer: nil)
            return
        case .heartbeat:
            attach(ch, node: makeNode(HeartbeatGenerator(), for: sound), buffer: nil)
            return
        case .file:
            if sound.region == nil {
                loadTexture(ch)
                return
            }
        }
        if let cached = cache.object(forKey: sound.id as NSString) {
            attachPlayer(ch, buffer: cached)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let buffer = try? LoopBuilder.buffer(for: sound)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let buffer else {
                    if self.channels[sound.id] === ch { self.channels[sound.id] = nil }
                    return
                }
                let bytes = Int(buffer.frameLength) * Int(buffer.format.channelCount) * 4
                self.cache.setObject(buffer, forKey: sound.id as NSString, cost: bytes)
                guard self.channels[sound.id] === ch else { return }
                self.attachPlayer(ch, buffer: buffer)
            }
        }
    }

    private func loadTexture(_ ch: Channel) {
        let sound = ch.sound
        let cache = self.cache
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let generator = try? TextureGenerator.load(sound, cache: cache)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let generator else {
                    if self.channels[sound.id] === ch { self.channels[sound.id] = nil }
                    return
                }
                guard self.channels[sound.id] === ch else { return }
                self.attach(ch, node: self.makeNode(generator, for: sound), buffer: nil)
            }
        }
    }

    private func attachPlayer(_ ch: Channel, buffer: AVAudioPCMBuffer) {
        let player = AVAudioPlayerNode()
        attach(ch, node: player, buffer: buffer)
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    private func attach(_ ch: Channel, node: AVAudioNode, buffer: AVAudioPCMBuffer?) {
        engine.attach(node)
        let format = buffer?.format ?? node.outputFormat(forBus: 0)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        (node as? AVAudioMixing)?.volume = 0
        ensureRunning()
        ch.node = node
        ch.buffer = buffer
        ch.ready = true
        startRamp()
    }

    private func teardown(_ id: String) {
        guard let ch = channels.removeValue(forKey: id), let node = ch.node else { return }
        (node as? AVAudioPlayerNode)?.stop()
        engine.detach(node)
    }

    // MARK: Ramping

    private func startRamp() {
        guard rampTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer
    }

    private func tick() {
        let dt: Float = 1.0 / 60
        var busy = false
        for (id, ch) in channels {
            guard ch.ready else { busy = true; continue }
            if ch.gain != ch.target {
                let step = ch.rate * dt
                if abs(ch.target - ch.gain) <= step {
                    ch.gain = ch.target
                } else {
                    ch.gain += ch.target > ch.gain ? step : -step
                }
                ch.mixing?.volume = ch.gain
                busy = true
            }
            if ch.gain == 0 && ch.target == 0 { teardown(id) }
        }
        guard !busy else { return }
        rampTimer?.invalidate()
        rampTimer = nil
        if channels.isEmpty { scheduleIdleStop() }
    }

    /// Stop the engine once nothing is playing, so the Mac can sleep and the CPU rests.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.channels.isEmpty, self.cues.isEmpty else { return }
            self.engine.stop()
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Generators

    /// Source node for a generator, wrapped in its sound's level drift when it has any.
    /// (The clock is an `AVAudioPlayerNode` loop and never drifts.)
    private func makeNode(_ generator: RealtimeGenerator, for sound: Sound) -> AVAudioSourceNode {
        let wrapped: RealtimeGenerator = sound.drift > 0
            ? DriftingGenerator(generator, depthDB: sound.drift, toggle: driftSwitch)
            : generator
        return Self.makeNode(wrapped)
    }

    private static func makeNode(_ generator: RealtimeGenerator) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: TextureGenerator.sampleRate, channels: 2)!
        return AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            generator.render(frames: Int(frameCount), into: bufferList)
            return noErr
        }
    }
}

/// Real-time white noise: endless and never repeating, unlike a short noise loop.
final class NoiseGenerator: RealtimeGenerator {
    private var random = FastRandom()

    func render(frames: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frames { out[i] = Float(random.next() * 2 - 1) * 0.15 }
        }
    }
}

/// Pomodoro phase cue: the first strike of the singing-bowl recording, shortened to ~11 s with a
/// soft tail and optionally pitched (resampled) — never a system beep.
enum Chime {
    static let seconds = 11.0
    static let fadeOut = 4.0

    static func buffer(pitch: Double) throws -> AVAudioPCMBuffer {
        let src = try SourceLoader.load("bowl", boost: 1)
        guard let data = src.floatChannelData else { throw LoopBuilder.Failure.empty }
        let sr = src.format.sampleRate
        let n = Int(src.frameLength)
        let channels = Int(src.format.channelCount)
        let length = min(Int(Double(n - 1) / pitch), Int(seconds * sr))
        let fadeIn = Int(0.005 * sr)
        let tail = Int(fadeOut * sr)
        guard length > tail, let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
              let dst = out.floatChannelData else { throw LoopBuilder.Failure.empty }
        out.frameLength = AVAudioFrameCount(length)
        for c in 0..<2 {
            let s = data[min(c, channels - 1)]
            let o = dst[c]
            for i in 0..<length {
                let position = Double(i) * pitch
                let j = Int(position)
                let f = Float(position - Double(j))
                var v = s[j] + (s[j + 1] - s[j]) * f
                if i < fadeIn { v *= Float(i) / Float(fadeIn) }
                let left = length - i
                if left < tail {
                    let t = Float(left) / Float(tail)
                    v *= t * t
                }
                o[i] = v
            }
        }
        return out
    }
}

/// Turns a recording into a seamless, loudness-matched loop buffer (used for the clock, whose
/// rhythm must stay exact) and hosts the shared trimming / loudness helpers.
enum LoopBuilder {
    enum Failure: Error { case missing, empty }

    static let targetRMS: Float = 0.13
    static let maxSeconds: Double = 90

    static func buffer(for sound: Sound) throws -> AVAudioPCMBuffer {
        guard case .file(let name) = sound.source else { throw Failure.missing }
        return try fromFile(name, sound: sound)
    }

    private static func fromFile(_ name: String, sound: Sound) throws -> AVAudioPCMBuffer {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Sounds") else {
            throw Failure.missing
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate

        var wanted = AVAudioFramePosition((maxSeconds + sound.crossfade + 2) * sr)
        if let region = sound.region {
            file.framePosition = AVAudioFramePosition(region.start * sr)
            wanted = AVAudioFramePosition((region.length + sound.crossfade) * sr)
        }
        wanted = min(wanted, file.length - file.framePosition)
        guard wanted > 0, let src = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wanted)) else {
            throw Failure.empty
        }
        try file.read(into: src, frameCount: AVAudioFrameCount(wanted))

        let channels = Int(format.channelCount)
        guard let data = src.floatChannelData else { throw Failure.empty }
        let n = Int(src.frameLength)

        // Trim silent lead-in / tail (thunder fades, typewriter pauses) unless the window is exact.
        var start = 0, end = n
        if sound.region == nil {
            (start, end) = audibleRange(data, channels: channels, frames: n, sampleRate: sr)
            end = min(end, start + Int((maxSeconds + sound.crossfade) * sr))
        }
        let length = end - start
        guard length > Int(sr) else { throw Failure.empty }

        let gain = loudnessGain(data, channels: channels, start: start, length: length) * sound.boost

        // Equal-power crossfade of the tail into the head: the loop point disappears.
        let fade = min(Int(sound.crossfade * sr), length / 4)
        let outLength = length - fade
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outLength)),
              let dst = out.floatChannelData else { throw Failure.empty }
        out.frameLength = AVAudioFrameCount(outLength)
        for c in 0..<channels {
            let s = data[c] + start
            let o = dst[c]
            for i in 0..<outLength { o[i] = s[i] * gain }
            for i in 0..<fade {
                let t = Float(i) / Float(fade) * .pi / 2
                o[i] = (s[i] * sin(t) + s[outLength + i] * cos(t)) * gain
            }
            for i in 0..<outLength { o[i] = softClip(o[i]) }
        }
        return out
    }

    /// Loudness: bring every sound to a similar level. Rare spikes (a crackle, a fat raindrop)
    /// shouldn't hold the whole recording down, so headroom is judged by the 99.9th percentile
    /// and the few samples above it are soft-clipped.
    static func loudnessGain(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, start: Int, length: Int) -> Float {
        var sumSquares: Double = 0
        var histogram = [Int](repeating: 0, count: 1000)
        for c in 0..<channels {
            let p = data[c] + start
            for i in 0..<length {
                let v = p[i]
                sumSquares += Double(v * v)
                histogram[min(Int(abs(v) * 999), 999)] += 1
            }
        }
        let rms = Float(sqrt(sumSquares / Double(length * channels)))
        var remaining = (length * channels) / 1000
        var bin = 999
        while bin > 0 && remaining > 0 { remaining -= histogram[bin]; bin -= 1 }
        let p999 = Float(bin + 1) / 999
        return min(targetRMS / max(rms, 1e-5), 0.8 / max(p999, 1e-5), 25)
    }

    /// Transparent below the knee, smoothly saturating to ±0.98 above it.
    @inline(__always) static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.8
        let a = abs(x)
        guard a > knee else { return x }
        let y = knee + 0.18 * tanh((a - knee) / 0.18)
        return x < 0 ? -y : y
    }

    static func audibleRange(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int, sampleRate: Double) -> (Int, Int) {
        let window = max(Int(sampleRate * 0.02), 1)
        let count = frames / window
        guard count > 4 else { return (0, frames) }
        var energy = [Float](repeating: 0, count: count)
        for w in 0..<count {
            var sum: Float = 0
            for c in 0..<channels {
                let p = data[c] + w * window
                for i in 0..<window { sum += p[i] * p[i] }
            }
            energy[w] = sum / Float(window * channels)
        }
        let mean = energy.reduce(0, +) / Float(count)
        let threshold = mean * 0.003
        let first = energy.firstIndex { $0 > threshold } ?? 0
        let last = energy.lastIndex { $0 > threshold } ?? (count - 1)
        return (first * window, min((last + 1) * window, frames))
    }
}
