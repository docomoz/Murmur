import AVFoundation
import AppKit
import Combine
import SwiftUI

/// Plain AppKit entry point: a SwiftUI `App` would insist on opening a window of its own.
@main
enum MurmurMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(SelfTest.failed ? 1 : 0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            SelfTest.snapshot(to: CommandLine.arguments[i + 1])
            exit(0)
        }
        if CommandLine.arguments.contains("--playtest") {
            SelfTest.playtest()
        }
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

/// Owns the menu bar icon and the glass panel that drops down from it.
///
/// The icon can be invisible — hidden behind the MacBook notch when the bar is crowded, or switched
/// off in System Settings — so the mixer also opens as a regular window on the very first launch
/// and on a repeat launch (double-click in Finder/Launchpad) whenever the panel can't be placed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = MixStore()
    private var statusItem: NSStatusItem?
    private var panel: GlassPanel?
    private var window: NSWindow?
    private var storeObserver: AnyCancellable?
    private var outsideClickMonitor: Any?
    private var panelSize = CGSize(width: 292, height: 600)
    private var aboutWindow: NSWindow?
    private var glassViews: [NSView] = []
    private var iconTimer: Timer?
    private var iconPhase = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !SelfTest.isRendering, !CommandLine.arguments.contains("--playtest") else { return }
        Analytics.start(appID: Analytics.appIDFromBundle)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.imagePosition = .imageLeading
        statusItem = item
        updateStatusItem()
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
                self?.applyAppearance()
            }
        }

        Updater.shared.start()
        // Siri / Spotlight phrases with a mix name ("Play Focus in Murmur") need the current list of mixes.
        MurmurShortcuts.updateAppShortcutParameters()

        let firstLaunch = !UserDefaults.standard.bool(forKey: "launchedBefore")
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        if CommandLine.arguments.contains("--open-panel") {
            // Debug: behave as if the menu bar icon was clicked.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.statusItem?.button?.performClick(nil) }
        }
        if firstLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                if self.canPlacePanel() { self.showPanel() } else { self.showWindow() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if canPlacePanel() { showPanel() } else { showWindow() }
        return false
    }

    // MARK: Menu bar icon

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        // While a call has Murmur ducked the bars stop swaying and settle low.
        let hushed = store.isPlaying && !store.active.isEmpty && store.isDucked
        let playing = store.isPlaying && !store.active.isEmpty && !hushed
        if playing, iconTimer == nil {
            // A gentle, slow sway of the bars while sound is playing — 12 fps is plenty for it.
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.iconPhase += 1.0 / 12
                    self.statusItem?.button?.image = StatusIcon.image(phase: self.iconPhase, playing: true,
                                                                      badge: self.store.pomodoro?.phase.symbol)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            iconTimer = timer
        } else if !playing {
            iconTimer?.invalidate()
            iconTimer = nil
        }
        let badge = store.pomodoro.map { $0.isPaused ? "pause" : $0.phase.symbol }
        button.image = StatusIcon.image(phase: iconPhase, playing: playing, badge: badge, hushed: hushed)
        if let label = store.pomodoroLabel {
            button.attributedTitle = NSAttributedString(string: " " + label, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
        } else {
            button.title = ""
        }
    }

    /// Whether the menu bar icon reports a real on-screen position to hang the panel from.
    /// On recent macOS the bar is drawn by the system and a hidden icon (notch, Settings) reports
    /// an off-screen frame — then the mixer opens as a window instead.
    private func canPlacePanel() -> Bool {
        guard let item = statusItem, item.isVisible,
              let window = item.button?.window, let screen = window.screen else { return false }
        return screen.frame.intersects(window.frame) && window.frame.minY >= screen.frame.minY
    }

    // MARK: Panel

    @objc private func togglePanel() {
        if panel?.isVisible == true { closePanel() } else { showPanel(fromClick: true) }
    }

    /// Drops the panel from the menu bar icon. When the system doesn't report where the icon is,
    /// a click still tells us: the pointer is on it. Otherwise fall back to the window.
    func showPanel(fromClick: Bool = false) {
        let anchorX: CGFloat
        let screen: NSScreen
        if canPlacePanel(), let button = statusItem?.button, let buttonWindow = button.window, let s = buttonWindow.screen {
            anchorX = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)).midX
            screen = s
        } else if fromClick {
            let mouse = NSEvent.mouseLocation
            guard let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return showWindow() }
            anchorX = mouse.x
            screen = s
        } else {
            return showWindow()
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // The window is `margin` bigger than the glass on every side; place the glass, not the window.
        let size = panelSize
        let m = GlassHost.margin
        let area = screen.visibleFrame
        let x = min(max(anchorX - size.width / 2, area.minX + 8 - m), area.maxX - size.width + m - 8)
        panel.setFrame(NSRect(x: x, y: area.maxY - size.height + m - 6, width: size.width, height: size.height), display: true)
        let button = statusItem?.button

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        button?.highlight(true)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        statusItem?.button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> GlassPanel {
        let panel = GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 292, height: 600))
        let content = GlassHost.makePanelContent(ContentView().environmentObject(store))
        panelSize = content.frame.size
        panel.contentView = content
        panel.onClose = { [weak self] in self?.closePanel() }
        glassViews.append(content)
        applyAppearance()
        return panel
    }

    // MARK: Appearance

    /// Applies the Theme / Backdrop settings to every glass window.
    private func applyAppearance() {
        let appearance: NSAppearance? = switch store.theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        for window in [panel, window, aboutWindow].compactMap({ $0 }) where window.appearance != appearance {
            window.appearance = appearance
        }
        let tint = store.active.first.flatMap { Sound.byID[$0] }.map { NSColor($0.tint) }
        for view in glassViews {
            GlassHost.style(view, backdrop: store.backdrop, mixTint: tint)
        }
    }

    // MARK: About

    func showAbout() {
        closePanel()
        if aboutWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = L("О Murmur", "About Murmur")
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: AboutView())
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            window.center()
            aboutWindow = window
            applyAppearance()
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Window fallback

    func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Murmur"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            let hosting = NSHostingView(rootView: ContentView(inWindow: true).environmentObject(store))
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            window.center()
            self.window = window
            applyAppearance()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The menu bar icon: bars in a circle, drawn by hand so they can sway softly while playing.
/// While Pomodoro runs, a small phase glyph (`badge`, an SF Symbol) follows the circle.
enum StatusIcon {
    private static let base: [CGFloat] = [0.46, 0.88, 0.66, 0.40]
    private static let speed: [Double] = [0.9, 0.62, 1.1, 0.75]

    static func image(phase: Double, playing: Bool, badge: String? = nil, hushed: Bool = false) -> NSImage {
        let glyph = badge.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        let extra = glyph.map { $0.size.width + 4 } ?? 0
        let image = NSImage(size: NSSize(width: 18 + extra, height: 18), flipped: false) { bounds in
            let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
            if let glyph {
                let size = glyph.size
                glyph.draw(in: NSRect(x: 22, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            }
            NSColor.black.set()
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.6, dy: 1.6))
            circle.lineWidth = 1.3
            circle.stroke()

            let width: CGFloat = 1.8, gap: CGFloat = 1.4
            var x = rect.midX - (4 * width + 3 * gap) / 2
            for i in 0..<4 {
                var level = base[i]
                if playing {
                    level *= 0.8 + 0.2 * CGFloat(sin(phase * speed[i] * 2 * .pi + Double(i) * 1.7))
                } else if hushed {
                    level *= 0.45
                }
                let height = max(10 * level, width)
                NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: width, height: height),
                             xRadius: width / 2, yRadius: width / 2).fill()
                x += width + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Murmur"
        return image
    }
}

/// Borderless floating panel that can take keyboard focus (space = play/pause) without
/// activating the app, like system menu bar extras.
final class GlassPanel: NSPanel {
    var onClose: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // the window is bigger than the glass; Liquid Glass draws its own rim
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    /// A click in the transparent margin around the glass counts as a click outside the panel.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown, let content = contentView,
           !content.bounds.insetBy(dx: GlassHost.margin, dy: GlassHost.margin).contains(event.locationInWindow) {
            onClose?()
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func resignKey() {
        super.resignKey()
        onClose?()
    }
}

/// Puts SwiftUI content on real system glass: `NSGlassEffectView` on macOS 26+ (follows the
/// Liquid Glass look chosen in System Settings), a vibrant menu material before that.
enum GlassHost {
    static let panelRadius: CGFloat = 22
    /// Transparent room around the glass inside the panel window. Liquid Glass draws its rim light
    /// slightly outside its shape; if the window ended right at the glass edge that was cut off by
    /// the window rectangle and showed up as dark lines in the corners. No extra shadow is added.
    static let margin: CGFloat = 22

    /// Backdrop styles: plain system glass, or tinted by the mix.
    @MainActor
    static func style(_ view: NSView, backdrop: PanelBackdrop, mixTint: NSColor?) {
        if #available(macOS 26.0, *), let glass = view.subviews.compactMap({ $0 as? NSGlassEffectView }).first {
            glass.style = .regular
            glass.tintColor = backdrop == .mix ? mixTint.map(Self.mixTint) : nil
        }
    }

    /// The mix color as a glass tint that keeps text readable: deep and dark in dark mode,
    /// soft and pale in light mode.
    static func mixTint(_ color: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return (color.blended(withFraction: 0.65, of: .black) ?? color).withAlphaComponent(0.55)
            }
            return (color.blended(withFraction: 0.55, of: .white) ?? color).withAlphaComponent(0.3)
        }
    }

    /// Panel content on real system glass: `NSGlassEffectView` on macOS 26+ (follows the Liquid
    /// Glass look chosen in System Settings), a vibrant menu material before that. Returns a
    /// transparent container `margin` larger than the content on every side.
    @MainActor
    static func makePanelContent<Content: View>(_ content: Content) -> NSView {
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        let glassFrame = NSRect(x: margin, y: margin, width: size.width, height: size.height)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 2 * margin, height: size.height + 2 * margin))
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: glassFrame)
            glass.cornerRadius = panelRadius
            glass.contentView = hosting
            container.addSubview(glass)
        } else {
            let effect = NSVisualEffectView(frame: glassFrame)
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = panelRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
            container.addSubview(effect)
        }
        return container
    }
}

/// `Murmur --selftest`: builds every loop and prints level and seam statistics.
enum SelfTest {
    static var isRendering = false
    /// Set by checks that can fail outright; `--selftest` then exits with status 1.
    static var failed = false

    @MainActor
    static func run() {
        checkDrift()
        print("sound        rms   peak  repeat  (old loop → repeat 1.00; lower = less repetitive)")
        for sound in Sound.all {
            switch sound.source {
            case .file where sound.region != nil: report(sound)
            case .file, .heartbeat: reportTexture(sound)
            case .whiteNoise: continue
            }
        }
        let duckFailures = DuckEnvelope.selfCheck()
        print("\nduck envelope: " + (duckFailures.isEmpty ? "ok" : "FAIL " + duckFailures.joined(separator: "; ")))
        let callFailures = CallDetector.selfCheck()
        print("call detector: " + (callFailures.isEmpty ? "ok" : "FAIL " + callFailures.joined(separator: "; ")))
        let (listenerCalls, listenerFailures) = MicMonitor.selfCheckListeners()
        print("mic listeners: " + (listenerFailures.isEmpty ? "ok" : "FAIL " + listenerFailures.joined(separator: "; "))
              + " (\(listenerCalls) calls for one sound elsewhere)")
        if !listenerFailures.isEmpty { failed = true }
        // Reads the HAL's process list only — never opens the microphone.
        let recorders = MicMonitor.recorderNames()
        let calls = MicMonitor.callNames()
        print("mic monitor: \(MicMonitor.processes().count) audio clients visible, recording now: "
              + (recorders.isEmpty ? "nobody" : recorders.joined(separator: ", "))
              + "; would duck for: " + (calls.isEmpty ? "nobody" : calls.joined(separator: ", ")))

        print("\nShuffle, examples:")
        for _ in 0..<12 {
            let levels = MainActor.assumeIsolated { MixStore.randomLevels() }
            print("  " + levels.sorted { $0.value > $1.value }.compactMap { Sound.byID[$0.key]?.name }.joined(separator: " + "))
        }
        if !reportIntents() { failed = true }
        reportChime()
        if !checkPomodoro() { failed = true }
        if !checkAnalyticsWrapper() { failed = true }
    }

    /// Test modes never reach TelemetryDeck; the capture hook sees every signal, minutes rounded to 0.1.
    @MainActor
    private static func checkAnalyticsWrapper() -> Bool {
        var failures: [String] = []
        MixStore.sandboxed = true
        Analytics.start(appID: "X")
        if Analytics.isLive { failures.append("live in sandboxed mode") }
        var got: [AnalyticsSignal] = []
        Analytics.capture = { got.append($0) }
        Analytics.send("Test.event", ["a": "b"], minutes: 1.26)
        Analytics.capture = nil
        if got != [AnalyticsSignal(name: "Test.event", parameters: ["a": "b"], minutes: 1.3)] { failures.append("captured \(got)") }
        print("\nanalytics wrapper: " + (failures.isEmpty ? "ok" : "FAIL " + failures.joined(separator: "; ")))
        return failures.isEmpty
    }

    /// Checks the App Intents metadata that build.sh puts into the bundle: every intent is there,
    /// and every text the system shows has a Russian translation in ru.lproj. Returns false on failure.
    private static func reportIntents() -> Bool {
        print("\nApp Intents:")
        let resources = Bundle.main.resourceURL!
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("Metadata.appintents/extract.actionsdata")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("  FAIL no Metadata.appintents in the bundle (run from build/Murmur.app, built by build.sh)")
            return false
        }
        let actions = (root["actions"] as? [String: Any] ?? [:]).keys.sorted()
        let expected = ["PlayMixIntent", "ShuffleIntent", "TogglePlaybackIntent", "PlayIntent", "PauseIntent", "StopIntent",
                        "StartPomodoroIntent", "StopPomodoroIntent", "SetVolumeIntent", "MurmurFocusFilter"]
        let missing = expected.filter { !actions.contains($0) }
        let shortcuts = (root["autoShortcuts"] as? [Any])?.count ?? 0
        let entities = (root["entities"] as? [String: Any] ?? [:]).keys.sorted()
        print("  actions \(actions.count), App Shortcuts \(shortcuts), entities \(entities.joined(separator: ", "))")
        var ok = missing.isEmpty
        if !ok { print("  FAIL missing actions: \(missing.joined(separator: ", "))") }

        // Every key the system will look up, split by table: phrases → AppShortcuts, the rest → Localizable.
        var keys: (texts: Set<String>, phrases: Set<String>) = ([], [])
        func walk(_ value: Any, phrase: Bool) {
            if let dict = value as? [String: Any] {
                for (k, v) in dict {
                    if let s = v as? String, k == "key" || k == "formatString" {
                        if phrase { keys.phrases.insert(s) } else { keys.texts.insert(s) }
                    } else {
                        walk(v, phrase: phrase || k == "phraseTemplates")
                    }
                }
            } else if let array = value as? [Any] {
                for v in array { walk(v, phrase: phrase) }
            }
        }
        walk(root, phrase: false)
        for (table, wanted) in [("Localizable", keys.texts), ("AppShortcuts", keys.phrases)] {
            let url = resources.appendingPathComponent("ru.lproj/\(table).strings")
            let russian = NSDictionary(contentsOf: url) as? [String: String] ?? [:]
            let untranslated = wanted.filter { russian[$0] == nil }.sorted()
            print("  ru.lproj/\(table).strings: \(wanted.count - untranslated.count)/\(wanted.count) translated")
            for key in untranslated { print("  FAIL no Russian for \"\(key)\"") }
            if !untranslated.isEmpty || wanted.isEmpty { ok = false }
        }
        let mixes = MainActor.assumeIsolated { MixStore.mixesForIntents.count }
        print("  mixes offered to Shortcuts: \(mixes)")
        return ok
    }

    /// Living Mix: every sound's drift stays within ±`drift` dB, moves slowly (no faster than
    /// `maxRate` dB/s, also while being switched off), really moves, and is exactly 1.0 for sounds
    /// without drift and once the feature is off. Also renders the wrapper over a constant signal
    /// to make sure the gain is interpolated inside buffers (no zipper steps).
    private static func checkDrift() {
        let dt = 512 / TextureGenerator.sampleRate
        let maxRate = 0.25          // dB/s while drifting
        let maxToggleRate = 0.75    // dB/s while fading the drift in/out
        var problems: [String] = []
        var summary: [String] = []

        func db(_ g: Float) -> Double { 20 * log10(Double(g)) }

        for sound in Sound.all {
            var drift = Drift(depthDB: sound.drift)
            var lo = 0.0, hi = 0.0, rate = 0.0
            var previous = db(drift.gain)
            for _ in 0..<Int(30 * 60 / dt) {
                let g = drift.advance(dt, enabled: true)
                let v = db(g)
                if sound.drift == 0 && g != 1 { problems.append("\(sound.id): no-drift sound moved (\(g))"); break }
                lo = min(lo, v); hi = max(hi, v)
                rate = max(rate, abs(v - previous) / dt)
                previous = v
            }
            if sound.drift > 0 {
                if lo < -sound.drift - 1e-6 || hi > sound.drift + 1e-6 {
                    problems.append(String(format: "%@: out of range %.2f…%.2f dB (±%.2f)", sound.id as NSString, lo, hi, sound.drift))
                }
                if rate > maxRate { problems.append(String(format: "%@: too fast, %.3f dB/s", sound.id as NSString, rate)) }
                if hi - lo < sound.drift * 0.5 { problems.append(String(format: "%@: barely moves, %.2f dB p-p", sound.id as NSString, hi - lo)) }
                summary.append(String(format: "%@ ±%.1f (%.1f…%+.1f, %.2f dB/s)", sound.id as NSString, sound.drift, lo, hi, rate))
            }

            // Switching Living Mix off glides back to exactly 1.0, slowly.
            var fading = rate
            for _ in 0..<Int((Drift.toggleTime + 1) / dt) {
                let v = db(drift.advance(dt, enabled: false))
                fading = max(fading, abs(v - previous) / dt)
                previous = v
            }
            if drift.gain != 1 { problems.append("\(sound.id): not 1.0 after switching off (\(drift.gain))") }
            if fading > maxToggleRate { problems.append(String(format: "%@: switch-off too fast, %.3f dB/s", sound.id as NSString, fading)) }
            var off = Drift(depthDB: sound.drift, enabled: false)
            for _ in 0..<1000 where off.advance(dt, enabled: false) != 1 {
                problems.append("\(sound.id): disabled drift is not 1.0"); break
            }
        }

        // The wrapper over a constant 1.0 signal: output = gain, and it never steps.
        final class Constant: RealtimeGenerator {
            func render(frames: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
                for b in UnsafeMutableAudioBufferListPointer(list) {
                    b.mData?.assumingMemoryBound(to: Float.self).update(repeating: 1, count: frames)
                }
            }
        }
        let toggle = DriftSwitch()
        let wrapper = DriftingGenerator(Constant(), depthDB: 3, toggle: toggle)
        let block = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: TextureGenerator.sampleRate, channels: 2)!, frameCapacity: 512)!
        block.frameLength = 512
        var last: Float = -1, step: Float = 0
        for n in 0..<Int(120 / dt) {
            if n == Int(100 / dt) { toggle.enabled = false }
            wrapper.render(frames: 512, into: block.mutableAudioBufferList)
            let p = block.floatChannelData![0]
            for i in 0..<512 {
                if last >= 0 { step = max(step, abs(p[i] - last)) }
                last = p[i]
            }
        }
        if step > 1e-5 { problems.append(String(format: "wrapper: sample step %.2e (zipper)", step)) }
        if last != 1 { problems.append("wrapper: not 1.0 after switching off (\(last))") }

        if problems.isEmpty {
            print(String(format: "living mix OK (max sample step %.1e): ", step) + summary.joined(separator: ", "))
        } else {
            failed = true
            for p in problems { print("FAIL living mix:", p) }
        }
        print("")
    }

    /// The Pomodoro cue: decodes, has a soft tail, no NaN, no clipping.
    private static func reportChime() {
        print("\nPomodoro cue (bowl):")
        for pitch in [1.0, 0.84] {
            guard let buffer = try? Chime.buffer(pitch: pitch), let data = buffer.floatChannelData else {
                print("  FAIL chime pitch \(pitch)")
                continue
            }
            let n = Int(buffer.frameLength)
            var peak: Float = 0, sum: Double = 0, broken = false
            for i in 0..<n {
                let v = data[0][i]
                if !v.isFinite { broken = true }
                peak = max(peak, abs(v))
                sum += Double(v * v)
            }
            print(String(format: "  pitch %.2f  %.1fs  rms %.3f  peak %.2f  last %.4f %@", pitch, Double(n) / buffer.format.sampleRate,
                         sqrt(sum / Double(n)), peak, abs(data[0][n - 1]), (broken ? "NaN!" : "") as NSString))
        }
    }

    /// Pomodoro state machine: phase order, long breaks, timing math, pausing, and how it drives the mix:
    /// silence in breaks, the same mix back after, the user's play/pause steering the countdown.
    @MainActor
    private static func checkPomodoro() -> Bool {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        let plan = PomodoroPlan.standard
        let order = (0..<16).map { plan.phase(at: $0) }
        let cycle: [PomodoroPhase] = [.focus, .shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak]
        expect(order == cycle + cycle, "phase order \(order)")
        expect(plan.duration(of: .focus) == 25 * 60 && plan.duration(of: .shortBreak) == 5 * 60
               && plan.duration(of: .longBreak) == 15 * 60, "25/5/15 durations")
        expect(PomodoroPlan.presets.map(\.focus) == [15, 20, 25, 30, 45], "menu lengths")
        expect(PomodoroPlan.byID("20").focus == 20 && PomodoroPlan.byID("junk") == .standard
               && PomodoroPlan.byID("0") == .standard, "saved length")

        // On time: each phase starts exactly where the last one ended; one full set = 130 min.
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var state = PomodoroState(plan: plan, start: t0)
        expect(state.end == t0 + 25 * 60 && state.round == 1, "first focus")
        var rounds: [Int] = []
        for _ in 0..<8 {
            rounds.append(state.round)
            state = state.advanced(at: state.end + 0.5)   // the tick lands a bit late
        }
        expect(rounds == [1, 1, 2, 2, 3, 3, 4, 4], "rounds \(rounds)")
        expect(state.phase == .focus && state.round == 1, "second set starts with focus 1")
        expect(abs(state.end.timeIntervalSince(t0) - (130 + 25) * 60) < 0.001,
               "130 min per set, got \(state.end.timeIntervalSince(t0) / 60)")
        expect(state.remaining(at: state.end - 90) == 90 && state.remaining(at: state.end + 3) == 0, "remaining")

        // Slept through the end: the next phase starts now, not in the past.
        let late = state.end + 3600
        let woke = state.advanced(at: late)
        expect(woke.phase == .shortBreak && woke.end == late + 5 * 60, "after sleep")
        // Skipped early: the next phase starts now and runs its full length.
        let early = state.end - 600
        expect(state.advanced(at: early).end == early + 5 * 60, "skip")

        // Paused focus: the countdown stands still, then continues from the same point.
        let p0 = state.end - 600
        let paused = state.paused(at: p0)
        expect(paused.isPaused && paused.remaining(at: p0 + 3600) == 600, "paused countdown stands still")
        let resumed = paused.resumed(at: p0 + 3600)
        expect(!resumed.isPaused && resumed.end == p0 + 3600 + 600, "resumed countdown")
        expect(!paused.advanced(at: p0).isPaused, "next phase is never paused")

        expect(countdownLabel(25 * 60) == "25:00" && countdownLabel(59.2) == "1:00"
               && countdownLabel(0.4) == "0:01" && countdownLabel(5400) == "1:30:00", "countdown labels")

        // The store: a break silences the mix (keeping it), the same mix comes back for focus.
        MixStore.sandboxed = true
        let store = MixStore()
        store.cuesEnabled = false
        store.setMaster(0)
        store.apply(Mix(id: "t", name: "", emoji: "", levels: ["rain": 0.42, "wind": 0.33, "cafe": 0.5]))
        let ownActive = store.active
        let ownVolumes = store.volumes
        store.startPomodoro(minutes: 20)
        expect(store.pomodoro?.phase == .focus && store.pomodoro?.plan.focus == 20 && store.isPlaying
               && store.pomodoroRemaining != nil, "starts in focus with the mix playing")
        store.skipPomodoroPhase()
        expect(store.pomodoro?.phase == .shortBreak && !store.isPlaying && store.active == ownActive, "break is quiet, mix kept")
        store.skipPomodoroPhase()
        expect(store.pomodoro?.phase == .focus && store.isPlaying && store.active == ownActive
               && store.volumes == ownVolumes, "focus brings the same mix back")

        // The user's pause freezes focus, play resumes it.
        store.togglePlay()
        expect(store.pomodoro?.isPaused == true && !store.isPlaying, "pause freezes focus")
        store.togglePlay()
        expect(store.pomodoro?.isPaused == false && store.isPlaying && store.pomodoro?.phase == .focus, "play resumes focus")

        // Play during a break ends it early.
        store.skipPomodoroPhase()
        expect(store.pomodoro?.phase == .shortBreak && !store.isPlaying, "second break")
        store.togglePlay()
        expect(store.pomodoro?.phase == .focus && store.isPlaying, "play ends the break")

        // Stopping leaves the sound alone; starting with nothing chosen plays Focus.
        store.stopPomodoro()
        expect(store.pomodoro == nil && store.isPlaying, "stop keeps the sound")
        store.stopAll()
        store.startPomodoro()
        expect(store.isPlaying && Set(store.active) == Set(Mix.presets.first { $0.id == "b.focus" }!.levels.keys),
               "empty start plays the Focus mix")
        expect(store.pomodoro?.plan.focus == 20, "last length remembered")
        store.stopAll()
        expect(store.pomodoro == nil, "stop all ends Pomodoro")

        print("\nPomodoro: " + (failures.isEmpty ? "OK" : "FAIL"))
        failures.forEach { print("  ✗ " + $0) }
        return failures.isEmpty
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
        MixStore.sandboxed = true
        let store = MixStore()
        store.previewUserMixes([
            Mix(id: "u1", name: L("Вечерний", "Evening"), emoji: "🌙", levels: ["rain": 0.5, "vinyl": 0.3]),
            Mix(id: "u2", name: L("Глубина", "Deep"), emoji: "🫧", levels: ["whale": 0.6, "underwater": 0.4]),
        ])
        store.apply(Mix.presets[0])
        store.setMaster(store.master)
        func renderPanel(_ name: String, schemes: [ColorScheme] = [.light, .dark]) {
            for scheme in schemes {
                let view = ContentView()
                    .environmentObject(store)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.cgImage else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(prefix)\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        renderPanel("")
        // About window and the menu bar icon (paused + two moments of the playing sway).
        let about = ImageRenderer(content: AboutView().background(Color(nsColor: .windowBackgroundColor)))
        about.scale = 2
        if let image = about.cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(prefix)-about.png"))
        }
        let icons = ImageRenderer(content: HStack(spacing: 12) {
            ForEach([(0.0, false, nil), (0.3, true, nil), (0.9, true, nil),
                     (0.5, true, "scope"), (0.7, true, "cup.and.saucer")], id: \.0) { item in
                Image(nsImage: StatusIcon.image(phase: item.0, playing: item.1, badge: item.2))
                    .resizable().aspectRatio(contentMode: .fit).frame(height: 72)
            }
        }.padding(8).background(Color.white))
        icons.scale = 1
        if let image = icons.cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(prefix)-icon.png"))
        }
        // Menu bar items at their real size (2× = retina), light and dark bar, as the system tints templates.
        let bar = ImageRenderer(content: VStack(spacing: 0) {
            ForEach([(Color(white: 0.92), Color.black), (Color(white: 0.16), Color.white)], id: \.1) { colors in
                HStack(spacing: 14) {
                    ForEach([("scope", "24:13"), ("pause", "18:40"), ("cup.and.saucer", "4:59")], id: \.1) { item in
                        HStack(spacing: 4) {
                            Image(nsImage: StatusIcon.image(phase: 0.4, playing: true, badge: item.0)).renderingMode(.template)
                            Text(item.1).font(.system(size: NSFont.systemFontSize).monospacedDigit()).fixedSize()
                        }
                    }
                }
                .foregroundStyle(colors.1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(colors.0)
            }
        })
        bar.scale = 2
        if let image = bar.cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(prefix)-menubar.png"))
        }

        // Pomodoro: the footer pill in focus, then in a quiet break.
        store.cuesEnabled = false
        store.startPomodoro(minutes: PomodoroPlan.standard.focus)
        renderPanel("-pomodoro", schemes: [.light])
        store.skipPomodoroPhase()
        renderPanel("-pomodoro-break", schemes: [.dark])
    }

    /// Plays every preset through the real engine for a moment and reports the output level.
    @MainActor
    static func playtest() {
        MixStore.sandboxed = true
        let store = MixStore()
        store.setMaster(0.22)   // quiet while testing; the level report compensates for it
        let mixes = Mix.presets + [Mix(id: "n", name: "White noise", emoji: "", levels: ["white": 0.5]), Mix(id: "b", name: "Bowl", emoji: "", levels: ["bowl": 0.6]), Mix(id: "c", name: "Cat+vinyl", emoji: "", levels: ["cat": 0.6, "vinyl": 0.5]), Mix(id: "w", name: "Whales", emoji: "", levels: ["whale": 0.7]), Mix(id: "h", name: "Heart", emoji: "", levels: ["heartbeat": 0.6])]
        var index = 0
        func next() {
            guard index < mixes.count else {
                // Last: the Pomodoro cue alone, over silence.
                store.stopAll()
                store.debugCue()
                store.debugMeasure(after: 1.0, seconds: 2.0) { rms, channels in
                    print(String(format: "%-12@ channels %d  output rms %.3f (%.1f dBFS)", "Pomodoro cue" as NSString,
                                 channels, rms, 20 * log10(max(rms, 1e-6))))
                    exit(0)
                }
                return
            }
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
