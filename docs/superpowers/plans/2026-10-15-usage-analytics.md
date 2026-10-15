# Usage Analytics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send anonymous usage statistics (audience, listening time per sound, mixes, Pomodoro, intents, settings) from both builds of Murmur to TelemetryDeck.

**Architecture:** One wrapper (`Analytics.swift`) owns the TelemetryDeck SDK and is the only file that imports it; it is a no-op without an App ID or in test modes, and can route signals to a capture closure for `--selftest`. Listening time is a pure value type (`ListeningSession`) that `MixStore` advances on every playback change and saves once a minute while playing. Every other event is one `Analytics.send` call at an existing `MixStore`/intent entry point.

**Tech Stack:** Swift 5 mode, SwiftPM (hand-assembled bundle via `build.sh`), TelemetryDeck SwiftSDK 2.14.2.

**Spec:** `docs/superpowers/specs/2026-10-15-usage-analytics-design.md`

## Global Constraints

- SDK: `.package(url: "https://github.com/TelemetryDeck/SwiftSDK", exact: "2.14.2")`, product `TelemetryDeck`; only `Analytics.swift` may `import TelemetryDeck`.
- App ID `4D9D3AF4-84E7-48A8-8769-82DFADDECCB4`, stored in `Resources/telemetrydeck-app-id.txt` (committed), overridable by `TELEMETRYDECK_APP_ID`, written by `build.sh` to Info.plist key `TelemetryDeckAppID`. Don't pass `namespace`.
- `config.sendNewSessionBeganSignal = false`; never set `defaultUser`.
- No events when `MixStore.sandboxed` (`--selftest`, `--snapshot`, `--playtest`) — except to the selftest capture closure.
- Never send: mix names, anything about other apps, file paths. Sound/preset values are internal ids (`rain`, `b.focus`).
- Parameter values are strings; durations are `floatValue` in minutes rounded to one decimal.
- Sessions (and per-sound shares) under 30 s are not sent.
- Nothing new runs while idle: the minute save timer exists only while a listening session is open; never send from the audio thread.
- Repo rules: code comments and docs in English; user-visible strings via `L("…", "…")`; commit after each task.

## Review Focus

- Quit while playing → the session is saved with `endedBy: quit` and sent on the next launch, not lost (Task 3 test "quit is sent on next launch").
- Mac sleeps while playing, wakes and keeps playing → two sessions (`sleep`, then a new one), not one long session including the sleep (Task 3 test "sleep splits the session").
- A Pomodoro break silences the mix → `Listening.ended` with `endedBy: pomodoroBreak`, and the mix coming back starts a new session (Task 3 test).
- A user mix named "SECRET" applied, saved, deleted, used by the Focus filter → the string never appears in any captured signal (Task 4 test).
- Restarting Pomodoro with another length → `Pomodoro.stopped` then `Pomodoro.started`, and Pomodoro's own auto-apply of the Focus mix does not emit `Mix.applied` (Task 4 tests).

---

### Task 1: SDK, App ID and build plumbing

**Files:**
- Modify: `Package.swift`, `Package.resolved`
- Create: `Resources/telemetrydeck-app-id.txt`
- Modify: `build.sh` (Info.plist block near line 106; bundle assembly near line 66; the Sparkle-key hint near line 121)
- Modify: `AppStore/Murmur.entitlements`, `AppStore/PrivacyInfo.xcprivacy`

**Interfaces:**
- Produces: Info.plist key `TelemetryDeckAppID` (string) in both builds; the module `TelemetryDeck` linkable from the `Murmur` target; SwiftPM's resource bundle for the SDK inside `Contents/Resources`.

- [ ] **Step 1:** Add the package dependency and the `TelemetryDeck` product to the `Murmur` target; `swift package resolve`; commit `Package.resolved`.
- [ ] **Step 2:** Create `Resources/telemetrydeck-app-id.txt` with the App ID (one line, no trailing spaces).
- [ ] **Step 3:** In `build.sh`, read `TELEMETRYDECK_APP_ID` or the file (same pattern as `SPARKLE_PUBLIC_KEY`), write `<key>TelemetryDeckAppID</key>` into Info.plist for both builds; with no ID print `  (analytics is off: no Resources/telemetrydeck-app-id.txt or TELEMETRYDECK_APP_ID)`.
- [ ] **Step 4:** In `build.sh`, copy every `*.bundle` from the arm64 `swift build --show-bin-path` directory whose name starts with `TelemetryDeck_` into `$APP/Contents/Resources/` (before signing).
- [ ] **Step 5:** `AppStore/Murmur.entitlements`: add `com.apple.security.network.client` = true. `AppStore/PrivacyInfo.xcprivacy`: replace the "collects no data" comment and the empty `NSPrivacyCollectedDataTypes` with two entries matching TelemetryDeck's own manifest — `NSPrivacyCollectedDataTypeProductInteraction` and `NSPrivacyCollectedDataTypeDeviceID`, each `Linked = false`, `Tracking = false`, purposes `[NSPrivacyCollectedDataTypePurposeAnalytics]`.
- [ ] **Step 6: Verify**

Run: `./build.sh && /usr/libexec/PlistBuddy -c "Print :TelemetryDeckAppID" build/Murmur.app/Contents/Info.plist && ls build/Murmur.app/Contents/Resources | grep TelemetryDeck_ && build/Murmur.app/Contents/MacOS/Murmur --selftest >/dev/null; echo $?`
Expected: the App ID, the bundle name, `0`.
Run: `./build-appstore.sh && codesign -d --entitlements - build/appstore/Murmur.app 2>/dev/null | grep network.client`
Expected: the entitlement is listed; the script's own Sparkle checks still pass. Then `./build.sh` again to restore the DMG build.

- [ ] **Step 7: Commit** — `git commit -m "Analytics: TelemetryDeck SDK, App ID and App Store network entitlement"`

### Task 2: `Analytics` wrapper

**Files:**
- Create: `Sources/Murmur/Analytics.swift`
- Modify: `Sources/Murmur/MurmurApp.swift` (`applicationDidFinishLaunching`; `SelfTest.run`)

**Interfaces:**
- Produces:
  - `struct AnalyticsSignal: Equatable { let name: String; let parameters: [String: String]; let minutes: Double? }`
  - `enum AnalyticsSource: String { case panel, intent, focusFilter }`
  - `@MainActor enum Analytics`:
    - `static func start(appID: String?)` — no-op if `appID` is nil/empty or `MixStore.sandboxed`; otherwise initializes the SDK (`sendNewSessionBeganSignal = false`; when the env var `MURMUR_ANALYTICS_LOG=1` is set, a `LogHandler(logLevel: .debug)` printing `[TelemetryDeck] <level>: <message>` to stdout).
    - `static var isLive: Bool { get }`
    - `static var capture: ((AnalyticsSignal) -> Void)?` — test hook, receives every signal even when not live.
    - `static func send(_ name: String, _ parameters: [String: String] = [:], minutes: Double? = nil)` — rounds `minutes` to one decimal, calls `capture`, and forwards to `TelemetryDeck.signal(_:parameters:floatValue:)` only when live.
    - `static var appIDFromBundle: String? { get }` — `Bundle.main.object(forInfoDictionaryKey: "TelemetryDeckAppID")`.

- [ ] **Step 1: Write the failing check** `SelfTest.checkAnalyticsWrapper() -> Bool` (called from `run()`, failure sets `failed = true`, prints `analytics wrapper: ok` / `FAIL …`):
  - with `MixStore.sandboxed = true`, `Analytics.start(appID: "X")` leaves `isLive == false`;
  - with `capture` set, `Analytics.send("Test.event", ["a": "b"], minutes: 1.26)` delivers exactly one `AnalyticsSignal(name: "Test.event", parameters: ["a": "b"], minutes: 1.3)`.
- [ ] **Step 2:** `./build.sh` — Expected: compile error (no `Analytics`).
- [ ] **Step 3:** Implement `Analytics.swift`; in `applicationDidFinishLaunching`, after the `SelfTest.isRendering`/`--playtest` guard, call `Analytics.start(appID: Analytics.appIDFromBundle)`.
- [ ] **Step 4:** `./build.sh && build/Murmur.app/Contents/MacOS/Murmur --selftest | grep "analytics wrapper"` — Expected: `analytics wrapper: ok`, exit 0.
- [ ] **Step 5: Commit** — `git commit -m "Analytics: wrapper around TelemetryDeck with a selftest capture hook"`

### Task 3: Listening sessions

**Files:**
- Create: `Sources/Murmur/Listening.swift`
- Modify: `Sources/Murmur/MixStore.swift` (`sync(fade:)`, `toggle`, `stopAll`, `setPlayingForPomodoro`, `init` observers), `Sources/Murmur/MurmurApp.swift` (`applicationDidFinishLaunching`, new `applicationWillTerminate`, `SelfTest`)

**Interfaces:**
- Consumes: `Analytics.send`, `AnalyticsSignal` (Task 2).
- Produces:
  - `struct ListeningSession: Codable, Equatable` with `init(start: Date, playing: Set<String>)`, `var start: Date`, `var lastUpdate: Date`, `var seconds: [String: Double]`, `var endedBy: String?`;
    `mutating func advance(to now: Date, playing: Set<String>)` — adds `now − lastUpdate` to every sound in the *previous* playing set, then stores the new set and `lastUpdate = now`;
    `func signals(endedBy: String) -> [AnalyticsSignal]` — `[]` if `lastUpdate − start < 30`; otherwise `Listening.ended` (`endedBy`, `soundCount`, `sounds` = ids with ≥ 30 s sorted and joined by `,`; minutes = total) followed by one `Sound.listened` (`sound`: id; minutes = that sound's seconds / 60) per sound with ≥ 30 s, in sorted id order.
  - `MixStore.clock: () -> Date` (default `Date.init`), used by listening and Pomodoro code.
  - `MixStore.saveListeningForQuit()`, `MixStore.sendRecoveredListening()`, internal `MixStore.endListening(_ reason: String)`.
  - `MixStore.listeningDefaults: UserDefaults?` — `.standard` normally, `nil` when `sandboxed` (nothing saved); the check sets it to `UserDefaults(suiteName: "app.murmur.selftest")` and removes that suite afterwards. Key `listeningSession` (JSON of `ListeningSession`).

Rules the code must follow: a session is open while `isPlaying && !active.isEmpty`; the playing set is `active` filtered to `volume(sound) > 0`; `updateListening()` runs at the end of `sync(fade:)`. End reasons: `stop` (from `stopAll` and when `toggle` removes the last sound), `pomodoroBreak` (while `pomodoroDriving`), `pause` (everything else), `sleep` (`NSWorkspace.willSleepNotification`; `didWakeNotification` reopens a session if still playing), `quit` (saved by `applicationWillTerminate`, sent next launch), `recovered` (a saved session with no `endedBy`). While a session is open, a 60 s `Timer` in `.common` mode saves it; the timer is invalidated when the session ends.

- [ ] **Step 1: Write the failing check** `SelfTest.checkListening() -> Bool` (prints `listening: ok`), using a fixed start date `t0` and pure `ListeningSession` values plus a sandboxed `MixStore` with `cuesEnabled = false`, a controllable `clock`, and `Analytics.capture` collecting signals:
  - pure: rain+cafe for 120 s, cafe removed, rain 60 s more → `signals(endedBy: "pause")` = `Listening.ended` minutes 3.0, `sounds: "cafe,rain"`, `soundCount: "2"`; `Sound.listened` cafe 2.0, rain 3.0;
  - pure: 20 s total → `[]`; a sound with 10 s inside a 5 min session is absent from `sounds` and has no `Sound.listened`;
  - store: apply a 2-sound mix, clock +90 s, `pause()` → one `Listening.ended` with `endedBy: "pause"`, minutes 1.5;
  - store: `stopAll()` after 60 s → `endedBy: "stop"`;
  - store "sleep splits the session": play, +60 s, post `NSWorkspace.willSleepNotification` on `NSWorkspace.shared.notificationCenter`, +60 s, post `didWakeNotification`, +60 s, pause → two `Listening.ended`: `sleep` (1.0) then `pause` (1.0);
  - store "pomodoroBreak": `startPomodoro(minutes: 1)`, +61 s, tick, → `endedBy: "pomodoroBreak"`; after the break's `skipPomodoroPhase()`, +60 s, `pause()` → a new session of 1.0;
  - "quit is sent on next launch": with `listeningDefaults` set to the selftest suite, play 2 min, `saveListeningForQuit()`, then on a fresh sandboxed store using the same suite `sendRecoveredListening()` emits `Listening.ended {endedBy: quit}` minutes 2.0 and the key is gone; a session saved by the minute timer path (no `endedBy`) is sent as `recovered`.
- [ ] **Step 2:** `./build.sh` — Expected: compile error.
- [ ] **Step 3:** Implement `Listening.swift`, the `MixStore` hooks and `clock` (replace `Date()` in the Pomodoro section with `clock()`; make `tickPomodoro()` internal for the check). Saving and recovery go only through `listeningDefaults`.
- [ ] **Step 4:** In `applicationDidFinishLaunching` call `store.sendRecoveredListening()` right after `Analytics.start`; add `applicationWillTerminate` calling `store.saveListeningForQuit()`.
- [ ] **Step 5:** `./build.sh && build/Murmur.app/Contents/MacOS/Murmur --selftest | grep -E "listening|FAIL"` — Expected: `listening: ok`, no FAIL, exit 0; `checkPomodoro` still OK.
- [ ] **Step 6: Commit** — `git commit -m "Analytics: listening sessions with per-sound minutes"`

### Task 4: Feature events

**Files:**
- Modify: `Sources/Murmur/MixStore.swift`, `Sources/Murmur/Intents.swift`, `Sources/Murmur/Views.swift` (call sites only if a signature changes), `Sources/Murmur/MurmurApp.swift` (launch + `SelfTest`)

**Interfaces:**
- Consumes: `Analytics.send`, `AnalyticsSource` (Task 2), `MixStore.clock` (Task 3).
- Produces (signatures later code and the intents use):
  - `func apply(_ mix: Mix, source: AnalyticsSource = .panel)` — sends `Mix.applied` (`kind`: `preset` if `mix.builtIn` else `user`; `preset`: `mix.id` only for presets; `source`), then does what `apply` did before. Pomodoro's own Focus-mix load and `randomMix` must not go through the event (move the old body to a private `load(_:)`).
  - `func randomMix(source: AnalyticsSource = .panel)` — `Mix.applied` with `kind: shuffle`, `source`.
  - `func startPomodoro(minutes: Int? = nil, source: AnalyticsSource = .panel)` — if a run is active, first `Pomodoro.stopped`; then `Pomodoro.started` (`focusMinutes`, `source`).
  - `var launchParameters: [String: String] { get }` — `build` (`appstore` under `#if APPSTORE`, else `dmg`), `livingMix`/`duckDuringCalls`/`launchAtLogin` (`on`/`off`), `theme`/`backdrop`/`accent` (raw values), `userMixes` (count).

Event rules (names and parameters exactly as in the spec's table): `Mix.saved` (`soundCount`), `Mix.deleted` (no parameters); `Pomodoro.focusCompleted` (`focusMinutes`, `round`) when a focus phase ends by time, not by skip; `Pomodoro.skipped` (`phase`: `focus`/`break`) from `skipPomodoroPhase()` and from Play during a break; `Pomodoro.stopped` (`phase`, `completedFocus`; minutes since the run started) from `stopPomodoro`, `stopAll` with a running timer, and a restart; `Intent.performed` (`intent`: the struct name) at the top of every `AppIntent.perform()` except the Focus filter; `FocusFilter.changed` (`state`: `on`/`off`; `paused`: `yes`/`no` only for `off`); `App.launched` with `launchParameters`, sent in `applicationDidFinishLaunching` after `sendRecoveredListening()`. Intents and the Focus filter pass `source: .intent` / `.focusFilter`.

- [ ] **Step 1: Write the failing check** `SelfTest.checkEvents() -> Bool` (prints `events: ok`) on a sandboxed store with capture:
  - `apply(Mix.presets[0])` → `Mix.applied` `{kind: preset, preset: "b.cafe", source: panel}`; `randomMix(source: .intent)` → `{kind: shuffle, source: intent}`;
  - with `active` empty, `startPomodoro(minutes: 25)` → exactly one `Pomodoro.started {focusMinutes: "25", source: panel}` and **no** `Mix.applied`;
  - `startPomodoro(minutes: 30)` while running → `Pomodoro.stopped` then `Pomodoro.started {focusMinutes: "30"}`;
  - `skipPomodoroPhase()` in focus → `Pomodoro.skipped {phase: focus}` and no `Pomodoro.focusCompleted`; clock past the end of a 1-minute focus + tick → `Pomodoro.focusCompleted {focusMinutes: "1", round: "1"}`;
  - `stopPomodoro()` → `Pomodoro.stopped` with `completedFocus` matching the run;
  - save a mix named `"SECRET"` → `Mix.saved {soundCount: "<n>"}`; apply it → `kind: user` without `preset`; delete it → `Mix.deleted`; then assert no captured signal's name or parameter value contains `"SECRET"`;
  - `launchParameters` contains exactly the eight keys and `build == "dmg"` in this build.
- [ ] **Step 2:** `./build.sh` — Expected: compile error.
- [ ] **Step 3:** Implement the events in `MixStore`; thread `source` through `Intents.swift` (`PlayMixIntent`, `ShuffleIntent`, `StartPomodoroIntent`, Focus filter); add `Intent.performed` and `FocusFilter.changed`; send `App.launched`.
- [ ] **Step 4:** `./build.sh && build/Murmur.app/Contents/MacOS/Murmur --selftest | grep -E "events|FAIL"` — Expected: `events: ok`, no FAIL, exit 0.
- [ ] **Step 5: Commit** — `git commit -m "Analytics: mix, Pomodoro, intent, Focus filter and launch events"`

### Task 5: Honest texts and docs

**Files:**
- Modify: `AppStore/PRIVACY.md`, `AppStore/metadata.md`, `AppStore/README.md`, `README.md`, `HANDOFF.md`

- [ ] **Step 1:** `AppStore/PRIVACY.md` (English and Russian, "Last updated: October 15, 2026" / «15 октября 2026 г.»): Murmur sends anonymous usage statistics through TelemetryDeck (telemetrydeck.com) — which features and sounds are used and for how long, app and macOS version, system language; an anonymous app-generated identifier, hashed before it leaves the Mac and again on the server; no mix names, no account, no IP stored, not linked to you, no ads or tracking. Keep: settings stay on the Mac. The DMG version also checks for updates (Sparkle, appcast on GitHub).
- [ ] **Step 2:** `AppStore/metadata.md`: the App Privacy row → "Usage Data → Product Interaction; Identifiers → Device ID — both not linked to you, not used for tracking, purpose Analytics"; both descriptions' HONEST / ЧЕСТНО paragraphs → no accounts, ads or subscriptions; only anonymous usage statistics to improve the app (EN) / без аккаунтов, рекламы и подписок; только анонимная статистика использования, чтобы делать приложение лучше (RU); review notes: replace "No account, no network access and no data collection" with "No account. The app sends anonymous usage statistics (TelemetryDeck); nothing else goes over the network." Keep every text within its Apple limit (description 4000).
- [ ] **Step 3:** `AppStore/README.md` step 7.7 → the App Privacy answers from Step 2. `README.md`: one line under Features about anonymous usage statistics. `HANDOFF.md`: the dependency line (Sparkle + TelemetryDeck), a new §4 subsection "Analytics" (wrapper, App ID file, the event table by reference to the spec, listening-session rules, `MURMUR_ANALYTICS_LOG=1`, how to see signals in the dashboard), the release checklist: release notes of the version that ships analytics say so in English and Russian.
- [ ] **Step 4: Verify** — `grep -rn "Data Not Collected\|no data collection\|never connects to the internet\|не подключается к интернету\|сбора данных" AppStore README.md HANDOFF.md` — Expected: no stale claims left (only the new honest wording).
- [ ] **Step 5: Commit** — `git commit -m "Analytics: honest privacy policy, store texts and docs"`

### Task 6: End-to-end check on the author's Mac

- [ ] **Step 1:** `./build.sh`, then run `MURMUR_ANALYTICS_LOG=1 build/Murmur.app/Contents/MacOS/Murmur` from Terminal, play a mix for over 30 s, pause, start and stop Pomodoro, quit (⌘Q from the ⚙ menu).
- [ ] **Step 2:** Expected in stdout: TelemetryDeck debug lines for `App.launched`, `Mix.applied`, `Listening.ended`, `Sound.listened`, `Pomodoro.started`, `Pomodoro.stopped`, and a successful upload (no HTTP error). Relaunch → the `quit` session is sent.
- [ ] **Step 3:** Ask the author to open TelemetryDeck → Explore → Recent Signals and confirm the signals arrived (the assistant can't see the dashboard). Installing the build into `/Applications` replaces his app — only with his go-ahead.
- [ ] **Step 4:** Record the result in `HANDOFF.md` §7 and commit.
