# Murmur — handoff

Нативное macOS-приложение для строки меню: смешивание фоновых звуков (дождь, костёр, кафе, киты, белый шум) для работы и сна. Звуки — только из открытой библиотеки Moodist (Pixabay License / CC0) или синтез в коде; чужих звуков, иконок и брендов в проекте нет и быть не должно.

- Состояние: v1.0, работает, установлено у автора в `/Applications/Murmur.app`.
- Стек: Swift 5 language mode (компилятор Swift 6.4), SwiftUI + AppKit, AVAudioEngine. Без сторонних зависимостей.
- Минимальная ОС: macOS 14 Sonoma. Сборка универсальная (arm64 + x86_64).
- Язык интерфейса: **русский или английский** — по первому языку системы (`ru*` → русский, иначе английский). Все видимые строки обёрнуты в `L("по-русски", "In English")`, помощник и `Lang.isRussian` — в `Sound.swift`. Проверить английский: `build/Murmur.app/Contents/MacOS/Murmur --snapshot <prefix> -AppleLanguages "(en)"`. `Info.plist` пока без `CFBundleLocalizations`, поэтому выбрать язык приложения отдельно в Системных настройках нельзя — можно добавить.

---

## 1. Быстрый старт

```bash
cd ~/Projects/Murmur
./build.sh                                  # → build/Murmur.app и build/Murmur.dmg (~1 мин)
open build/Murmur.app
cp -R build/Murmur.app /Applications/       # установить
```

Отладочные режимы (запуск бинарника внутри бандла, чтобы `Bundle.main` видел звуки):

```bash
build/Murmur.app/Contents/MacOS/Murmur --selftest          # отрендерить 150 с каждого звука: RMS, пик, NaN и «repeat» (повторяемость)
build/Murmur.app/Contents/MacOS/Murmur --playtest          # реально проиграть все пресеты и замерить уровень на выходе
build/Murmur.app/Contents/MacOS/Murmur --snapshot preview  # отрендерить окно в preview-light.png / preview-dark.png
open build/Murmur.app --args --open-panel                   # запустить и сразу открыть панель (как клик по значку)
```

`--playtest` реально играет звук (тихо: master 0.22 в памяти; замер компенсирует громкость). **`--snapshot` и `--playtest` работают в песочнице (`MixStore.sandboxed`)**: читают настройки пользователя, но ничего не записывают. Раньше снапшот сохранял тестовые миксы в настоящие настройки автора — не повторять; и не трогать `defaults write app.murmur.mac …` вручную.

---

## 2. Окружение и грабли (важно!)

1. **`@State` раньше был недоступен.** Пока на машине были только Command Line Tools, `@State` не работал: в текущем SDK `@State` — макрос, а плагина `SwiftUIMacros` в CLT нет: ошибка `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`. Обход, принятый во всём проекте:
   ```swift
   private let hoverState = State<Bool>(initialValue: false)
   private var hover: Bool { get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue } }
   // биндинг: hoverState.projectedValue
   ```
   Теперь установлен Xcode 27 (`xcode-select -p` → `/Applications/Xcode.app`), и обычный `@State` компилируется. Старые вью можно не переписывать: обход тоже работает.
2. **Путь бинарника SwiftPM** — новый бэкенд кладёт его в `.build/out/Products/Release/Murmur` и перезаписывает при сборке под другую архитектуру. `build.sh` поэтому собирает каждую архитектуру, сразу копирует результат через `swift build --show-bin-path`, затем `lipo`.
3. **Подмена бинарника внутри подписанного .app** → процесс убивается (exit 137). После ручного `cp` бинарника обязательно `codesign --force --deep -s - build/Murmur.app`.
4. **zsh: не называйте переменную `path`** — она связана с `$PATH` и ломает shell.
5. Предупреждения `ld: warning: search path ... not found` и `hdiutil ... deprecated` безвредны.
6. `ImageRenderer` (режим `--snapshot`) не рисует `ScrollView`, `Menu` и **Liquid Glass** (стеклянные элементы пропадают вместе с содержимым). При `SelfTest.isRendering = true` список выводится без ScrollView, а `liquidGlass`/`GlassGroup` подменяют стекло матовой подложкой. Настоящее стекло видно только в живом приложении.

---

## 3. Структура

```
Package.swift                 SwiftPM, executable target "Murmur", macOS 14
build.sh                      сборка: 2 арх → lipo → .app → иконка → Info.plist → ad-hoc подпись → DMG
Sources/Murmur/
  MurmurApp.swift             @main (чистый AppKit), AppDelegate: NSStatusItem + GlassPanel, окно-фолбэк, GlassHost; SelfTest
  Sound.swift                 модель звука и каталог Sound.all (28 шт.), категории, Color(hex:)
  AudioEngine.swift           AVAudioEngine-граф, каналы с плавной громкостью, NoiseGenerator (шумы/тоны), LoopBuilder (петля часов + общие хелперы)
  Texture.swift               гранулярный движок: TextureGenerator / GrainLayer, HeartbeatGenerator, SourceLoader, FastRandom
  MixStore.swift              состояние (ObservableObject): активные звуки, громкости, пресеты, таймер сна, хоткей, автозапуск
  Views.swift                 весь UI (панель, ленты, строки, слайдеры) + нативные NSMenu (MenuBuilder, ActionMenuItem)
Resources/Sounds/*.mp3        19 записей (≈34 МБ), копируются в .app/Contents/Resources/Sounds
Resources/icon-1024.png       иконка (генерируется scripts/make_icon.swift)
scripts/make_icon.swift       рисует иконку кодом: `swift scripts/make_icon.swift Resources/icon-1024.png`
CREDITS.md                    источники и лицензии звуков (кладётся в бандл)
README-друзьям.txt            инструкция для получателей DMG (кладётся в DMG как «Как открыть.txt»)
preview-*.png                 последние снапшоты UI
build/                        артефакты (не исходники)
```

Bundle ID: `app.murmur.mac`. `LSUIElement = true` (нет иконки в Доке). Настройки — `UserDefaults` этого домена.

---

## 4. Архитектура

### Аудио (`AudioEngine.swift`)
- Граф: `[канал] → mainMixerNode → PeakLimiter (AVAudioUnitEffect) → outputNode`. Лимитер нужен, чтобы микс из многих звуков не клиппировал.
- **Канал** = `AVAudioSourceNode` с генератором реального времени (`RealtimeGenerator`: текстура, шум, тон, сердце; 48 кГц стерео) или — только для часов — `AVAudioPlayerNode` с точной петлёй. Каналы создаются лениво при первом `setTarget(gain > 0)` и удаляются, когда громкость доехала до 0.
- **Плавность**: у каждого канала `gain → target` с линейной скоростью; таймер 60 Гц в `RunLoop.main(.common)`. Клик/вкл/выкл никогда не щёлкает.
- **Простой**: через 2 с без каналов движок останавливается (CPU, сон Mac). `recover()` перезапускает граф после смены устройства вывода / пробуждения (`AVAudioEngineConfigurationChange`, `NSWorkspace.didWakeNotification`).
- **Гранулярные текстуры вместо петель** (`Texture.swift`) — главное средство против повторов. Раньше каждый звук был одной записью по кругу (у китов круг 27,5 с, у клавиатуры 9,5 с — ухо это слышало). Теперь:
  - `SourceLoader` декодирует запись (до 120 с), обрезает тишину по краям, нормализует громкость (`LoopBuilder.loudnessGain`: `min(0.13/RMS, 0.8/p99.9, 25) × boost`) + `softClip`. Буферы кэшируются (`NSCache`, ключ `src:<файл>:<boost>`).
  - У звука есть `layers: [Layer]` (`Sound.swift`). Каждый `GrainLayer` непрерывно запускает «гранулы»: случайный фрагмент записи случайной длины (`length`), со случайной скоростью/тоном (`rate`, линейная интерполяция), громкостью (`gainJitterDB`), панорамой (`pan`), случайным зеркалированием L/R (`swapChannels`). Соседние гранулы склеиваются равномощным кроссфейдом (`fade`); недавние позиции не повторяются. `gap > 0` делает слой разреженным (редкие события с паузами).
  - Многослойные звуки: **киты** = основная песня (rate 0.93–1.06) + «далёкая стая» (rate 0.78–0.9, −7 дБ, паузы 2–10 с) + фон `underwater.mp3` (−9 дБ); **гроза** + далёкие раскаты; **птицы** + редкие птицы по сторонам; **колокольчики** + второй слой.
  - Всё считается на аудиопотоке без аллокаций (`UnsafeMutablePointer`, `FastRandom`).
  - `--selftest` меряет «repeat»: корреляцию звука с самим собой через старую длину петли (петля = 1.00). Сейчас 0.00–0.16 у всех текстур.
- **HeartbeatGenerator**: синтез «lub-dub» с вариабельностью ритма — темп плавает 54–64 уд/мин, каждый удар ±2,5 % по времени и 0.82–1.0 по силе.
- **LoopBuilder** остался только для **часов** (ритм должен быть точным): окно `LoopRegion(start: 0.45, length: 15.005)` = ровно 15 тиков, кроссфейд 0.03 с.
- **NoiseGenerator**: белый шум (`FastRandom`, ×0.15). Розовый/коричневый шум и тоны 432/528 Гц были, но удалены по просьбе автора (v1.2).
- **Режим событий** (`Layer.events`) для однократных записей: поющая чаша — один удар с затуханием ~35 с; запись целиком запускается каждые 12–24 с со своим тоном (rate 0.94–1.06) и панорамой, новые удары звучат поверх затухающих (до 4 одновременно).

### Состояние (`MixStore.swift`, `@MainActor`)
- `active: [String]` (порядок включения), `volumes: [id: Double]`, `master`, `isPlaying`, `userMixes`, таймер.
- Кривая громкости слайдеров: `pow(v, 1.6)`; master → `mainMixerNode.outputVolume`.
- `sync(fade:)` пересчитывает цели всех каналов. Перетаскивание слайдера выключенного звука включает его.
- Пресеты `Mix.presets` (встроенные, не удаляются) + пользовательские (JSON в UserDefaults `userMixes`).
- **«Наугад»** (`MixStore.randomMix` / `randomLevels`) — по сценам (`MixStore.scenes`): сцена = якорные звуки + совместимые с ними дополнения (кафе в дождь, костёр ночью, лес днём, море, глубина, гроза, поезд, медитация, библиотека, фокус, уют…). Берётся якорь (громкость 0.55–0.8) + 1–2 дополнения (0.2–0.45); тот же набор, что уже играет, не повторяется. `--selftest` печатает 12 примеров. Добавляя звук, впишите его в подходящие сцены, иначе «Наугад» его никогда не выберет.
- Таймер сна: 15/30/45/60/90/120 мин, последние 45 с громкость плавно уходит в 0, отсчёт показывается в строке меню.
- Глобальный хоткей **⌃⌥P** (Carbon `RegisterEventHotKey`, не требует прав Accessibility).
- Автозапуск: `SMAppService.mainApp` (надёжно работает из `/Applications`).
- Персистентность: ключи `active`, `volumes`, `master`, `userMixes`, `launchedBefore`.
- `statusLine` и `suggestedMixName` — `statusLine` после редизайна в UI не используется (можно удалить).

### UI (`Views.swift`)
Структура: шапка → пресеты → список звуков со слайдерами → футер; стиль macOS 26/27 **Liquid Glass**:
- ширина 292; фон панели не задаём — им служит `NSGlassEffectView` из `GlassHost.makePanelContent`. Цвета семантические (`.primary/.secondary`), чтобы работала вибрация на стекле;
- `liquidGlass(in:tint:interactive:)` — `glassEffect(Glass.regular.tint(..).interactive())` на macOS 26+, матовый материал на 14–15; `GlassGroup` = `GlassEffectContainer`;
- шапка: стеклянные круглые кнопки «☰ все миксы» и «⚙»; в центре **Stop (38 pt) и Play (50 pt) — два отдельных круга** с зазором 10 pt, без общего `GlassEffectContainer` (в 1.1–1.8 они сливались в одну «каплю», автору не понравилось). Play — стекло, тонированное акцентным цветом, без непрозрачной заливки, чтобы уважать системную настройку стекла;
- `Aurora` — мягкое цветное свечение в цветах играющих звуков, только при подложке «В цветах микса»; иконки активных звуков окрашены `sound.tint.gradient`;
- **полоса пресетов** под шапкой (`PresetStrip`): одна горизонтальная лента — **🎲 «Наугад» всегда первая**, затем сохранённые миксы пользователя (новые сразу после «Наугад»), затем встроенные Кафе / Фокус / Костёр / Море. Лента идёт **от края до края панели** (ширина 292, внутренний отступ 12): стеклянные плитки рисуются отдельным слоем и **не обрезаются границами ScrollView** — в 1.7 «Наугад» был закреплён справа, и прокручиваемые плитки проступали под ним. До 5 плиток они ровно заполняют ширину; больше — плитки сужаются до 46 pt, и следующая выглядывает у края. Трекпад листает нативно; колесо мыши — по одной плитке (`WheelCatcher`). Правый клик по своему миксу → «Удалить микс». После сохранения лента прокручивается к началу.
- компактный список: строка 44 pt, иконка 17 pt light, название 12.5 pt, `LineSlider` — трек 2.5 pt, риска 3×11;
- футер: стеклянная «пилюля» «Таймер сна» + общая громкость;
- фокус-рамки отключены (`.focusEffectDisabled()`, `.focusable(false)` на кнопках);
- всплывающие подсказки (`.help`) убраны намеренно — автору они мешали; не возвращать;
- меню — нативные `NSMenu` через `MenuBuilder.popUp`. Сохранение микса — `NSAlert` с текстовым полем.

### Строка меню и панель (`MurmurApp.swift`)
- Точка входа — `MurmurMain` (чистый AppKit, `.accessory`). **SwiftUI `App` не используется**: со сценой `Settings` он сам открывал пустое окно 900×450 при каждом запуске, а `MenuBarExtra` даёт непрозрачное серое окно, которое нельзя сделать стеклянным.
- Значок — `NSStatusItem` с иконкой `StatusIcon` (рисуется кодом: кружок + 4 полоски, template). Пока играет звук, полоски мягко покачиваются (таймер 12 fps, амплитуда ±20 %); на паузе таймер остановлен. Рядом — отсчёт таймера сна.
- **Акцент** (меню ⚙ → Акцент, `AccentChoice`): «как в системе» (`NSColor.controlAccentColor`, по умолчанию), лаванда, сирень, роза, малина, коралл, мандарин, янтарь, песок, лайм, изумруд, графит. Акцент красит только Play, линии громкости, выбранный пресет и «Таймер сна»; значки на стеклянных кнопках (☰, ⚙, Stop) и подписи пресетов — цветом текста (`.primary`), иначе при сером системном акценте они сливаются со стеклом. `Theme.tint1/tint2/gradient/link` — вычисляемые, читают `Theme.accent`, который выставляет `MixStore`. Бирюза `#49EEC8` из ранних версий автору не понравилась — не возвращать.
- Контраст: выключенные строки — `Theme.dimText/dimIcon` (тёмно-серые в светлой теме, светло-серые в тёмной), а не `.secondary` — тот на светлом стекле нечитаем.
- Настройки внешнего вида (меню ⚙): **Тема** (как в системе / светлая / тёмная → `window.appearance`) и **Подложка** (`PanelBackdrop`): системная (`NSGlassEffectView.style = .regular`, без оттенка) или в цветах микса (оттенок первого звука через `GlassHost.mixTint` + `Aurora`). **По умолчанию — «В цветах микса»** (с 1.10). `mixTint` — динамический цвет: в тёмной теме цвет микса затемняется (65 % чёрного, α 0.55), в светлой высветляется (55 % белого, α 0.3) — иначе в тёмной теме на ярких обоях стекло становилось светлым и текст терялся. `Aurora` в тёмной теме тоже тише (0.16 против 0.3). Режимы «прозрачная» (`.clear`) и «матовая» были в 1.2 и удалены — выглядели плохо. Хранятся в UserDefaults `theme`/`backdrop`, применяются `AppDelegate.applyAppearance()` ко всем стеклянным окнам.
- «О Murmur» — своё окно (`AboutView`, обычное системное окно без стекла): иконка, версия, ссылка на GitHub, описание, лицензии, «© 2026 Maksim Berezkin».
- **Грабли со скруглёнными углами (важно):** Liquid Glass рисует световую кромку чуть за пределами своей формы. Если окно заканчивается ровно по краю стекла, она обрезается прямоугольником окна → тёмные линии/«квадратные уголки» по краям (особенно в тёмной теме и снизу). Решение (`GlassHost.makePanelContent`): окно панели на `GlassHost.margin` = 22 pt больше стекла с каждой стороны, прозрачное, `hasShadow = false`. Своей тени нет — в 1.3 была CALayer-тень, автору она показалась артефактом, убрана в 1.4. Клик в прозрачный запас закрывает панель (`GlassPanel.sendEvent`). Контент дополнительно обрезан по `GlassHost.panelRadius` (22, continuous).
- Обычные окна (запасное окно микшера, «О программе») — стандартные системные окна **без** `NSGlassEffectView`: стекло во всё прямоугольное окно даёт те же артефакты в углах.
- Панель — `GlassPanel` (`NSPanel`, borderless + nonactivating, может быть key → работает пробел). Контент — `GlassHost.makePanelContent`: SwiftUI в `NSHostingView` внутри **`NSGlassEffectView`** (macOS 26+; следует системной настройке Liquid Glass «прозрачное/тонированное»), до 26 — `NSVisualEffectView(.menu)`. Закрывается по клику снаружи (global monitor), Esc, потере фокуса.
- **Грабли macOS 27:** строку меню рисует система; окно статус-айтема в нашем процессе — заглушка с фреймом `(0, -33, 32, 33)`, `screen == nil`. Поэтому: при клике по значку панель позиционируется по курсору (`showPanel(fromClick: true)`); если координат нет и это не клик — открывается окно-фолбэк.
- Окно-фолбэк (`showWindow`, `ContentView(inWindow: true)`, обычное окно): при самом первом запуске и при повторном открытии приложения (двойной клик), если панель не к чему привязать.

---

## 5. Каталог звуков

Порядок в списке задаётся категориями в `Sound.all` (новые звуки вставлены в свои категории). id → источник.

| id | Название | Источник |
|---|---|---|
| rain | Дождь | Moodist rain/light-rain |
| storm | Гроза (+ далёкие раскаты) | rain/thunder |
| waves | Морской прибой | nature/waves |
| river | Ручей | nature/river |
| underwater | Под водой | places/underwater (также фон китов) |
| campfire | Костёр (boost 1.8) | nature/campfire |
| wind | Ветер | nature/wind |
| birds | Птицы (+ редкие птицы по сторонам) | animals/birds |
| crickets | Сверчки | animals/crickets |
| whale | Киты (3 слоя) | animals/whale + places/underwater |
| city | Улица | urban/busy-street |
| cafe | Кафе | places/cafe |
| train | Поезд | transport/inside-a-train |
| library | Библиотека | places/library |
| keyboard | Клавиатура | things/keyboard |
| clock | Часы (точная петля) | things/clock |
| heartbeat | Сердцебиение | синтез |
| cat | Мурлыканье кота (замедлено: rate 0.86–0.92, длинные гранулы) | animals/cat-purring |
| vinyl | Виниловая пластинка | things/vinyl-effect |
| bowl | Поющая чаша (режим событий) | things/singing-bowl |
| white | Белый шум | синтез в реальном времени |

В v1.4 по просьбе автора убраны дубли (ливень, дождь в окно, дождь по палатке, водопад, ветер в листве, джунгли, чайки, лягушки, ночная деревня, метро, парусник, самолёт, печатная машинка, вентилятор, колокольчики) — «одна идея = один звук». Файлы удалены из репозитория; при желании их можно вернуть из Moodist.

Пресеты: «Дождливое кафе» (дождь, кафе, немного улицы и винила), «Фокус» (дождь + библиотека + тихий белый шум), «У костра», «Море», «Гроза», «Ночной поезд», «Библиотека» (`Mix.presets` в `MixStore.swift`); все ссылаются только на существующие звуки.

**Лицензии.** Записи — из открытой библиотеки Moodist (github.com/remvze/moodist), лицензии Pixabay Content License и CC0; распространять в составе приложения можно. Скачивались с `https://raw.githubusercontent.com/remvze/moodist/main/public/sounds/<путь>.mp3`. Звуки из коммерческих приложений и сайтов не использовать — только открытые лицензии. Шумы из Moodist (9-секундные петли) сознательно заменены синтезом.

**Добавить звук:** положить mp3 в `Resources/Sounds/<id>.mp3`, добавить `Sound(...)` в `Sound.all` с подходящими `layers` (контурный SF Symbol; проверить существование: `NSImage(systemSymbolName:)`), пересобрать, прогнать `--selftest` (RMS ≈ 0.1–0.13, repeat < 0.2, без NaN). Короткие записи — короткие гранулы (`length` 1–7 с); речь/голоса — узкий `rate` (±1 %), иначе слышно «ускорение». Для генераторов — новый `case` в `SoundSource` и ветка в `AudioEngine.load` / `NoiseGenerator`.

---

## 6. Распространение

### Mac App Store (подготовлено, ждёт аккаунта разработчика)
- Пошаговая инструкция для автора: **`AppStore/README.md`**; тексты страницы RU/EN с проверенными лимитами, ключевые слова, заметки для App Review и идеи скриншотов: `AppStore/metadata.md`; политика конфиденциальности: `AppStore/PRIVACY.md` (URL в App Store Connect указывает на неё на GitHub).
- `build-appstore.sh` берёт результат `build.sh` и делает App Store-версию: Bundle ID **`com.docomoz.murmur`** (DMG остаётся `app.murmur.mac`, чтобы не терять настройки существующих установок), `ITSAppUsesNonExemptEncryption = false`, `PrivacyInfo.xcprivacy` (только UserDefaults, причина CA92.1), песочница `AppStore/Murmur.entitlements` (только `app-sandbox`, больше ничего не нужно).
  - Без переменных — локальная тестовая сборка в песочнице с ad-hoc подписью (`build/appstore/Murmur.app`).
  - С `MAS_APP_IDENTITY` (Apple Distribution), `MAS_INSTALLER_IDENTITY` (3rd Party Mac Developer Installer) и `MAS_PROFILE` (Mac App Store Connect profile) — встраивает профиль, добавляет `com.apple.application-identifier`/`team-identifier` из профиля в entitlements, подписывает и собирает `build/appstore/Murmur.pkg` для Transporter.
- Проверено в песочнице (12.10): все записи читаются, звук играет (`--selftest`, `--playtest`), настройки пишутся в `~/Library/Containers/com.docomoz.murmur`, панель открывается. Глобальный монитор кликов, хоткей и автозапуск в песочнице допустимы, но вживую в App Store-сборке не проверялись.
- `scripts/make_screenshot.swift <panel.png> "Заголовок" "Подпись" out.png` — кадр 2880×1800 для App Store из снимка панели (⌘⇧4 → пробел → клик).
- Приложение бесплатное: банковские/налоговые формы не нужны. Автор: Maksim Berezkin, аккаунт Apple ID — Казахстан, карта — Киргизия (обсуждали; второй аккаунт не нужен).
- Интерфейс двуязычный (см. «Язык интерфейса» выше), английская страница App Store ему соответствует; в английском UI «Наугад» = «Shuffle».

### DMG (GitHub Releases)

- `build.sh` подписывает ad-hoc (`codesign -s -`). Без сертификата Apple Developer ($99/год) у друзей Gatekeeper ругнётся при первом запуске: «Системные настройки → Конфиденциальность и безопасность → Всё равно открыть» или `xattr -dr com.apple.quarantine /Applications/Murmur.app`. Это описано в `README-друзьям.txt`.
- Релизная сборка с Developer ID и нотаризацией: `DEVELOPER_ID="Developer ID Application: Maksim Berezkin (TEAMID)" NOTARY_PROFILE=murmur-notary ./build.sh`. Скрипт подписывает с hardened runtime, нотаризует и степлит сначала .app (zip), потом подписанный DMG, а в «Как открыть.txt» заменяет инструкцию про Gatekeeper на простое «Запусти». Без переменных — прежняя ad-hoc сборка. `NOTARY_PROFILE` без `DEVELOPER_ID` — ошибка.
- Однократная настройка: сертификат «Developer ID Application» (developer.apple.com → Certificates, CSR из «Связки ключей»; проверить: `security find-identity -v -p codesigning`), затем `xcrun notarytool store-credentials murmur-notary --apple-id <id> --team-id <TEAMID>` с app-specific password с appleid.apple.com.
- Entitlements не нужны: `--selftest`/`--playtest` проходят с hardened runtime (проверено ad-hoc подписью с `--options runtime`).
- Версия задаётся в `build.sh` (`VERSION`, `CFBundleVersion`). Автор: Maksim Berezkin (в «О программе», копирайте и LICENSE).

---

## 7. Проверено / не проверено

Проверено автоматически: сборка обеих архитектур; все петли (стыки чистые, уровни выровнены, костёр/сверчки/парусник чуть тише — природа записей); все пресеты и тоны реально играют через движок; вёрстка (снапшоты светлой/тёмной темы); автор подтвердил: «всё работает».

Не проверено руками ассистентом (нет доступа к UI): нативные меню (миксы/таймер/настройки), горячая клавиша ⌃⌥P, таймер сна до конца, автозапуск, поведение при смене аудиоустройства.

---

## 8. Идеи / TODO

- Не открывать окно при автозапуске (определять запуск как login item) или сделать настройку «Показывать окно при запуске».
- Удалить мёртвый `statusLine` из `MixStore`.
- Анимированные иконки активных звуков, сейчас «пульсируют» только шумы/тоны.
- Liquid Glass проверен только сборкой и офлайн-снапшотом с подменой — живой вид на macOS 26/27 стоит посмотреть глазами.
- Возможно, стоит дать пользователю регулятор «разнообразия» (ширина `rate`/частота событий).
- Media keys / Now Playing (`MPRemoteCommandCenter`) — осознанно не сделано, чтобы не перехватывать клавиши у Музыки.
- Локализация (EN), настройка хоткея, больше звуков из Moodist (там 80+: airport, night-village, rain-on-tent, singing-bowl и т. д.).
- Developer ID + нотаризация: `build.sh` готов (§6), ждём одобрения Apple Developer Program и первой реальной нотаризации.
- Репозиторий: https://github.com/docomoz/Murmur (публичный). DMG выкладывается в Releases: `gh release create vX.Y build/Murmur.dmg`.
