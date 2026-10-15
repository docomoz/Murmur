# Murmur — the App Store page

Everything to paste into App Store Connect. Apple's limits are in parentheses; the texts fit them
(checked with a script). The primary language is English; Russian is the second localization.

## General (language-independent)

| Field | Value |
|---|---|
| Bundle ID | `com.docomoz.murmur` |
| SKU | `murmur-mac` |
| Primary category | Productivity |
| Secondary category | Health & Fitness |
| Price | Free, all countries |
| Age rating | 4+ — answer "No" / "None" to every question |
| App Privacy | Data Not Linked to You: **Usage Data → Product Interaction** and **Identifiers → Device ID**, purpose Analytics, not used for tracking (TelemetryDeck; the SDK hashes the identifier) |
| Encryption | Not used (already declared in the build: `ITSAppUsesNonExemptEncryption = NO`) |
| Copyright | `2026 Maksim Berezkin` |
| Support URL | https://github.com/docomoz/Murmur/issues |
| Marketing URL | https://github.com/docomoz/Murmur |
| Privacy Policy URL | https://github.com/docomoz/Murmur/blob/main/AppStore/PRIVACY.md |
| Sign-in required for review | No |

---

## English

**Name** (30): `Murmur: Focus & Sleep Sounds`

**Subtitle** (30): `Rain, fire & ocean in menu bar`

**Promotional text** (170, can be changed without a new review):
```
21 living sounds right in your menu bar: rain, fire, waves, whales, café. A granular engine makes sure they never loop.
```

**Keywords** (100, comma-separated, no spaces):
```
white noise,rain,focus,sleep,ambient,meditation,nature,relax,study,concentration,calm,noise
```

**Description** (4000):
```
Murmur is a quiet background for work, study and sleep. It lives in your menu bar: click the icon, mix a few sounds, get back to what matters.

SOUNDS THAT NEVER LOOP
A short recording on repeat gets old fast — after a couple of minutes your brain starts to recognize the loop. Murmur's granular engine keeps building the sound from living fragments of each recording, with varying length, tempo and stereo position. Rain stays rain, but it never sounds the same twice.

21 SOUNDS
• Water: rain, thunderstorm, ocean waves, stream, underwater
• Nature: campfire, wind, birds, crickets, whales
• City: street, café, train, library
• Home: keyboard, clock, heartbeat, purring cat, vinyl record, singing bowl
• White noise

Whales sing in three layers — the song, a distant pod and the deep ocean. Every strike of the singing bowl sounds like a different bowl. The heartbeat has a living, gently drifting rhythm.

MIXES
• Mix any sounds, each with its own volume
• Ready-made mixes: Café, Focus, Campfire, Sea, Storm, Night Train, Library
• "Shuffle" builds a scene that makes sense: a summer-night campfire, a rainy café, the deep sea with whales
• Save your own mixes — they show up first in the preset strip

FOR SLEEP AND FOCUS
• Pomodoro timer: focus to your mix, breaks in silence
• ⌃⌥P pauses from any app
• Launch at login

BEAUTIFUL AND NATIVE
• Liquid Glass, light and dark themes
• Backdrop tinted with the colors of what's playing
• 12 accent colors
• The menu bar icon gently "breathes" while sound is playing

HONEST
No accounts, ads or subscriptions. Only anonymous usage statistics, to make the app better. All sounds work offline.

Recordings come from the open Moodist library (Pixabay License and CC0).
```

**What's New** (4000): `First release on the App Store.`

---

## Russian

**Name** (30): `Murmur — звуки для фокуса`

**Subtitle** (30): `Дождь, костёр и море в меню`

**Promotional text** (170):
```
21 живой звук прямо в строке меню: дождь, костёр, прибой, киты, кафе. Гранулярный движок — звуки никогда не повторяются по кругу.
```

**Keywords** (100):
```
белый шум,дождь,фокус,сон,медитация,концентрация,природа,релакс,учёба,работа,шум,ambient
```

**Description** (4000):
```
Murmur — тихий фон для работы, учёбы и сна. Он живёт в строке меню: нажали на значок, смешали звуки — и вернулись к делам.

ЗВУКИ, КОТОРЫЕ НЕ ПОВТОРЯЮТСЯ
Короткая запись по кругу быстро надоедает: через пару минут мозг начинает узнавать повтор. В Murmur гранулярный движок непрерывно собирает звук из живых фрагментов записи — с разной длиной, темпом и панорамой. Дождь остаётся дождём, но никогда не звучит одинаково.

21 ЗВУК
• Вода: дождь, гроза, морской прибой, ручей, под водой
• Природа: костёр, ветер, птицы, сверчки, киты
• Город: улица, кафе, поезд, библиотека
• Дом: клавиатура, часы, сердцебиение, мурлыканье кота, виниловая пластинка, поющая чаша
• Белый шум

Киты поют в три слоя — песня, далёкая стая и толща океана. Каждый удар поющей чаши звучит как новая чаша. У сердцебиения живой, чуть плавающий ритм.

МИКСЫ
• Смешивайте любые звуки — у каждого своя громкость
• Готовые миксы: Кафе, Фокус, Костёр, Море, Гроза, Ночной поезд, Библиотека
• «Наугад» собирает осмысленную сцену: костёр летней ночью, кафе в дождь, глубина с китами
• Сохраняйте свои миксы — они появятся первыми в строке пресетов

ДЛЯ СНА И ФОКУСА
• Помодоро-таймер: фокус под ваш микс, перерыв — в тишине
• ⌃⌥P — пауза из любого приложения
• Запуск при входе в систему

КРАСИВО И НАТИВНО
• Liquid Glass, светлая и тёмная темы
• Подложка в цветах играющего микса
• 12 акцентных цветов
• Значок в строке меню мягко «дышит», пока играет звук

ЧЕСТНО
Без аккаунтов, рекламы и подписок. Только анонимная статистика использования, чтобы делать приложение лучше. Все звуки работают офлайн.

Записи — из открытой библиотеки Moodist (Pixabay License и CC0).
```

**What's New** (4000): `Первая версия в App Store.`

---

## Notes for the reviewers (App Review Information → Notes)

```
Murmur is a menu bar app (LSUIElement, no Dock icon).

- On first launch the mixer opens automatically under the waveform icon in the menu bar
  (or as a regular window if the menu bar icon is hidden, e.g. behind the notch).
- Afterwards, click the waveform icon in the menu bar to open the mixer.
- Click a sound row to start it; drag the line under its name to change its volume.
- The tiles under the play button are presets; "Shuffle" (dice) builds a random scene.
- ⌃⌥P toggles playback from any app. Space toggles it while the mixer is open.
- Gear icon: theme, backdrop, accent color, launch at login, About, Quit.

No account. The app sends anonymous usage statistics (TelemetryDeck); nothing else goes over the network.
All recordings are bundled
(Moodist library, Pixabay License / CC0); white noise and heartbeat are synthesized in real time.
The UI follows the system language: Russian if it is the first language, English otherwise.
```

---

## Screenshots

Mac App Store: 1 to 10 images at 16:10 — 2880×1800 (or 2560×1600 / 1440×900 / 1280×800).
Make one set per localization: the English set with the Mac in English, the Russian one with Russian as the first language.

1. Open the Murmur panel and start a good-looking mix.
2. ⌘⇧4, then Space, then click the panel — macOS saves it on a transparent background with a shadow.
3. Frame the shot (from the project folder):
   ```
   swift scripts/make_screenshot.swift ~/Desktop/panel.png "Sounds that never loop" "Rain, a campfire, the sea and 18 more sounds — mix them right in the menu bar." shot1.png
   ```

Ideas for the set:
| # | On the panel | Title | Caption | Title (RU) | Caption (RU) |
|---|---|---|---|---|---|
| 1 | The Café mix | Sounds that never loop | Rain, a campfire, the sea and 18 more sounds — mix them right in the menu bar. | Звуки, которые не повторяются | Дождь, костёр, море и ещё 18 звуков — смешивайте прямо в строке меню. |
| 2 | Whales + underwater, backdrop in the mix's colors | Whales sing in three layers | The song, a distant pod and the deep ocean — different every time. | Киты поют в три слоя | Песня, далёкая стая и толща океана — каждый раз по-новому. |
| 3 | The preset strip with your own mixes | Your mixes, one click away | Save your favorite combinations, and Shuffle builds a new scene. | Свои миксы — в одно касание | Сохраняйте любимые сочетания, а «Наугад» соберёт новую сцену. |
| 4 | The Pomodoro menu during focus | Pomodoro focus | Breaks in silence, a singing bowl marks each change. ⌃⌥P pauses from any app. | Фокус по помодоро | Перерыв — в тишине, смену отметит поющая чаша. ⌃⌥P — пауза из любого приложения. |
| 5 | Dark theme, another accent | Liquid Glass and 12 accents | Light and dark themes, a backdrop in the mix's colors. | Liquid Glass и 12 акцентов | Светлая и тёмная темы, подложка в цветах микса. |
