import AVFoundation
import AppKit
import SwiftUI

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
        if CommandLine.arguments.contains("--playtest") {
            SelfTest.playtest()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            SelfTest.snapshot(to: CommandLine.arguments[i + 1])
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(appDelegate.store)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Murmur lives in the menu bar, but that icon can be invisible: hidden behind the MacBook notch
/// when the bar is crowded, or switched off in System Settings. So the mixer can also open as a
/// regular window — on a repeat launch (double-click in Finder/Launchpad) or when the icon isn't
/// actually on screen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = MixStore()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !SelfTest.isRendering, !CommandLine.arguments.contains("--playtest") else { return }
        let firstLaunch = !UserDefaults.standard.bool(forKey: "launchedBefore")
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            let visible = Self.statusItemVisible()
            NSLog("Murmur: status item visible = \(visible)")
            if firstLaunch || !visible { self?.showWindow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: ContentView(inWindow: true).environmentObject(store))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Murmur"
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// True only if the menu bar icon is really on screen (not switched off, not under the notch).
    private static func statusItemVisible() -> Bool {
        let items = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }
        return items.contains { item in
            guard item.isVisible, item.occlusionState.contains(.visible),
                  let screen = item.screen ?? NSScreen.main else { return false }
            let frame = item.frame
            guard screen.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let notch = CGRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX, height: left.height)
                if notch.insetBy(dx: -4, dy: 0).intersects(frame) { return false }
            }
            return true
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var store: MixStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: store.isPlaying ? "waveform.circle.fill" : "waveform.circle")
            if let label = store.timerLabel {
                Text(label).monospacedDigit()
            }
        }
    }
}

/// `Murmur --selftest`: builds every loop and prints level and seam statistics.
enum SelfTest {
    static var isRendering = false

    static func run() {
        print("sound        rms   peak  repeat  (old loop → repeat 1.00; lower = less repetitive)")
        for sound in Sound.all {
            switch sound.source {
            case .file where sound.region != nil: report(sound)
            case .file, .heartbeat: reportTexture(sound)
            case .noise, .tone: continue
            }
        }
    }

    /// Renders 150 s of the live generator and checks how similar the audio is one old-loop-length
    /// apart. A plain loop is identical there (correlation 1.0); a good texture is near 0.
    private static func reportTexture(_ sound: Sound) {
        let start = Date()
        let generator: RealtimeGenerator
        let period: Double
        do {
            if sound.source == .heartbeat {
                generator = HeartbeatGenerator()
                period = 60.0 / 58
            } else {
                generator = try TextureGenerator.load(sound, cache: nil)
                let loop = try LoopBuilder.buffer(for: sound)
                period = Double(loop.frameLength) / loop.format.sampleRate
            }
        } catch {
            print("FAIL", sound.id, error)
            return
        }
        let sr = TextureGenerator.sampleRate
        let total = Int(150 * sr)
        let block = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!, frameCapacity: 1024)!
        block.frameLength = 1024
        var signal = [Float](repeating: 0, count: total)
        var written = 0
        while written < total {
            generator.render(frames: 1024, into: block.mutableAudioBufferList)
            let n = min(1024, total - written)
            let left = block.floatChannelData![0]
            for i in 0..<n { signal[written + i] = left[i] }
            written += n
        }
        var sum: Double = 0
        var peak: Float = 0
        var broken = false
        for v in signal {
            if !v.isFinite { broken = true }
            sum += Double(v * v)
            peak = max(peak, abs(v))
        }
        var worst = 0.0
        let window = Int(1.5 * sr)
        let lag = Int(period * sr)
        for k in 0..<8 {
            let a = Int((5 + Double(k) * 15) * sr)
            guard a + lag + window < total else { break }
            var ab = 0.0, aa = 0.0, bb = 0.0
            for i in 0..<window {
                let x = Double(signal[a + i]), y = Double(signal[a + lag + i])
                ab += x * y; aa += x * x; bb += y * y
            }
            worst = max(worst, abs(ab) / max(sqrt(aa * bb), 1e-12))
        }
        print(String(format: "%-11@ %.3f  %.2f   %.2f   loop was %5.1fs  %@ %.0fms",
                     sound.id as NSString, sqrt(sum / Double(total)), peak, worst, period,
                     (broken ? "NaN!" : "") as NSString, Date().timeIntervalSince(start) * 1000))
    }

    /// Renders the panel to PNGs (light + dark) for visual review without clicking the menu bar.
    @MainActor
    static func snapshot(to prefix: String) {
        isRendering = true
        let store = MixStore()
        store.apply(Mix.presets[0])
        store.setMaster(store.master)
        for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let view = ContentView()
                .environmentObject(store)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(suffix).png"))
        }
    }

    /// Plays every preset through the real engine for a moment and reports the output level.
    @MainActor
    static func playtest() {
        let store = MixStore()
        let mixes = Mix.presets + [Mix(id: "n", name: "Шумы", emoji: "", levels: ["white": 0.5, "pink": 0.5, "brown": 0.5]), Mix(id: "t", name: "Тоны", emoji: "", levels: ["tone432": 0.3, "tone528": 0.3]), Mix(id: "w", name: "Киты", emoji: "", levels: ["whale": 0.7]), Mix(id: "h", name: "Сердце", emoji: "", levels: ["heartbeat": 0.6])]
        var index = 0
        func next() {
            guard index < mixes.count else { store.stopAll(); exit(0) }
            let mix = mixes[index]
            index += 1
            store.apply(mix)
            store.debugMeasure(after: 2.0, seconds: 1.5) { rms, channels in
                print(String(format: "%-12@ channels %d  output rms %.3f (%.1f dBFS)", mix.name as NSString, channels, rms, 20 * log10(max(rms, 1e-6))))
                next()
            }
        }
        next()
        RunLoop.main.run()
    }

    private static func report(_ sound: Sound) {
        let start = Date()
        guard let buffer = try? LoopBuilder.buffer(for: sound), let data = buffer.floatChannelData else {
            print("FAIL", sound.id)
            return
        }
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var sum: Double = 0
        var peak: Float = 0
        var meanStep: Double = 0
        for c in 0..<channels {
            for i in 0..<n {
                let v = data[c][i]
                sum += Double(v * v)
                peak = max(peak, abs(v))
                if i > 0 { meanStep += Double(abs(v - data[c][i - 1])) }
            }
        }
        meanStep /= Double((n - 1) * channels)
        // The jump across the loop point should look like any other sample-to-sample step.
        var seam: Double = 0
        for c in 0..<channels { seam += Double(abs(data[c][0] - data[c][n - 1])) }
        seam /= Double(channels)
        let line = String(format: "%-11@ %6.1fs  rms %.3f  peak %.2f  seam/step %5.2f  %.0fms",
                          sound.id as NSString, Double(n) / buffer.format.sampleRate,
                          sqrt(sum / Double(n * channels)), peak, seam / max(meanStep, 1e-9),
                          Date().timeIntervalSince(start) * 1000)
        print(line)
    }
}
