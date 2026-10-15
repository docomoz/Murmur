# Murmur — handoff

A native macOS menu bar app that mixes background sounds (rain, a campfire, a café, whales, white noise) for work and sleep. Sounds come only from the open Moodist library (Pixabay License / CC0) or are synthesized in code; the project has no third-party sounds, icons or brands, and must never get any.

- State: v1.12, works, installed by the author in `/Applications/Murmur.app`.
- Stack: Swift 5 language mode (Swift 6.4 compiler), SwiftUI + AppKit, AVAudioEngine. Dependencies (SwiftPM): Sparkle 2 (self-update in the DMG version only, §6) and the TelemetryDeck Swift SDK 2.14.2 (anonymous usage statistics, §4 "Analytics").
- Minimum OS: macOS 14 Sonoma. Universal build (arm64 + x86_64).
- The repository is English: docs, code comments, script output, commit messages and release notes. Russian exists only as a product localization (`L()` UI strings, `ru.lproj` for App Intents, the Russian App Store page, Russian release notes next to the English ones).
- UI language: **Russian or English**, by the first system language (`ru*` → Russian, otherwise English). Every visible string is wrapped as `L("по-русски", "In English")`; the helper and `Lang.isRussian` live in `Sound.swift`. To check English: `build/Murmur.app/Contents/MacOS/Murmur --snapshot <prefix> -AppleLanguages "(en)"`. The bundle has `en.lproj`/`ru.lproj` (`Resources/Localization`, needed for the App Intents texts, §4 "App Intents"), `CFBundleLocalizations = [en, ru]`, `CFBundleDevelopmentRegion = en` — so system texts and App Intents pick the language by the same rule as `L()` (a Russian Mac → ru, any other → en). Subtlety: with the languages "Ukrainian, Russian" the bundle picks ru while `L()` picks English (it only looks at the first language).

---

## 1. Quick start

```bash
cd ~/Projects/Murmur
./build.sh                                  # → build/Murmur.app and build/Murmur.dmg (~1 min)
open build/Murmur.app
cp -R build/Murmur.app /Applications/       # install
```

Debug modes (run the binary inside the bundle so `Bundle.main` sees the sounds):

```bash
build/Murmur.app/Contents/MacOS/Murmur --selftest          # Living Mix check + 150 s of every sound: RMS, peak, NaN, "repeat"; Pomodoro cue; Pomodoro logic; App Intents (exit 1 on failure)
build/Murmur.app/Contents/MacOS/Murmur --playtest          # actually play every preset and the Pomodoro cue, measure the output level
build/Murmur.app/Contents/MacOS/Murmur --snapshot preview  # preview-light/dark.png + preview-pomodoro-light.png (focus) and preview-pomodoro-break-dark.png (break), preview-menubar.png (the menu bar icon at real size)
open build/Murmur.app --args --open-panel                   # launch and open the panel right away (like clicking the icon)
```

`--playtest` really plays sound (quietly: master 0.22 in memory; the measurement compensates for the volume). **`--snapshot` and `--playtest` run sandboxed (`MixStore.sandboxed`)**: they read the user's settings but write nothing. The snapshot used to save test mixes into the author's real settings — don't repeat that, and don't run `defaults write app.murmur.mac …` by hand.

---

## 2. Environment and gotchas (important!)

1. **`@State` used to be unavailable.** While the machine had only the Command Line Tools, `@State` didn't work: in the current SDK `@State` is a macro, and the CLT have no `SwiftUIMacros` plugin: `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`. The workaround used throughout the project:
   ```swift
   private let hoverState = State<Bool>(initialValue: false)
   private var hover: Bool { get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue } }
   // binding: hoverState.projectedValue
   ```
   Xcode 27 is installed now (`xcode-select -p` → `/Applications/Xcode.app`), and plain `@State` compiles. Old views don't need rewriting: the workaround works too.
2. **SwiftPM binary path** — the new backend puts it in `.build/out/Products/Release/Murmur` and overwrites it when building for the other architecture. So `build.sh` builds each architecture, copies the result right away via `swift build --show-bin-path`, then runs `lipo`.
3. **Replacing the binary inside a signed .app** → the process gets killed (exit 137). After a manual `cp` of the binary always run `codesign --force --deep -s - build/Murmur.app`.
4. **zsh: don't name a variable `path`** — it's tied to `$PATH` and breaks the shell.
5. The warnings `ld: warning: search path ... not found` and `hdiutil ... deprecated` are harmless.
6. `ImageRenderer` (the `--snapshot` mode) doesn't draw `ScrollView`, `Menu` or **Liquid Glass** (glass elements disappear together with their content). With `SelfTest.isRendering = true` the list is rendered without a ScrollView, and `liquidGlass`/`GlassGroup` swap the glass for a material. Real glass is visible only in the live app.
7. **App Intents build without an Xcode project, but need the full Xcode** (`appintentsmetadataprocessor`, `appintentsnltrainingprocessor`, `xcodebuild -version`). Details in §4 "App Intents". Intent texts must be string literals only (no `L()`), otherwise they don't make it into the metadata.

---

## 3. Layout

```
Package.swift                 SwiftPM, executable target "Murmur", macOS 14
Package.resolved              pinned Sparkle version (2.10.0)
build.sh                      build: 2 archs → lipo → .app + Sparkle.framework → icon → Info.plist → App Intents metadata → signing → styled DMG
build-appstore.sh             App Store version (no Sparkle, sandboxed), §6
appcast.xml                   Sparkle update feed (served from raw.githubusercontent.com), §6
scripts/make_appcast.sh       adds the release in build/Murmur.dmg to appcast.xml, signed with EdDSA
Sources/Murmur/
  MurmurApp.swift             @main (plain AppKit), AppDelegate: NSStatusItem + GlassPanel, fallback window, GlassHost; SelfTest
  Sound.swift                 sound model and the Sound.all catalog, categories, Color(hex:)
  AudioEngine.swift           AVAudioEngine graph, channels with smooth volume, NoiseGenerator (noises/tones), LoopBuilder (the clock loop + shared helpers)
  CallDucking.swift           Quiet During Calls: MicMonitor (who records from the mic, CoreAudio) and DuckEnvelope (the ducking envelope)
  Texture.swift               granular engine: TextureGenerator / GrainLayer, HeartbeatGenerator, SourceLoader, FastRandom
  Drift.swift                 Living Mix: Drift (slow level drift), DriftingGenerator, DriftSwitch
  MixStore.swift              state (ObservableObject): active sounds, volumes, presets, Pomodoro, hotkey, launch at login
  Pomodoro.swift              pure Pomodoro model: PomodoroPlan (focus length, 5/15 breaks), PomodoroPhase, PomodoroState (phase + end + pause), countdownLabel
  Views.swift                 the whole UI (panel, strips, rows, sliders) + native NSMenus (MenuBuilder, ActionMenuItem)
  Updater.swift               self-update (Sparkle, standard UI); an empty stub with -DAPPSTORE
  Intents.swift               App Intents: actions for Shortcuts/Spotlight/Siri, MixEntity, App Shortcuts, Focus filter
  Analytics.swift             anonymous usage statistics: the only file that imports TelemetryDeck (`Analytics.send`)
  Listening.swift             ListeningSession: listening time per sound, for the `Listening.ended`/`Sound.listened` events
Resources/Sounds/*.mp3        19 recordings (≈34 MB), copied to .app/Contents/Resources/Sounds
Resources/Localization/       ru.lproj (Russian for App Intents: Localizable.strings, AppShortcuts.strings) and en.lproj
Resources/icon-1024.png       the icon (generated by scripts/make_icon.swift)
scripts/make_icon.swift       draws the icon in code: `swift scripts/make_icon.swift Resources/icon-1024.png`
scripts/make_dmg_background.swift  DMG window background (just the arrow, no text — the same for every language); build.sh runs it itself
scripts/update_cask.sh        updates version/sha256 in the Homebrew cask (§6)
packaging/homebrew/murmur.rb  Homebrew cask — the source of truth, copied to the tap from here
CREDITS.md                    sources and licenses of the sounds (goes into the bundle)
preview-*.png                 latest UI snapshots
build/                        artifacts (not sources)
```

Bundle ID: `app.murmur.mac`. `LSUIElement = true` (no Dock icon). Settings live in `UserDefaults` of that domain.

---

## 4. Architecture

### Audio (`AudioEngine.swift`)
- Graph: `[channel] → mainMixerNode → PeakLimiter (AVAudioUnitEffect) → outputNode`. The limiter keeps a mix of many sounds from clipping.
- **A channel** = an `AVAudioSourceNode` with a realtime generator (`RealtimeGenerator`: texture, noise, tone, heart; 48 kHz stereo) or — for the clock only — an `AVAudioPlayerNode` with an exact loop. Channels are created lazily on the first `setTarget(gain > 0)` and removed once the volume has reached 0.
- **Smoothness**: each channel ramps `gain → target` at a linear rate; a 60 Hz timer in `RunLoop.main(.common)`. A click/on/off never pops.
- **Idle**: after 2 s without channels the engine stops (CPU, Mac sleep). `recover()` restarts the graph after an output device change / wake (`AVAudioEngineConfigurationChange`, `NSWorkspace.didWakeNotification`).
- **Quiet During Calls** (`CallDucking.swift`, the ⚙ menu, on by default, key `duckDuringCalls`). When another app is in a call — it both records from the mic and plays sound (Zoom, Meet in a browser, Telegram, FaceTime…) — Murmur fades to silence over 1.5 s; once the mic is released it waits 2.5 s (so mute/unmute doesn't make the sound "pump") and comes back over 3 s. It's a separate `duck.gain` multiplier in `MixStore.applyMaster` (`master × duck`) — volumes, the mix and `isPlaying` don't change.
  - `MicMonitor` **never opens the microphone itself** (no permission needed): it reads the HAL process objects (macOS 14+) — `kAudioHardwarePropertyProcessObjectList` and, for each one, `kAudioProcessPropertyIsRunningInput` (the same thing that lights the orange dot) and `…IsRunningOutput`, except for its own PID.
  - **What counts as a call** — `CallDetector.callApps` (a pure function over a list of "bundle ID, records, plays"): an app that records **and** plays. Processes whose bundle IDs nest (`kontur.talk` + `kontur.talk.helper`, `com.google.Chrome` + `com.google.Chrome.helper` — that's how Chrome names the process that plays Meet's audio) count as one app; vendor neighbours (`com.apple.VoiceMemos` and `com.apple.Music`) don't. Safari/WebRTC records and plays in the same `com.apple.WebKit.GPU`. Recording only (Plaud, dictation) doesn't duck; Murmur (its PID and its bundle ID) never counts. `kAudioDevicePropertyDeviceIsRunningSomewhere` can't be the signal: on AirPods/headsets input and output are one device, and Murmur's own sound "runs" it; device flags (all devices with an input) only serve as a reason to recheck the processes. Listeners sit on the input and output of every process (except our own) and on every device with an input; when the process/device lists change, only new objects get listeners (vanished ones lose theirs, the rest are left alone). A burst of notifications from one sound anywhere collapses into a single check after 0.25 s plus a confirming one 1 s after things go quiet.
  - **Gotcha (1.11 → fixed):** listeners only via the C API `AudioObjectAddPropertyListener`/`AudioObjectRemovePropertyListener` (a function + a `clientData` `Relay`). `AudioObjectRemovePropertyListenerBlock` from Swift silently removes nothing and still returns `noErr`: in 1.11 every resubscription added another copy of all listeners, and each copy walked all audio processes over IPC on any sound in the system. Idle Murmur burned up to ~1 s of CPU per foreign sound, more the longer it had been running. `--selftest`, the line "mic listeners: ok (4 calls…)": 20 start/stop cycles, then a silent `afplay`; more than 12 calls or a call after `stop()` — FAIL.
  - `DuckEnvelope` is a pure function of time (a smoothstep gain); `--selftest` runs it ("duck envelope: ok") and the `CallDetector` cases ("call detector: ok"), and the "mic monitor:" line prints who is recording from the mic right now and who Murmur would duck for.
  - Once the ducking reaches 0, the engine is paused (`AudioEngine.isPaused`: `engine.pause()`, `ensureRunning`/`recover()` don't start it); before the sound comes back — `recover()` (the output device often changes during a call: AirPods → headset mode). Idle (stop after 2 s without channels) works as before.
  - Indication: the menu bar bars freeze low, and the panel footer shows a mic icon in the accent color instead of the speaker by the master volume. In the test modes (`sandboxed`) the monitor doesn't start.
  - Risk: an app that records in one process and plays in a process with a non-nested bundle ID won't be recognized as a call; a recorder whose nested helper plays something will duck, conversely.
- **Granular textures instead of loops** (`Texture.swift`) — the main weapon against repeats. Each sound used to be a single recording on repeat (the whales looped every 27.5 s, the keyboard every 9.5 s — the ear heard it). Now:
  - `SourceLoader` decodes a recording (up to 120 s), trims silence at the edges, normalizes the loudness (`LoopBuilder.loudnessGain`: `min(0.13/RMS, 0.8/p99.9, 25) × boost`) + `softClip`. Buffers are cached (`NSCache`, key `src:<file>:<boost>`).
  - A sound has `layers: [Layer]` (`Sound.swift`). Each `GrainLayer` keeps launching "grains": a random fragment of the recording with a random length (`length`), speed/pitch (`rate`, linear interpolation), gain (`gainJitterDB`), pan (`pan`), random L/R mirroring (`swapChannels`). Neighbouring grains are joined with an equal-power crossfade (`fade`); recent positions don't repeat. `gap > 0` makes the layer sparse (rare events with pauses).
  - Multi-layer sounds: **whales** = the main song (rate 0.93–1.06) + a "distant pod" (rate 0.78–0.9, −7 dB, 2–10 s pauses) + an `underwater.mp3` bed (−9 dB); **thunderstorm** + distant rumbles; **birds** + rare birds to the sides; **chimes** + a second layer.
  - Everything is computed on the audio thread without allocations (`UnsafeMutablePointer`, `FastRandom`).
  - `--selftest` measures "repeat": the sound's correlation with itself at the old loop length (a loop = 1.00). Currently 0.00–0.16 for every texture.
- **Living Mix** (`Drift.swift`, ⚙ → Living Mix, on by default, UserDefaults `livingMix`) — the same "not a loop" idea, at the mix level: each sound's volume slowly wanders around its slider (rain swells and eases, the café fills up and empties). It's a multiplier on top of the channel volume: nothing is written to `volumes`, the sliders don't move, saved mixes don't change.
  - The offset in dB = a sum of three sines with random incommensurable periods (150–300 s, 80–150 s, 60–90 s; weights 1 / 0.6 / 0.3) and random phases, normalized by the sum of weights → it never leaves ±`Sound.drift` dB, averages exactly 0 (on average the mix is what the user set) and never repeats. Speed ≤ ~0.15 dB/s — the change is audible only over minutes.
  - Depth is `Sound.drift` (±dB, 2 by default): wind 3; rain, thunderstorm, birds, street, café, keyboard 2.5; stream, train, library 1.5; cat, vinyl, bowl 1; white noise 0.75; **clock and heartbeat 0** (exact rhythm/pulse). The clock is an `AVAudioPlayerNode`, the wrapper doesn't touch it anyway.
  - Applied on the audio thread: `AudioEngine.makeNode(_:for:)` wraps the generator in a `DriftingGenerator`, which after `render` multiplies the buffer by a gain linearly interpolated from the previous buffer to the current one (`last + step·i`, not a running sum — otherwise Float loses the ~1e-7 steps and a step appears at the buffer boundary). No allocations, no timers: the 60 Hz ramp timer still stops, and the engine still sleeps 2 s after the last channel.
  - On/off is a shared `DriftSwitch` (read by the audio thread); the depth glides to 0 (or from 0) over `Drift.toggleTime` = 6 s, after which the multiplier is exactly 1.0.
  - The first line of `--selftest` checks the drift: 30 simulated minutes per sound — within ±drift, no faster than 0.25 dB/s (≤ 0.75 dB/s while toggling off), a swing of ≥ half the depth, sounds with `drift: 0` and a disabled drift — exactly 1.0; the wrapper over a constant signal has no steps (sample-to-sample step < 1e-5). On failure — `FAIL living mix: …` and exit code 1.
- **HeartbeatGenerator**: a synthesized "lub-dub" with rhythm variability — the tempo wanders between 54 and 64 bpm, each beat ±2.5 % in time and 0.82–1.0 in strength.
- **LoopBuilder** remains only for the **clock** (the rhythm has to be exact): the window `LoopRegion(start: 0.45, length: 15.005)` = exactly 15 ticks, a 0.03 s crossfade.
- **NoiseGenerator**: white noise (`FastRandom`, ×0.15). Pink/brown noise and 432/528 Hz tones used to exist but were removed at the author's request (v1.2).
- **Event mode** (`Layer.events`) for one-shot recordings: the singing bowl is a single strike with a ~35 s decay; the whole recording starts every 12–24 s with its own pitch (rate 0.94–1.06) and pan, new strikes sound over the decaying ones (up to 4 at once).

### State (`MixStore.swift`, `@MainActor`)
- `active: [String]` (order of switching on), `volumes: [id: Double]`, `master`, `isPlaying`, `userMixes`, Pomodoro.
- Slider volume curve: `pow(v, 1.6)`; master → `mainMixerNode.outputVolume`.
- `sync(fade:)` recomputes every channel's target. Dragging the slider of a sound that's off switches it on.
- Presets `Mix.presets` (built-in, can't be deleted) + user mixes (JSON in UserDefaults `userMixes`).
- **Shuffle** (`MixStore.randomMix` / `randomLevels`) works by scenes (`MixStore.scenes`): a scene = anchor sounds + extras that go with them (a rainy café, a campfire at night, a forest by day, the sea, the deep, a thunderstorm, a train, meditation, a library, focus, cozy…). It takes an anchor (volume 0.55–0.8) + 1–2 extras (0.2–0.45); the set that is already playing is never repeated. `--selftest` prints 12 examples. When adding a sound, put it into fitting scenes, otherwise Shuffle will never pick it.
- **There is no sleep timer** (removed in 1.12 by the author's decision: nobody sensible uses it). Pomodoro replaces it.
- **Pomodoro timer** (`Pomodoro.swift` + the `// MARK: Pomodoro` section in `MixStore`):
  - Focus length to choose from — `PomodoroPlan.presets`: 15 / 20 / 25 / 30 / 45 min (any 1–180 from Shortcuts). Breaks are the same for all: 5 min, every 4th (`longEvery`) — 15 min. Phases by index: even — focus, odd — breaks, break no. 4, 8, … — long.
  - `PomodoroState` is a pure value (phase index + end time + `pausedLeft`). `advanced(at:)`: if the tick is late by ≤ 5 s (`catchUp`), the new phase starts exactly at the end of the old one (no drift); if later (the Mac slept) or the phase was skipped early — from "now", at full length. `paused(at:)`/`resumed(at:)` freeze and resume the countdown. The tick is 0.5 s.
  - **Sound.** The start has no cue: the current mix plays (if `active` is empty — the built-in Focus mix, `b.focus`). End of focus — a bowl strike, then the mix fades to pause over 8 s (`pomodoroFadeOut`): **the break is silence**, `active` and the volumes stay untouched. End of the break — a higher-pitched bowl strike and the same mix comes back over 4 s (`pomodoroFadeIn`). There's no separate "break sound" (mix) anymore.
  - **The user's Play/Pause drive Pomodoro** (`isPlaying.didSet` → `playbackChangedByUser()`; Pomodoro's own starts/stops are marked with `pomodoroDriving` and don't count): pausing during focus freezes the countdown (focus without sound isn't focus), Play resumes it; Play during a break ends the break early and starts focus. This covers everything that changes `isPlaying`: the button, ⌃⌥P, switching a sound on in the list, presets, intents.
  - The phase change cue is a single singing-bowl strike (`Chime` in `AudioEngine.swift`: the first 11 s of `bowl.mp3`, a 4 s tail; break — ×0.84, focus — ×1.0), a one-off `AVAudioPlayerNode` over the mix through master, volume 0.22 (`--playtest`: −24 dBFS). While the bowl sounds, the engine doesn't idle-stop (`cues`). No system beeps.
  - Stop Pomodoro only stops the timer; the sound stays as it is (silence during a break). Stop (■) stops Pomodoro too. "Take a Break Now"/"Skip Break" — `skipPomodoroPhase()`. Picking another length while running starts over from focus.
  - Only the last focus length is saved: key `pomodoroPlan` (minutes as a string; the old "50"/"90" values from 1.11 are valid, unknown ones → 25). The 1.11 key `pomodoroBreak` is no longer read. The state itself isn't restored after a relaunch. The test modes write nothing (`sandboxed`).
- Global hotkey **⌃⌥P** (Carbon `RegisterEventHotKey`, doesn't need Accessibility permission).
- Launch at login: `SMAppService.mainApp` (works reliably from `/Applications`).
- Persistence: keys `active`, `volumes`, `master`, `userMixes`, `launchedBefore`, `livingMix`, `pomodoroPlan`, `duckDuringCalls` (plus `theme`/`backdrop`/`accent`; + `focusSession` — what the Focus filter switched on, see "App Intents"; + `listeningSession` — the open listening session, see "Analytics").
- `statusLine` and `suggestedMixName` — `statusLine` is no longer used by the UI after the redesign (can be removed).

### UI (`Views.swift`)
Structure: header → presets → list of sounds with sliders → footer; macOS 26/27 **Liquid Glass** style:
- width 292; we don't set a panel background — the `NSGlassEffectView` from `GlassHost.makePanelContent` is the background. Colors are semantic (`.primary/.secondary`) so vibrancy on glass works;
- `liquidGlass(in:tint:interactive:)` — `glassEffect(Glass.regular.tint(..).interactive())` on macOS 26+, a material on 14–15; `GlassGroup` = `GlassEffectContainer`;
- header: round glass buttons "☰ all mixes" and "⚙"; in the middle **Stop (38 pt) and Play (50 pt) are two separate circles** 10 pt apart, without a shared `GlassEffectContainer` (in 1.1–1.8 they merged into one "drop", the author didn't like it). Play is glass tinted with the accent color, without an opaque fill, to respect the system glass setting;
- `Aurora` is a soft colored glow in the colors of the playing sounds, only with the "Mix Colors" backdrop; icons of active sounds are tinted with `sound.tint.gradient`;
- **the preset strip** under the header (`PresetStrip`): one horizontal strip — **🎲 Shuffle always first**, then the user's saved mixes (new ones right after Shuffle), then the built-in Café / Focus / Campfire / Sea. The strip runs **edge to edge across the panel** (width 292, inner padding 12): the glass tiles are drawn on a separate layer and **aren't clipped by the ScrollView bounds** — in 1.7 Shuffle was pinned on the right, and the scrolling tiles showed through under it. Up to 5 tiles fill the width evenly; with more, tiles narrow to 46 pt and the next one peeks out at the edge. The trackpad scrolls natively; the mouse wheel moves one tile at a time (`WheelCatcher`). Right-click on your own mix → Delete Mix. After saving, the strip scrolls back to the start.
- compact list: 44 pt rows, a 17 pt light icon, a 12.5 pt name, `LineSlider` — a 2.5 pt track, a 3×11 thumb;
- footer: a glass Pomodoro "pill" + the master volume. The pill shows "⏱ Pomodoro" (not running), "⌖ Focus 24:13" / "☕ Break 4:59" while running and "⏸ Focus 18:40" when focus is paused (`.fixedSize()` so the countdown isn't truncated). The pill's menu (`MenuBuilder.pomodoro`): a "Pomodoro Timer" header; while running — "Now: focus, 2 of 4" + "Take a Break Now"/"Skip Break" + Stop Pomodoro and a "Start Over" section; then the lengths "Focus 15…45 min" (a checkmark at the current one) and the hint "5 min breaks, every 4th is 15 min";
- focus rings are disabled (`.focusEffectDisabled()`, `.focusable(false)` on buttons);
- tooltips (`.help`) are removed on purpose — they bothered the author; don't bring them back;
- menus are native `NSMenu`s via `MenuBuilder.popUp`. Saving a mix is an `NSAlert` with a text field.
- in the ⚙ menu above "About Murmur" — "Check for Updates…" and "Check for Updates Automatically" (only when `Updater.shared.isAvailable`: a DMG build with an EdDSA key, §6).

### Menu bar and panel (`MurmurApp.swift`)
- The entry point is `MurmurMain` (plain AppKit, `.accessory`). **The SwiftUI `App` isn't used**: with a `Settings` scene it opened an empty 900×450 window on every launch, and `MenuBarExtra` gives an opaque grey window that can't be made glass.
- The icon is an `NSStatusItem` with the `StatusIcon` image (drawn in code: a circle + 4 bars, template). While sound plays, the bars gently sway (a 12 fps timer, ±20 % amplitude); on pause the timer is stopped. Next to it is the Pomodoro countdown; during Pomodoro a small phase badge is drawn right after the circle (`StatusIcon.image(…, badge:)`: `scope` — focus, `pause` — focus paused, `cup.and.saucer` — break), all one template image, so the menu bar color is respected.
- **Accent** (⚙ menu → Accent, `AccentChoice`): "system" (`NSColor.controlAccentColor`, the default), lavender, lilac, rose, raspberry, coral, tangerine, amber, sand, lime, emerald, graphite. The accent colors only Play, the volume lines, the selected preset and the Pomodoro pill; icons on the glass buttons (☰, ⚙, Stop) and preset labels use the text color (`.primary`), otherwise they blend into the glass with a grey system accent. `Theme.tint1/tint2/gradient/link` are computed and read `Theme.accent`, which `MixStore` sets. The `#49EEC8` turquoise from early versions didn't please the author — don't bring it back.
- Contrast: rows that are off use `Theme.dimText/dimIcon` (dark grey in the light theme, light grey in the dark one), not `.secondary` — it's unreadable on light glass.
- Appearance settings (⚙ menu): **Theme** (system / light / dark → `window.appearance`) and **Backdrop** (`PanelBackdrop`): system (`NSGlassEffectView.style = .regular`, no tint) or mix colors (the first sound's tint via `GlassHost.mixTint` + `Aurora`). **The default is Mix Colors** (since 1.10). `mixTint` is a dynamic color: in the dark theme the mix color is darkened (65 % black, α 0.55), in the light one lightened (55 % white, α 0.3) — otherwise in the dark theme on bright wallpapers the glass turned light and the text got lost. `Aurora` is also quieter in the dark theme (0.16 vs 0.3). The "clear" (`.clear`) and "frosted" modes existed in 1.2 and were removed — they looked bad. Stored in UserDefaults `theme`/`backdrop`, applied by `AppDelegate.applyAppearance()` to every glass window.
- "About Murmur" is its own window (`AboutView`, a regular system window without glass): icon, version, GitHub link, description, licenses, "© 2026 Maksim Berezkin".
- **Rounded corner gotcha (important):** Liquid Glass draws a light rim slightly outside its shape. If the window ends exactly at the edge of the glass, the rim is clipped by the window rectangle → dark lines/"square corners" along the edges (especially in the dark theme and at the bottom). The fix (`GlassHost.makePanelContent`): the panel window is `GlassHost.margin` = 22 pt bigger than the glass on every side, transparent, `hasShadow = false`. No custom shadow — 1.3 had a CALayer shadow, the author saw it as an artifact, removed in 1.4. A click in the transparent margin closes the panel (`GlassPanel.sendEvent`). The content is also clipped to `GlassHost.panelRadius` (22, continuous).
- Regular windows (the fallback mixer window, About) are standard system windows **without** an `NSGlassEffectView`: glass over a whole rectangular window gives the same corner artifacts.
- The panel is a `GlassPanel` (`NSPanel`, borderless + nonactivating, can become key → Space works). The content is `GlassHost.makePanelContent`: SwiftUI in an `NSHostingView` inside an **`NSGlassEffectView`** (macOS 26+; follows the system Liquid Glass setting "clear/tinted"), before 26 — `NSVisualEffectView(.menu)`. It closes on a click outside (global monitor), Esc, losing focus.
- **macOS 27 gotcha:** the system draws the menu bar; the status item window in our process is a stub with the frame `(0, -33, 32, 33)`, `screen == nil`. So: on a click on the icon the panel is positioned at the cursor (`showPanel(fromClick: true)`); if there are no coordinates and it isn't a click, the fallback window opens.
- The fallback window (`showWindow`, `ContentView(inWindow: true)`, a regular window): on the very first launch and when the app is opened again (double click) if the panel has nothing to attach to.

### App Intents: Shortcuts, Spotlight, Siri, Focus filter (`Intents.swift`)
- **Actions** (all `openAppWhenRun = false`, `perform()` on `@MainActor`, they get the `MixStore` from the `AppDelegate` via `MixStore.forIntents()`): Play Mix (parameter — `MixEntity`), Shuffle, Pause / Play (toggle), Play, Pause, Stop, Pomodoro Timer (focus minutes 1–180, 25 by default), Stop Pomodoro, Murmur Volume (0–100). There's no extension (appex): intents run in the app itself; if Murmur isn't running, the system launches it in the background.
- **`MixEntity` / `MixQuery`** (`EntityStringQuery`): the built-in presets + the user's mixes, id = `Mix.id`. The list comes from the live `MixStore`, without it — `Mix.presets + MixStore.savedUserMixes()`. On saving/deleting a mix and on launch, `MurmurShortcuts.updateAppShortcutParameters()` is called so the phrase "Play <mix> in Murmur" knows the new mixes.
- **`MurmurShortcuts`** (`AppShortcutsProvider`): 6 App Shortcuts with English phrases (Russian ones come from `ru.lproj/AppShortcuts.strings`) — visible in Spotlight and Shortcuts with no setup. Every phrase must contain `\(.applicationName)`.
- **Focus filter** `MurmurFocusFilter` (`SetFocusFilterIntent`): Settings → Focus → a mode → Focus Filters → Murmur → a mix + "Pause when the mode turns off". The system calls `perform()` both when the mode turns on (with the chosen values) and when it turns off (with the default values, i.e. `mix == nil`), so the "should we pause" decision is remembered when it turns on (`FocusSession`, UserDefaults `focusSession`). It pauses only if exactly the mix that the mode started is still playing.
- **Language.** Everything that goes into the metadata (titles, descriptions, parameters, `Summary`, phrases, `shortTitle`) is an **English string literal**: build.sh extracts them at compile time, `L()` wouldn't work there. Russian lives in `Resources/Localization/ru.lproj`: `Localizable.strings` (the key is the English literal; in a `Summary` the parameter is written as `${mix}`) and `AppShortcuts.strings` (phrases, `${applicationName}`). `en.lproj` holds only a placeholder so English is in the bundle's list of localizations. **`--selftest` checks that every key from the metadata has a Russian translation** ("FAIL no Russian for …", exit code 1) — when adding/changing an intent text, update ru.lproj. (Until 14.10 it was the other way round: Russian literals, English in en.lproj; the Siri phrase models came out identical after the flip.)

**How the metadata is built (build.sh, no Xcode project).** Xcode does two steps for intents; build.sh repeats them by hand:
1. `swift build … -Xswiftc -emit-const-values -Xswiftc -const-gather-protocols-list -Xswiftc build/intents/protocols.json` — the compiler writes `*.swiftconstvalues` (values of every type conforming to the protocols in the list; the list is taken from an Xcode 27 build — `<Target>_const_extract_protocols.json`). The new SwiftPM backend does this by itself; the flags are for robustness. The file lands in `.build/out/Intermediates.noindex/Murmur.build/Release/Murmur-p.build/Objects-normal/arm64/Murmur-primary.swiftconstvalues`; build.sh finds the newest `*.swiftconstvalues` under `*release*/…/arm64/`.
2. `xcrun appintentsmetadataprocessor --compile-time-extraction --deployment-aware-processing …` → `Contents/Resources/Metadata.appintents/{extract.actionsdata,version.json}`. The metadata doesn't depend on the architecture — arm64 is enough.
3. `xcrun appintentsnltrainingprocessor … --archive-ssu-assets` → `<lang>.lproj/nlu.appintents` and `Metadata.appintents/root.ssu.yaml` (phrase models for Siri/Spotlight; en from the literals, ru from `ru.lproj/AppShortcuts.strings`, which is also the `--source-file` the tool validates).
Then the regular signing — the metadata is inside `Resources`, codesign seals it. The bundle ID doesn't make it into the metadata, so `build-appstore.sh` (changes the ID to `com.docomoz.murmur`, sandbox) doesn't need to rebuild anything; intents and Focus filters need no extra entitlements.

**How the system finds them (verified 12.10 on macOS 27).** The `linkd` daemon indexes `Metadata.appintents` after LaunchServices registration, **but only after the app has been launched at least once** — before the first launch the log says `Bundle … is not trusted for binding, skipping`. After a launch: `Adding …/Metadata.appintents/extract.actionsdata`, `Inserting canonical bundle`, `LNMetadataChangedNotification added`, `Interpolating AppShortcuts`, "donating to Siri"; `duetexpertd`/Shortcuts loads all 10 actions, the filter as a `WFFocusConfigurationLinkAction`. How to check without starting the GUI:
```bash
./build.sh
# A copy with another bundle ID so it isn't confused with the installed Murmur. Not in /tmp: linkd
# doesn't find bundles in temporary folders (LS error -10814).
mkdir -p build/check && cp -R build/Murmur.app build/check/
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.murmur.check" build/check/Murmur.app/Contents/Info.plist
codesign --force -s - build/check/Murmur.app
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSREG -f build/check/Murmur.app
open -n -g build/check/Murmur.app --args --selftest     # a windowless "launch": selftest exits by itself
/usr/bin/log show --last 1m --predicate 'process == "linkd" AND eventMessage CONTAINS "app.murmur.check"' --style compact
$LSREG -u build/check/Murmur.app && rm -rf build/check  # clean up
```
(in zsh `log` is a builtin, hence `/usr/bin/log`). The index itself (`~/Library/Daemon Containers/…/appintents.sqlite3`) and the `com.apple.linkd.registry` XPC are closed to third-party processes — logs only.
- If Shortcuts shows stale actions: there are several copies with the same bundle ID (build/, /Applications) — `lsregister -f /Applications/Murmur.app` and launch it.
- In an ad-hoc build `linkd` logs `Failed to generate bundleIdentity: Unable to get teamId` — an ad-hoc signature has no Team ID; it doesn't prevent indexing. How it affects running the actions is unverified (see §7).

### Analytics (`Analytics.swift`, `Listening.swift`)
- Anonymous usage statistics go to **TelemetryDeck** (dashboard.telemetrydeck.com, app "Murmur", organization namespace `com.docomoz`). Design, the event table and the reasons: `docs/superpowers/specs/2026-10-15-usage-analytics-design.md`. Free plan for accounts created after 1 July 2026: 50,000 events/month (≈80 active users); using it all two months in a row auto-upgrades the account.
- **App ID** `4D9D3AF4-84E7-48A8-8769-82DFADDECCB4` lives in `Resources/telemetrydeck-app-id.txt` (not a secret; `TELEMETRYDECK_APP_ID` overrides it); `build.sh` writes it to Info.plist `TelemetryDeckAppID` in both builds. No ID → analytics off, with the hint "analytics is off".
- `Analytics.swift` is the only file that imports the SDK. `Analytics.start` runs in `applicationDidFinishLaunching`; it's a no-op in the test modes (`MixStore.sandboxed`), and `Analytics.capture` lets `--selftest` see every signal. `sendNewSessionBeganSignal = false`: `App.launched` replaces the SDK's own session signal. `defaultUser` is never set — the SDK's anonymous identifier, hashed twice.
- Events: `App.launched` (build `dmg`/`appstore` + settings snapshot), `Listening.ended` + `Sound.listened` (minutes), `Mix.applied` (`kind` preset/user/shuffle, `source` panel/intent/focusFilter), `Mix.saved`, `Mix.deleted`, `Pomodoro.started/focusCompleted/skipped/stopped`, `Intent.performed`, `FocusFilter.changed`. **Never** a mix name or anything about other apps: `--selftest` saves a mix named "SECRET" and fails if the string shows up in any signal.
- **Listening sessions** (`MixStore` "Listening time"): a session is open while `isPlaying && !active.isEmpty`; `sync(fade:)` advances it on every change, crediting the elapsed time to the sounds that were playing (volume > 0). It ends with `endedBy` `pause`, `stop` (Stop or the last sound switched off), `pomodoroBreak`, `sleep` (`willSleep`; waking up while playing opens a new one). Sessions and per-sound shares under 30 s aren't sent. While open it's saved to UserDefaults `listeningSession` once a minute; at quit it's saved with `endedBy: quit` instead of sent, and the next launch sends it (a save without `endedBy` — a crash — goes as `recovered`). The minute timer exists only while a session is open.
- `apply`/`randomMix`/`startPomodoro` take a `source`; Pomodoro's own loading of the Focus mix goes through `load()` and isn't a `Mix.applied`. `MixStore.clock` replaces `Date()` in Pomodoro and listening code so the checks can move time.
- Debugging: `MURMUR_ANALYTICS_LOG=1 build/Murmur.app/Contents/MacOS/Murmur` prints the SDK's debug log (`[TelemetryDeck] …`) to the terminal. Signals show up in the dashboard under Explore → Recent Signals within a minute or two.
- App Store build: `com.apple.security.network.client`; `AppStore/PrivacyInfo.xcprivacy` declares Product Interaction + Device ID for Analytics, not linked, no tracking (as TelemetryDeck's own manifest does); the SDK's resource bundle `TelemetryDeck_TelemetryDeck.bundle` (its manifest) is copied into `Contents/Resources` by `build.sh`, and its MIT notice as `TelemetryDeck-LICENSE.txt`.
- Gotcha: dependencies emit their own `.swiftconstvalues`, so `build.sh` takes only the Murmur module's (`*/Murmur.build/*`) for the App Intents metadata — the newest file was TelemetryDeck's and the metadata step failed.

---

## 5. Sound catalog

The list order follows the categories in `Sound.all` (new sounds are inserted into their categories). id → source.

| id | Name | Source |
|---|---|---|
| rain | Rain | Moodist rain/light-rain |
| storm | Thunderstorm (+ distant rumbles) | rain/thunder |
| waves | Ocean waves | nature/waves |
| river | Stream | nature/river |
| underwater | Underwater | places/underwater (also the whales' bed) |
| campfire | Campfire (boost 1.8) | nature/campfire |
| wind | Wind | nature/wind |
| birds | Birds (+ rare birds to the sides) | animals/birds |
| crickets | Crickets | animals/crickets |
| whale | Whales (3 layers) | animals/whale + places/underwater |
| city | Street | urban/busy-street |
| cafe | Café | places/cafe |
| train | Train | transport/inside-a-train |
| library | Library | places/library |
| keyboard | Keyboard | things/keyboard |
| clock | Clock (exact loop) | things/clock |
| heartbeat | Heartbeat | synthesized |
| cat | Purring cat (slowed down: rate 0.86–0.92, long grains) | animals/cat-purring |
| vinyl | Vinyl record | things/vinyl-effect |
| bowl | Singing bowl (event mode) | things/singing-bowl |
| white | White noise | synthesized in real time |

In v1.4 the duplicates were removed at the author's request (downpour, rain on a window, rain on a tent, waterfall, wind in leaves, jungle, seagulls, frogs, night village, subway, sailboat, airplane, typewriter, fan, chimes) — "one idea = one sound". The files are deleted from the repository; they can be brought back from Moodist if wanted.

Presets: Rainy Café (rain, café, a bit of street and vinyl), Focus (rain + library + quiet white noise), By the Campfire, Sea, Storm, Night Train, Library (`Mix.presets` in `MixStore.swift`); all of them refer only to existing sounds.

**Licenses.** Recordings come from the open Moodist library (github.com/remvze/moodist), under the Pixabay Content License and CC0; they may be distributed as part of the app. They were downloaded from `https://raw.githubusercontent.com/remvze/moodist/main/public/sounds/<path>.mp3`. Don't use sounds from commercial apps and sites — open licenses only. Moodist's noises (9-second loops) were deliberately replaced with synthesis.

**Adding a sound:** put the mp3 into `Resources/Sounds/<id>.mp3`, add a `Sound(...)` to `Sound.all` with fitting `layers` and `drift` (the Living Mix depth, 0 for rhythmic sounds) (an outline SF Symbol; check it exists: `NSImage(systemSymbolName:)`), rebuild, run `--selftest` (RMS ≈ 0.1–0.13, repeat < 0.2, no NaN). Short recordings need short grains (`length` 1–7 s); speech/voices need a narrow `rate` (±1 %), otherwise "speeding up" is audible. For generators — a new `case` in `SoundSource` and a branch in `AudioEngine.load` / `NoiseGenerator`.

---

## 6. Distribution

### Mac App Store (prepared, waiting for the developer account)
- Step-by-step guide for the author: **`AppStore/README.md`**; store page texts EN/RU with checked limits, keywords, App Review notes and screenshot ideas: `AppStore/metadata.md`; privacy policy: `AppStore/PRIVACY.md` (the URL in App Store Connect points to it on GitHub). The App Store primary language is English, Russian is the second localization.
- `build-appstore.sh` takes the output of `build.sh` and makes the App Store version: bundle ID **`com.docomoz.murmur`** (the DMG stays `app.murmur.mac` so existing installs keep their settings), `ITSAppUsesNonExemptEncryption = false`, `PrivacyInfo.xcprivacy` (UserDefaults only, reason CA92.1), the sandbox `AppStore/Murmur.entitlements` (just `app-sandbox`, nothing else is needed).
  - Without variables — a local sandboxed test build with an ad-hoc signature (`build/appstore/Murmur.app`).
  - With `MAS_APP_IDENTITY` (Apple Distribution), `MAS_INSTALLER_IDENTITY` (3rd Party Mac Developer Installer) and `MAS_PROFILE` (Mac App Store Connect profile) — embeds the profile, adds `com.apple.application-identifier`/`team-identifier` from the profile to the entitlements, signs and builds `build/appstore/Murmur.pkg` for Transporter.
- Verified in the sandbox (12.10): every recording is readable, sound plays (`--selftest`, `--playtest`), settings are written to `~/Library/Containers/com.docomoz.murmur`, the panel opens. The global click monitor, the hotkey and launch at login are allowed in the sandbox but haven't been checked live in the App Store build.
- App Intents in the App Store build: `Metadata.appintents` carries over from `build.sh` as is (the bundle ID isn't recorded in it), no entitlements needed. Verified 12.10: a sandboxed ad-hoc `com.docomoz.murmur` build is indexed by `linkd` after registration and a launch (actions + App Shortcuts). Worth mentioning the Shortcuts actions and the Focus filter in the App Store Connect description.
- `scripts/make_screenshot.swift <panel.png> "Title" "Caption" out.png` — a 2880×1800 App Store frame from a panel snapshot (⌘⇧4 → Space → click).
- The app is free: no banking/tax forms needed. Author: Maksim Berezkin, Apple ID account — Kazakhstan, card — Kyrgyzstan (discussed; a second account isn't needed).
- The UI is bilingual (see "UI language" above), and the App Store pages match it; in the English UI «Наугад» = "Shuffle".

### DMG (GitHub Releases)

- `build.sh` signs ad-hoc (`codesign -s -`). Without an Apple Developer certificate ($99/year) Gatekeeper complains on first launch: System Settings → Privacy & Security → Open Anyway, or `xattr -dr com.apple.quarantine /Applications/Murmur.app`. This is described in `README.md`.
- A release build with Developer ID and notarization: `DEVELOPER_ID="Developer ID Application: Maksim Berezkin (TEAMID)" NOTARY_PROFILE=murmur-notary ./build.sh`. The script signs with the hardened runtime, notarizes and staples first the .app (zip), then the signed DMG. Without variables — the usual ad-hoc build. `NOTARY_PROFILE` without `DEVELOPER_ID` is an error.
- The DMG holds only `Murmur.app` and an `Applications` link with an arrow between them on the background — no text, so it's the same for every language. `build.sh` creates a writable image, puts in `.background/background.tiff` (1x+2x, drawn by `scripts/make_dmg_background.swift`), lays out the window via AppleScript in Finder (Terminal needs access to Finder, the window flashes for a second), then adds `.VolumeIcon.icns` and compresses to UDZO. Window size and icon positions are the `WIN_*`/`APP_X`/`APPS_X`/`ICON_Y` variables in `build.sh`; the background is drawn for them. `WIN_H` is the height without the title bar (Finder's title bar is ≈32 pt on macOS 27, the background has a bleed at the bottom); with 128 pt icons and `WIN_H` < 330 Finder shows a scrollbar. Finder draws the icon labels black in the light theme and white in the dark one, so the bottom of the background is mid-dark.
- `.VolumeIcon.icns` can't be added up front: `hdiutil -srcfolder` skips it, and Finder deletes it while setting up the window.
- One-time setup: a "Developer ID Application" certificate (developer.apple.com → Certificates, CSR from Keychain Access; check: `security find-identity -v -p codesigning`), then `xcrun notarytool store-credentials murmur-notary --apple-id <id> --team-id <TEAMID>` with an app-specific password from appleid.apple.com.
- No entitlements needed (neither for the app nor for Sparkle: its XPC services, which would need them, are removed from the bundle). Before Sparkle `--selftest` passed with an ad-hoc signature + `--options runtime` too; **now ad-hoc + hardened runtime doesn't launch**: library validation won't load Sparkle.framework without a Team ID (`different Team IDs`). With a real Developer ID the app and the framework share one Team ID — that's how Sparkle intends it; so the ad-hoc build is signed without the runtime. To avoid notarizing a broken app, the Developer ID branch of `build.sh` runs `--selftest` after signing and fails if dyld refused.
- The version is set in `build.sh`: `VERSION` (CFBundleShortVersionString) and `BUILD_NUMBER` (CFBundleVersion — Sparkle compares versions by it, bump it every release). Author: Maksim Berezkin (in About, the copyright and LICENSE).

### Self-update of the DMG version (Sparkle 2)

**How it works.**
- Sparkle 2.10.0 comes through SwiftPM (`Package.swift`, exact version; `Package.resolved` is in the repository). The first build downloads it (a ~50 MB clone + a ~10 MB binary zip in `.build`). `build.sh` copies the universal `Sparkle.framework` from `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64` to `Contents/Frameworks` (the rpath `@executable_path/../Frameworks` is set in `Package.swift`), removes `XPCServices` (only sandboxed apps need them) and the headers, adds `Sparkle-LICENSE.txt`.
- Signing follows Sparkle's documentation for builds without Xcode, inside out and **without `--deep`**: `Autoupdate`, `Updater.app`, the framework, then the app (`sign_app` in `build.sh`; for Developer ID — with `--options runtime --timestamp`).
- `Updater.swift`: `SPUStandardUpdaterController` with Sparkle's standard window. It starts in `applicationDidFinishLaunching` (not in `--selftest/--snapshot/--playtest`) and **only if Info.plist has `SUFeedURL` and `SUPublicEDKey`** — otherwise the update menu items aren't shown. `SUEnableAutomaticChecks = true`: a daily check without the "check automatically?" question; it's turned off in the ⚙ menu.
- Murmur is `.accessory` without a Dock icon, so Sparkle's window is easy to lose. Following Sparkle's "gentle reminders" scheme for background apps: while an update is shown, the app temporarily becomes `.regular` (a Dock icon and a ⌘Tab entry, a "1" badge for a background check), and goes back to `.accessory` when the session ends. A manual check closes the panel and calls `NSApp.activate` so the window is in front. Sparkle's window hasn't been checked live (by eye) — see "Verified".
- `build.sh` writes the Info.plist keys: `SUPublicEDKey` — from `SPARKLE_PUBLIC_KEY` or the file `Resources/sparkle-public-key.txt` (a public key isn't a secret, the file is committed); `SUFeedURL` — `SPARKLE_FEED_URL`, by default `https://raw.githubusercontent.com/docomoz/Murmur/main/appcast.xml`. Without a key the build goes on as before, with the hint "self-update is off".
- **The feed** is `appcast.xml` at the repository root, served by raw.githubusercontent.com (~5 min cache; no GitHub Pages needed). The `enclosure` points at the DMG in the release: `https://github.com/docomoz/Murmur/releases/download/vX.Y/Murmur.dmg`. Sparkle mounts the DMG and takes `Murmur.app` itself; it removes the quarantine from the update.
- `scripts/make_appcast.sh notes.md [notes.ru.md]` mounts `build/Murmur.dmg`, reads the version/build/minimum OS and `SUPublicEDKey` **from the app inside the DMG**, signs the DMG with `sign_update` (key from the keychain or `SPARKLE_KEY_FILE`), **verifies the signature with the app's public key** (CryptoKit; catches "signed with the wrong key") and inserts the `<item>` first in `appcast.xml` (a rerun replaces the item with the same `sparkle:version`). Markdown notes are shown in Sparkle's window (`sparkle:format="markdown"`). **Release notes are English with an optional Russian translation**: the second file becomes a `<description xml:lang="ru">` next to `xml:lang="en"`, and Sparkle picks one by the user's preferred languages (`SUAppcast.m`, `bestNodeInNodes`; English for every non-Russian Mac). Overrides: `DMG`, `APPCAST`, `DOWNLOAD_URL`.
- Careful: `sign_update` with an XML file (e.g. `appcast.xml`) doesn't just print the signature, it **embeds it into the file** — sign only the DMG (the script does exactly that).

**Ad-hoc vs Developer ID (worked out from Sparkle's `SUUpdateValidator.m` sources and verified).** For an app update Sparkle requires *at least one* check to pass: the EdDSA signature from the feed or the Apple signatures of the new and old app matching; if EdDSA passed but the Apple signatures differ, the new app just needs a *valid* signature (ad-hoc will do). So:
- ad-hoc → ad-hoc works (via EdDSA), verified end to end (below); ad-hoc → Developer ID passes too (EdDSA), Developer ID → Developer ID — by both checks;
- without an EdDSA key ad-hoc can't update, so self-update is enabled only when `SUPublicEDKey` is present;
- Sparkle would also let "Developer ID → ad-hoc" through (EdDSA), but don't do that; and Sparkle forbids dropping the EdDSA key in a new version.
- Gatekeeper doesn't touch the update: Sparkle removes the quarantine. Ad-hoc installs keep the old Open Anyway ritual on the first install — once.

**One-time setup (author) — done, the key is in the keychain and `Resources/sparkle-public-key.txt`.**
1. `swift package resolve` (or `./build.sh`) — the tools appear in `.build/artifacts/sparkle/Sparkle/bin/`.
2. `.build/artifacts/sparkle/Sparkle/bin/generate_keys` — creates an Ed25519 key **in the login keychain** (account `ed25519`) and prints the public key. Write the public one to `Resources/sparkle-public-key.txt` and commit it.
3. A backup of the private key: `generate_keys -x ~/sparkle-murmur.key` → put it in a password manager/safe place, delete the file. Losing the key = installed copies no longer accept updates (except through a matching Developer ID signature). On another Mac: `generate_keys -f file` imports the key into the keychain. **Never commit** the private key.
4. Works without the keychain too: `SPARKLE_KEY_FILE=path scripts/make_appcast.sh` (`sign_update --ed-key-file`).

**DMG release checklist.**
1. Bump `VERSION` and `BUILD_NUMBER` in `build.sh`.
2. `DEVELOPER_ID=… NOTARY_PROFILE=murmur-notary ./build.sh` (or just `./build.sh` — ad-hoc updates too). The key must land in Info.plist (no "self-update is off" line).
3. Write the release notes: `notes.md` in English and `notes.ru.md` with the same items in Russian. The first release with analytics says plainly that anonymous usage statistics are now sent (and links the privacy policy).
4. `scripts/make_appcast.sh notes.md notes.ru.md` — signs **exactly this** `build/Murmur.dmg`; don't rebuild the DMG after it.
5. `gh release create vX.Y build/Murmur.dmg --notes-file notes.md` (the tag is strictly `v` + `VERSION` — the feed link points to it). GitHub release notes are English.
6. Commit and push `appcast.xml` **after** the DMG is uploaded to the release (otherwise Sparkle downloads a 404).
7. Check: in an installed previous version, ⚙ → "Check for Updates…".

Versions ≤ 1.10 don't contain Sparkle: their users install the new version manually once, automatically after that.

**Testing an update locally** (as verified on 12.10, touching nothing in `/Applications` or the `app.murmur.mac` settings): a throwaway key without the keychain — 32 random bytes in base64 (`Curve25519.Signing.PrivateKey().rawRepresentation` from CryptoKit; `sign_update --ed-key-file` accepts such a file), the public key is `publicKey.rawRepresentation` in base64. Then `SPARKLE_PUBLIC_KEY=… SPARKLE_FEED_URL=http://127.0.0.1:8765/appcast.xml ./build.sh`; two copies in a temporary folder with the bundle ID `app.murmur.mac.updatetest` (the old 1.10 and the new 1.11/12, re-signed with `codesign --force -s -`), the DMG of the new one, `DMG=… APPCAST=… DOWNLOAD_URL=http://127.0.0.1:8765/Murmur.dmg SPARKLE_KEY_FILE=… scripts/make_appcast.sh`, `python3 -m http.server 8765 --bind 127.0.0.1`; `defaults write app.murmur.mac.updatetest SUAutomaticallyUpdate -bool YES` and `launchedBefore -bool YES`, launch the old copy → after ~5 s it downloads the feed and the DMG and starts `Autoupdate`; once the process exits, the copy is 1.11. After the test — `defaults delete app.murmur.mac.updatetest`, delete `~/Library/Caches/app.murmur.mac.updatetest` and `~/Library/HTTPStorages/app.murmur.mac.updatetest`. ATS doesn't block HTTP on 127.0.0.1.

**App Store.** `build-appstore.sh` calls `MURMUR_APPSTORE=1 DEVELOPER_ID= NOTARY_PROFILE= ./build.sh`: Sparkle's code is compiled out (`-Xswiftc -DAPPSTORE`, `Updater` is a stub, no menu items), the framework isn't linked (`-Xlinker -dead_strip_dylibs`) or copied, there are no `SU*` keys; in this mode `build.sh` stops after signing (no notarization and no DMG). `build-appstore.sh` additionally fails if the bundle has Sparkle.framework, a reference to it in `otool -L` or `SUFeedURL`. Consequence: after `build-appstore.sh`, `build/` holds a Murmur.app **without** Sparkle and no DMG — run `./build.sh` again for a DMG release.

### Homebrew (own tap)

Decision: **for now, our own tap `docomoz/homebrew-tap`** (`brew install --cask docomoz/tap/murmur`), the official `homebrew/cask` later. The official one won't accept it for two reasons (checked with `brew audit --cask --new` on 12.10): (1) Gatekeeper — the ad-hoc build fails the signature check, and under Acceptable Casks apps must pass it; Homebrew deprecates and removes such casks; (2) notability (Package Acceptance Policy): ≥30 forks / 30 watchers / 75 stars, and for a self-submission by the repository owner ≥90 / 90 / 225; the repository must be ≥30 days old. Our own tap has none of these requirements.

Files: `packaging/homebrew/murmur.rb` — the cask (source of truth), `scripts/update_cask.sh` — fills in the version and sha256 (by default it takes the digest of the published asset via `gh`, downloads it without `gh`; `--local` — the hash of `build/Murmur.dmg`; `--tap <path>` — copies into the tap checkout and runs `brew style`). The script commits and pushes nothing.

The cask: `depends_on macos: :sonoma` (now means "or newer"; the `">= :sonoma"` form is deprecated), `uninstall quit:` (the menu bar app is usually running), `zap` — `~/Library/Preferences/app.murmur.mac.plist` (the app writes nothing besides UserDefaults) and Saved Application State. Launch at login via `SMAppService.mainApp` isn't in the cask: `uninstall login_item:` only works with old login items, and Homebrew doesn't touch the SMAppService entry: without the app it becomes invalid (not checked by hand). While the build is ad-hoc, the cask has a `caveats` block about Open Anyway / `xattr` (Homebrew sets the quarantine; there's no `--no-quarantine` flag anymore).

Since Homebrew 6, third-party taps need trust: `brew install --cask docomoz/tap/murmur` (the full name) works right away; the short `brew install --cask murmur` only after `brew tap docomoz/tap` and `brew trust --cask docomoz/tap/murmur`. Give the full name in the README.

**Author's checklist**
1. ✓ Done 12.10: the repository https://github.com/docomoz/homebrew-tap, a clone in `~/Projects/homebrew-tap` (`Casks/murmur.rb` + README).
2. ✓ Done 12.10: cask 1.11 published (`auto_updates true` — 1.11 has Sparkle; `zap` also cleans Sparkle's caches). `brew audit --cask --strict --online docomoz/tap/murmur` passes, the install line is in the README.
3. Every release: `./build.sh` → `gh release create vX.Y build/Murmur.dmg` → `scripts/update_cask.sh --tap ~/Projects/homebrew-tap` (takes the version from `build.sh`) → commit `packaging/homebrew/murmur.rb` here and `Casks/murmur.rb` in the tap. Hash exactly the DMG that was uploaded: the DMG isn't reproducible, another `./build.sh` gives another sha256. `brew livecheck --cask docomoz/tap/murmur` shows whether the cask lags behind.
4. After the first notarized build (Developer ID, §6 DMG): remove the `caveats` block from the cask, publish.
5. The official `homebrew/cask` — once releases are notarized and the repository has ≥90 forks / 90 watchers / 225 stars (self-submission) or someone else submits it at ≥30 / 30 / 75. Check locally: `brew tap-new --no-git <user>/test`, put the cask into `Casks/`, `brew audit --cask --new <user>/test/murmur` must pass without errors; then `brew untap`. The PR goes to Homebrew/homebrew-cask (`Casks/m/murmur.rb`, the `murmur` token is free); once accepted, remove the cask from our tap (or keep it, but don't maintain two sources).
6. ✓ Sparkle: `auto_updates true` is set (otherwise `brew upgrade` and Sparkle would fight over the version); a `livecheck` with `strategy :sparkle` on the appcast is possible; `zap` includes `~/Library/Caches/app.murmur.mac` and `~/Library/HTTPStorages/app.murmur.mac`.

---

## 7. Verified / not verified

Verified automatically: building both architectures; all loops (clean seams, matched levels, campfire/crickets/sailboat slightly quieter — the nature of the recordings); every preset and tone actually plays through the engine; layout (light/dark theme snapshots); the author confirmed "everything works".

Self-update (12.10): `./build.sh` and `./build-appstore.sh` build, `codesign --verify --deep --strict` passes, `--selftest` passes in both builds; the App Store build has neither the framework, nor a reference to it, nor Sparkle strings in the binary. End-to-end test with a throwaway key and a feed on localhost (§6): ad-hoc 1.10 downloaded and installed 1.11 by itself, the new bundle's signature is valid, no quarantine, `--selftest` passes; a feed signed with a foreign key — the update was rejected (1.10 stayed), and `make_appcast.sh` with a foreign key fails. Not verified: Developer ID + notarization with Sparkle (no certificate; ad-hoc + runtime can't imitate it, see §6), Sparkle's window on a manual check and the `.accessory/.regular` switch by eye.

Not checked by hand by the assistant (no UI access): native menus (mixes/timer/settings), the ⌃⌥P hotkey, launch at login, behaviour on an audio device change. Pomodoro: phase change logic, silence during a break and the mix coming back, the user's Pause/Play are checked in `--selftest`, the cue really plays in `--playtest`, the pill in snapshots; a live 25-minute cycle with crossfades, the phase badge in the menu bar and the Pomodoro menu haven't been looked at live.

App Intents (12.10): verified that the metadata builds and `linkd` indexes it (regular and sandboxed builds), Shortcuts loads all 10 actions and the Focus filter, App Shortcuts are interpolated; `--selftest` checks the metadata and the Russian translations. **Not verified** (needs a live GUI): actually running the actions from Shortcuts/Spotlight/Siri (including a background launch of a non-running Murmur and an ad-hoc build without a Team ID), the list of mixes in the parameter, the filter firing when a Focus mode turns on/off, Siri recognizing the Russian phrases.

---

## 8. Ideas / TODO

- Don't open the window on launch at login (detect a login item launch) or add a "Show window on launch" setting.
- Remove the dead `statusLine` from `MixStore`.
- Animated icons for active sounds; right now only noises/tones "pulse".
- Liquid Glass has been checked only by the build and an offline snapshot with a substitute — the live look on macOS 26/27 is worth checking by eye.
- Maybe give the user a "variety" control (`rate` width / event frequency).
- Media keys / Now Playing (`MPRemoteCommandCenter`) — deliberately not done, so as not to steal keys from Music.
- A hotkey setting, more sounds from Moodist (it has 80+: airport, night-village, rain-on-tent, singing-bowl, etc.).
- Developer ID + notarization: `build.sh` is ready (§6), waiting for Apple Developer Program approval and the first real notarization (now together with Sparkle.framework).
- Repository: https://github.com/docomoz/Murmur (public). The DMG goes to Releases: `gh release create vX.Y build/Murmur.dmg`.
