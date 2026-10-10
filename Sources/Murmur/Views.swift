import AppKit
import SwiftUI

enum Theme {
    /// Set by `MixStore`; views re-render on store changes and pick the new colors up.
    nonisolated(unsafe) static var accent: AccentChoice = .system

    static var tint1: Color { Color(nsColor: accent.colors.0) }
    static var tint2: Color { Color(nsColor: accent.colors.1) }
    static var gradient: LinearGradient { LinearGradient(colors: [tint1, tint2], startPoint: .leading, endPoint: .trailing) }
    static var iconGradient: LinearGradient { LinearGradient(colors: [tint1, tint2], startPoint: .top, endPoint: .bottom) }
    /// Accent for text on glass: a touch darker in light mode so it stays readable.
    static var link: Color {
        let base = accent.colors.0
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? (base.blended(withFraction: 0.2, of: .white) ?? base)
                : (base.blended(withFraction: 0.25, of: .black) ?? base)
        })
    }

    // Semantic colors that follow light/dark. Dimmed (off) items stay clearly readable on light glass.
    static let dimText = Color(light: 0x4A4F57, dark: 0xB4BAC2)
    static let dimIcon = Color(light: 0x5F656E, dark: 0x9EA5AE)
    static let track = Color(light: 0xC9CED4, dark: 0x4A4F56)
    static let fillOff = Color(light: 0x8D939B, dark: 0x8A9098)
    static let thumbOff = Color(light: 0x6F757E, dark: 0xA3A9B1)
    static let hover = Color.primary.opacity(0.07)
}

extension Color {
    /// A color that follows the panel's light/dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        })
    }
}

// MARK: Liquid Glass

extension View {
    /// Liquid Glass on macOS 26+, a frosted material on older systems.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *), !SelfTest.isRendering {
            self.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
        } else {
            self
                .background(shape.fill(tint.map { AnyShapeStyle($0.opacity(0.55)) } ?? AnyShapeStyle(.thinMaterial)))
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}

/// Lets neighbouring glass shapes blend and morph into each other (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *), !SelfTest.isRendering {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: Panel

struct ContentView: View {
    @EnvironmentObject private var store: MixStore
    /// Shown as a standalone window (traffic lights at the top-left) instead of the menu bar panel.
    var inWindow = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
                .padding(.top, inWindow ? 30 : 14)
                .padding(.horizontal, 14)

            PresetStrip()
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider().opacity(0.5).padding(.horizontal, 14)

            if SelfTest.isRendering {
                list
            } else {
                ScrollView(showsIndicators: false) { list }
                    .frame(height: 420)
            }

            Divider().opacity(0.5).padding(.horizontal, 14)

            FooterView()
        }
        .frame(width: 292)
        .background(store.backdrop == .mix ? Aurora() : nil)
        // The panel's glass is rounded; keep the content (and its glow) inside those corners.
        .clipShape(RoundedRectangle(cornerRadius: inWindow ? 0 : GlassHost.panelRadius, style: .continuous))
        .focusEffectDisabled()
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(Sound.all) { sound in
                SoundRow(sound: sound)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }
}

// MARK: Top bar

private struct TopBar: View {
    @EnvironmentObject private var store: MixStore

    var body: some View {
        GlassGroup(spacing: 16) {
            HStack {
                GlassIconButton(symbol: "checklist") { MenuBuilder.mixes(store) }
                Spacer()
                // Stop + Play sit close enough for their glass to melt into one block.
                HStack(spacing: 3) {
                    StopButton()
                    PlayButton()
                }
                Spacer()
                GlassIconButton(symbol: "gearshape") { MenuBuilder.settings(store) }
            }
        }
    }
}

private struct GlassIconButton: View {
    let symbol: String
    let menu: () -> NSMenu

    var body: some View {
        Button {
            MenuBuilder.popUp(menu())
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .liquidGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

private struct StopButton: View {
    @EnvironmentObject private var store: MixStore

    var body: some View {
        let enabled = !store.active.isEmpty
        Button {
            withAnimation(.easeOut(duration: 0.3)) { store.stopAll() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .opacity(enabled ? 1 : 0.35)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
                .liquidGlass(in: Circle(), interactive: enabled)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!enabled)
    }
}

private struct PlayButton: View {
    @EnvironmentObject private var store: MixStore

    var body: some View {
        Button(action: store.togglePlay) {
            Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                .contentTransition(.symbolEffect(.replace))
                .offset(x: store.isPlaying ? 0 : 1.5)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
                .liquidGlass(in: Circle(), tint: Theme.tint1, interactive: true)
                .shadow(color: Theme.tint1.opacity(store.isPlaying ? 0.5 : 0.2), radius: store.isPlaying ? 12 : 5)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .keyboardShortcut(.space, modifiers: [])
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: store.isPlaying)
    }
}

/// Soft colored light under the glass, taking the colors of whatever is playing.
private struct Aurora: View {
    @EnvironmentObject private var store: MixStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tints = store.active.compactMap { Sound.byID[$0]?.tint }
        let a = tints.first ?? Theme.tint1
        let b = tints.dropFirst().first ?? Theme.tint2
        let c = tints.dropFirst(2).first ?? a
        ZStack {
            Circle().fill(a).frame(width: 220).blur(radius: 80).offset(x: -110, y: -260)
            Circle().fill(b).frame(width: 200).blur(radius: 80).offset(x: 120, y: -150)
            Circle().fill(c).frame(width: 180).blur(radius: 90).offset(x: -60, y: 260)
        }
        // Gentler in dark mode, where bright color under light text costs contrast.
        .opacity(store.isPlaying && !tints.isEmpty ? (colorScheme == .dark ? 0.16 : 0.3) : 0.08)
        .animation(.easeInOut(duration: 1.2), value: store.active)
        .animation(.easeInOut(duration: 0.8), value: store.isPlaying)
        .allowsHitTesting(false)
    }
}

// MARK: Presets

private struct PresetStrip: View {
    @EnvironmentObject private var store: MixStore

    /// The most loved mixes, one click away. The full list lives in the ☰ menu.
    private static let popular: [(id: String, title: String)] = [
        ("b.cafe", "Кафе"), ("b.focus", "Фокус"), ("b.fire", "Костёр"), ("b.sea", "Море"),
    ]

    var body: some View {
        GlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Self.popular, id: \.id) { item in
                    if let mix = Mix.presets.first(where: { $0.id == item.id }) {
                        PresetTile(emoji: mix.emoji, title: item.title,
                                   selected: store.isPlaying && store.isCurrent(mix)) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { store.apply(mix) }
                        }
                    }
                }
                PresetTile(emoji: "🎲", title: "Наугад", selected: false) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { store.randomMix() }
                }
            }
        }
    }
}

private struct PresetTile: View {
    let emoji: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(emoji).font(.system(size: 15))
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                         tint: selected ? Theme.tint1.opacity(0.75) : nil, interactive: true)
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

// MARK: Rows

private struct SoundRow: View {
    @EnvironmentObject private var store: MixStore
    let sound: Sound
    private let hoverState = State<Bool>(initialValue: false)
    private var hover: Bool { get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue } }

    var body: some View {
        let on = store.isActive(sound)

        HStack(spacing: 12) {
            Image(systemName: sound.symbol)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(on ? AnyShapeStyle(sound.tint.gradient) : AnyShapeStyle(Theme.dimIcon))
                .symbolEffect(.bounce, value: on)
                .symbolEffect(.pulse, options: .repeating, isActive: on && store.isPlaying && sound.category == .noise)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(sound.name)
                    .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Color.primary : Theme.dimText)
                    .lineLimit(1)
                LineSlider(
                    value: Binding(get: { store.volume(sound) }, set: { store.setVolume(sound, $0) }),
                    on: on
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hover ? Theme.hover : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.25)) { store.toggle(sound) }
        }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.3), value: on)
    }
}

/// Volume line: thin track, gradient fill, a slim vertical tick for the thumb.
struct LineSlider: View {
    @Binding var value: Double
    var on: Bool
    private let draggingState = State<Bool>(initialValue: false)
    private var dragging: Bool { get { draggingState.wrappedValue } nonmutating set { draggingState.wrappedValue = newValue } }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = CGFloat(value) * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.track)
                    .frame(height: 2.5)
                Capsule()
                    .fill(on ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.fillOff))
                    .frame(width: max(x, 0), height: 2.5)
                Capsule()
                    .fill(on ? Theme.tint1 : Theme.thumbOff)
                    .frame(width: 3, height: dragging ? 13 : 11)
                    .offset(x: min(max(x - 1.5, 0), width - 3))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        value = Double(min(max(g.location.x / width, 0), 1))
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 13)
    }
}

// MARK: Footer

private struct FooterView: View {
    @EnvironmentObject private var store: MixStore

    var body: some View {
        HStack(spacing: 8) {
            Button {
                MenuBuilder.popUp(MenuBuilder.timer(store))
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "moon.zzz")
                    Text(store.timerLabel ?? "Таймер сна")
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.link)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(Capsule())
                .liquidGlass(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .focusable(false)

            Spacer()

            Image(systemName: "speaker.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.dimIcon)
            LineSlider(value: Binding(get: { store.master }, set: { store.setMaster($0) }), on: true)
                .frame(width: 84)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.dimIcon)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: Menus

/// Native AppKit menus: they look right in the menu bar panel and keep the custom icons intact.
@MainActor
enum MenuBuilder {
    static func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    static func mixes(_ store: MixStore) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Готовые миксы"))
        for mix in Mix.presets {
            menu.addItem(ActionMenuItem("\(mix.emoji)  \(mix.name)", checked: store.isPlaying && store.isCurrent(mix)) { store.apply(mix) })
        }
        if !store.userMixes.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Мои миксы"))
            for mix in store.userMixes {
                menu.addItem(ActionMenuItem("\(mix.emoji)  \(mix.name)", checked: store.isPlaying && store.isCurrent(mix)) { store.apply(mix) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Сохранить текущий микс…", enabled: !store.active.isEmpty) { promptSave(store) })
        if !store.userMixes.isEmpty {
            let delete = NSMenuItem(title: "Удалить микс", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for mix in store.userMixes {
                sub.addItem(ActionMenuItem("\(mix.emoji)  \(mix.name)") { store.delete(mix) })
            }
            delete.submenu = sub
            menu.addItem(delete)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("🎲  Случайный микс") { store.randomMix() })
        return menu
    }

    static func timer(_ store: MixStore) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Выключить звук через"))
        for minutes in MixStore.timerOptions {
            let title = minutes < 60 ? "\(minutes) минут" : minutes == 60 ? "1 час" : minutes == 90 ? "1,5 часа" : "2 часа"
            menu.addItem(ActionMenuItem(title) { store.startTimer(minutes: minutes) })
        }
        if store.timerRemaining != nil {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Отменить таймер") { store.cancelTimer() })
        }
        return menu
    }

    static func settings(_ store: MixStore) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let theme = NSMenuItem(title: "Тема", action: nil, keyEquivalent: "")
        theme.submenu = NSMenu()
        for option in PanelTheme.allCases {
            theme.submenu?.addItem(ActionMenuItem(option.title, checked: store.theme == option) { store.theme = option })
        }
        menu.addItem(theme)

        let backdrop = NSMenuItem(title: "Подложка", action: nil, keyEquivalent: "")
        backdrop.submenu = NSMenu()
        for option in PanelBackdrop.allCases {
            backdrop.submenu?.addItem(ActionMenuItem(option.title, checked: store.backdrop == option) { store.backdrop = option })
        }
        menu.addItem(backdrop)

        let accent = NSMenuItem(title: "Акцент", action: nil, keyEquivalent: "")
        accent.submenu = NSMenu()
        for option in AccentChoice.allCases {
            let item = ActionMenuItem(option.title, checked: store.accent == option) { store.accent = option }
            item.image = swatch(option.colors.0, option.colors.1)
            accent.submenu?.addItem(item)
        }
        menu.addItem(accent)

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Открывать при входе в систему", checked: store.launchAtLogin) {
            store.setLaunchAtLogin(!store.launchAtLogin)
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("О Murmur") { (NSApp.delegate as? AppDelegate)?.showAbout() })
        menu.addItem(ActionMenuItem("Выйти из Murmur") { NSApp.terminate(nil) })
        return menu
    }

    /// Small round color swatch for the Accent menu.
    private static func swatch(_ a: NSColor, _ b: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSGradient(starting: a, ending: b)?.draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)), angle: -90)
            return true
        }
    }

    private static func promptSave(_ store: MixStore) {
        let alert = NSAlert()
        alert.messageText = "Сохранить микс"
        alert.informativeText = "Он появится в меню миксов слева вверху."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = store.suggestedMixName
        alert.accessoryView = field
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.saveCurrentMix(named: field.stringValue)
        }
    }
}

final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

// MARK: About

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Версия \(info?["CFBundleShortVersionString"] as? String ?? "1.0")"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

            Text("Murmur")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .padding(.top, 10)
            Text(version)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Link("github.com/docomoz/Murmur", destination: URL(string: "https://github.com/docomoz/Murmur")!)
                .font(.system(size: 12))
                .focusable(false)
                .padding(.top, 8)

            Text("Звуки природы для фокуса и сна\nпрямо в строке меню. ⌃⌥P — пауза\nиз любого приложения.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)

            Text("Записи — библиотека Moodist, лицензии Pixabay\nи CC0. Белый шум и сердцебиение\nсинтезируются в реальном времени.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Text("© 2026 Maksim Berezkin")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 26)
        .frame(width: 340)
        .focusEffectDisabled()
    }
}
