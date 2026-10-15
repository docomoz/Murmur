# Usage analytics — design

Date: 2026-10-15. Status: approved by the author (2026-10-15).

## Why

Murmur is about to get its first outside users (a handful at the start). The author wants to know how many
people actually use it and how: whether they use the Pomodoro timer, how long they listen, whether they save
their own mixes, and which sounds are popular — to decide which sounds to add or drop and where to take the app.
Right now the author is the only active user and wants to see the analytics working on his own Mac first.

## Goals

- Daily and monthly active users, app version, macOS version, system language, DMG vs App Store build.
- Listening time: how long a listening session lasts and how many minutes each sound is listened to.
- Which presets, saved mixes and Shuffle get used; whether people save and delete their own mixes.
- Pomodoro: how often it starts, with which focus length, from where, how often focus is completed vs abandoned.
- Shortcuts/Siri/Focus filter usage.
- Which settings people change (Living Mix, Quiet During Calls, theme, backdrop, accent, launch at login).
- Works for the author's own Mac from day one (his usage counts like anyone else's).

## Non-goals

- No opt-out switch and no consent prompt: the author decided statistics are sent for everyone.
- No crash reporting, no performance metrics, no A/B tests, no remote config.
- No per-user profiles or user-level drill-down beyond what the service does anonymously.

## Anti-goals (a failure even if it works)

- Sending anything personal: mix names (user-typed text), anything about other apps (who is in a call, process
  names, bundle IDs of other apps), file paths, the user's name, an IP stored by the service.
- Analytics making the app worse: blocking the main thread, waking the Mac, keeping the audio engine or a timer
  running while idle, noticeable CPU or network use (1.11.1 already shipped one idle-CPU regression).
- Burning the free event budget with chatty events (see "Budget").
- Test modes (`--selftest`, `--snapshot`, `--playtest`) polluting the data.

## Service: TelemetryDeck (assistant's call)

[TelemetryDeck](https://telemetrydeck.com) instead of Amplitude: built for Apple apps, anonymizes the user
identifier (SDK hashes it, the server salts and hashes again), doesn't store IPs, has a Swift package with no
dependencies (`TelemetryDeck/SwiftSDK`, latest stable 2.14.2, macOS 10.13+, product `TelemetryDeck`).
TelemetryDeck adds base parameters to every signal itself (app version, build, OS version, device model,
system locale, SDK version), so those aren't sent by hand.

**Budget.** The free plan for accounts created after 1 July 2026 is **50,000 events/month**; using it all two
months in a row auto-upgrades the account to a paid plan (emails at 80 % and 100 %). The event set below is
sized at roughly 20 events per active user per day → ~600/month → the free plan covers ~80 active users. If
Murmur outgrows that, the first knob is dropping `Sound.listened` in favour of the `sounds` parameter on
`Listening.ended`.

**Account.** Created by the author: app "Murmur" (macOS), **App ID `4D9D3AF4-84E7-48A8-8769-82DFADDECCB4`**,
organization namespace `com.docomoz` (not passed to the 2.x SDK: its docs say to leave `namespace` unset).
The App ID isn't a secret — it ships inside every app.

The SDK sends `TelemetryDeck.Session.started` at every launch by itself. `App.launched` carries the same
information plus the settings snapshot, so the SDK's own signal is turned off
(`config.sendNewSessionBeganSignal = false`) to save budget (assistant's call).

## Events

Names follow TelemetryDeck's `Category.action` style. Parameter values are strings; durations go into the
signal's `floatValue` in minutes (one decimal). Sound and preset identifiers are the internal ids (`rain`,
`cafe`, `b.focus`…), never localized names.

| Event | When | Parameters | floatValue |
|---|---|---|---|
| `App.launched` | once per launch, after the store is set up | `build`: `dmg` / `appstore`; `livingMix`, `duckDuringCalls`, `launchAtLogin`: `on`/`off`; `theme`, `backdrop`, `accent`: raw values; `userMixes`: count | — |
| `Listening.ended` | playback goes from playing to not playing, for any reason, if it lasted ≥ 30 s | `endedBy`: `pause` / `stop` / `pomodoroBreak` / `sleep` / `quit` / `recovered` (sent on the next launch after a crash or force quit); `soundCount`; `sounds`: sorted ids joined with `,` | minutes |
| `Sound.listened` | together with `Listening.ended`, one per sound that played ≥ 30 s of that session | `sound`: id | minutes this sound played |
| `Mix.applied` | a preset tile, a saved mix or Shuffle is chosen (panel, all-mixes menu or intent) | `kind`: `preset` / `user` / `shuffle`; `preset`: id (presets only); `source`: `panel` / `intent` / `focusFilter` | — |
| `Mix.saved` | a mix is saved | `soundCount` | — |
| `Mix.deleted` | a saved mix is deleted | — | — |
| `Pomodoro.started` | the timer starts | `focusMinutes`; `source`: `panel` / `intent` | — |
| `Pomodoro.focusCompleted` | a focus phase runs to its end | `focusMinutes`; `round` (1, 2, …) | — |
| `Pomodoro.skipped` | Take a Break Now / Skip Break | `phase`: `focus` / `break` | — |
| `Pomodoro.stopped` | Stop Pomodoro, Stop (■), or a new length restarts it | `phase`; `completedFocus`: count in this run | minutes since start |
| `Intent.performed` | any App Intent's `perform()` (Shortcuts, Spotlight, Siri) | `intent`: type name, e.g. `PlayMixIntent` | — |
| `FocusFilter.changed` | the Focus filter's `perform()` | `state`: `on` / `off`; `paused`: `yes`/`no` (off only) | — |

Settings changes are not separate events: the `App.launched` snapshot shows what people keep or change.

**Listening time details.** A session is one continuous stretch of `isPlaying == true` (Quiet During Calls
ducking doesn't end it; it only lowers the volume). Per-sound minutes count the time a sound was in `active`
with a non-zero volume during the session. To survive a crash or force quit, the open session (start time,
per-sound seconds so far) is saved to UserDefaults at most once a minute while playing and cleared when
`Listening.ended` is sent; at launch a leftover session is sent with `endedBy: recovered` and the duration up
to its last save. Sleep (`NSWorkspace.willSleepNotification`) and quit (`applicationWillTerminate`) end the
session too.

## Behaviour and constraints

- **One small wrapper** (e.g. `Analytics.swift`) owns the SDK; the rest of the code calls
  `Analytics.send(.event, …)`-style methods and never imports TelemetryDeck directly. With no App ID, or in the
  test modes (`MixStore.sandboxed`), every call is a no-op.
- **App ID is configured like the Sparkle key**: `Resources/telemetrydeck-app-id.txt` (committed) or the
  `TELEMETRYDECK_APP_ID` env var; `build.sh` writes it into Info.plist (`TelemetryDeckAppID`); the app reads it
  from there. No ID → analytics off, and `build.sh` prints a hint, as it does for Sparkle.
- Signals are never sent from the audio thread; nothing new runs while the app is idle (no timers when not
  playing; the once-a-minute session save runs only while playing and reuses existing timers if possible).
- The author's Mac is counted normally (no test mode in release builds).
- Both builds get analytics: the DMG build and the App Store build.

## Build and packaging changes

- `Package.swift`: add `TelemetryDeck/SwiftSDK` pinned with `exact: "2.14.2"`; commit `Package.resolved`.
- The SDK ships a resource bundle (its `PrivacyInfo.xcprivacy`). `build.sh` assembles the bundle by hand, so it
  must copy SwiftPM's generated resource bundle into the app (where `Bundle.module` finds it) and sign it; the
  builder verifies the app doesn't crash on `Bundle.module` and that the App Store build keeps the SDK's
  privacy manifest.
- App Store build: add `com.apple.security.network.client` to `AppStore/Murmur.entitlements`; update
  `AppStore/PrivacyInfo.xcprivacy` with the collected data types (Product Interaction, used for Analytics, not
  linked, not tracking; plus whatever identifier type TelemetryDeck's own manifest declares).
- `--selftest`: a check that the wrapper is a no-op in sandboxed mode and that event parameters never contain a
  mix name (e.g. build every event from a store with a user mix named "SECRET" and assert the string doesn't
  appear).

## Texts to update (honest wording)

The app currently promises "no data collection" and "never connects to the internet". Replace with: Murmur
sends anonymous usage statistics (which features and sounds are used, how long) to understand how the app is
used; nothing personal, no mix names, no account, not linked to you, no ads or tracking. Plus the self-update
check for the DMG version.

- `AppStore/PRIVACY.md` (English and Russian), new "Last updated" date, name TelemetryDeck as the processor.
- `AppStore/metadata.md`: the HONEST / ЧЕСТНО section of both descriptions, the App Privacy row
  (Data Not Collected → Usage Data: Product Interaction, not linked to you, not used for tracking), the review
  notes ("No account, no network access and no data collection").
- `AppStore/README.md` step 7.7 (App Privacy answers).
- `README.md` if it mentions privacy; `HANDOFF.md`: a new "Analytics" section (service, App ID, events, how to
  check in the dashboard) and the dependency line ("the only dependency is Sparkle").
- Release notes of the version that ships it (English + Russian) say plainly that anonymous statistics are now
  sent.

## Left to the builder

- Exact hook points in `MixStore`/`Views`/`Intents` and how `source` is threaded through.
- Whether the minute save piggybacks on the Pomodoro tick or the status-icon timer, as long as nothing runs when idle.
- Whether the SDK keeps unsent signals across a quit on macOS (it caches and sends in the background). If it
  can drop the last signals on `applicationWillTerminate`, the `quit` session must not be lost: keep it in the
  saved open session and send it as `recovered` on the next launch instead.
- The user identifier: the SDK's default anonymous identifier is fine; don't set `defaultUser` to anything
  derived from the user.
- How to verify end to end: TelemetryDeck's dashboard shows test/live signals; the author checks from his Mac
  after installing the build.

## Assistant's calls (for the author to check)

- TelemetryDeck as the service; 50k free events/month for new accounts.
- `Sound.listened` with minutes instead of a "sound turned on" event: listening minutes answer "which sounds are
  popular" better, and short tries (< 30 s) aren't counted.
- App ID in a committed text file, like the Sparkle public key.
- Sessions shorter than 30 s aren't sent.
