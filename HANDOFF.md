# Murmur — handoff

Нативное macOS-приложение для строки меню: смешивание фоновых звуков (дождь, костёр, кафе, киты, белый шум) для работы и сна. Звуки — только из открытой библиотеки Moodist (Pixabay License / CC0) или синтез в коде; чужих звуков, иконок и брендов в проекте нет и быть не должно.

- Состояние: v1.0, работает, установлено у автора в `/Applications/Murmur.app`.
- Стек: Swift 5 language mode (компилятор Swift 6.4), SwiftUI + AppKit, AVAudioEngine. Единственная зависимость — Sparkle 2 (SwiftPM, автообновление только в DMG-версии, §6).
- Минимальная ОС: macOS 14 Sonoma. Сборка универсальная (arm64 + x86_64).
- Язык интерфейса: **русский или английский** — по первому языку системы (`ru*` → русский, иначе английский). Все видимые строки обёрнуты в `L("по-русски", "In English")`, помощник и `Lang.isRussian` — в `Sound.swift`. Проверить английский: `build/Murmur.app/Contents/MacOS/Murmur --snapshot <prefix> -AppleLanguages "(en)"`. В бандле есть `en.lproj`/`ru.lproj` (`Resources/Localization`, нужны для текстов App Intents, §4 «App Intents»), `CFBundleLocalizations = [en, ru]`, `CFBundleDevelopmentRegion = en` — так системные тексты и App Intents выбирают язык по тому же правилу, что `L()` (русский Mac → ru, любой другой → en). Тонкость: при языках «украинский, русский» бандл выберет ru, а `L()` — английский (смотрит только на первый язык).

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
build/Murmur.app/Contents/MacOS/Murmur --selftest          # проверка «Живого микса» + 150 с каждого звука: RMS, пик, NaN, «repeat»; сигнал помодоро; логика помодоро; App Intents (exit 1 при ошибке)
build/Murmur.app/Contents/MacOS/Murmur --playtest          # реально проиграть все пресеты и сигнал помодоро, замерить уровень на выходе
build/Murmur.app/Contents/MacOS/Murmur --snapshot preview  # preview-light/dark.png + preview-pomodoro-light.png (фокус) и preview-pomodoro-break-dark.png (перерыв), preview-menubar.png (значок в строке меню в реальном размере)
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
7. **App Intents собираются без Xcode-проекта, но нужен полный Xcode** (`appintentsmetadataprocessor`, `appintentsnltrainingprocessor`, `xcodebuild -version`). Подробно — §4 «App Intents». Тексты интентов — только строковые литералы (никаких `L()`), иначе они не попадут в метаданные.

---

## 3. Структура

```
Package.swift                 SwiftPM, executable target "Murmur", macOS 14
Package.resolved              закреплённая версия Sparkle (2.10.0)
build.sh                      сборка: 2 арх → lipo → .app + Sparkle.framework → иконка → Info.plist → метаданные App Intents → подпись → оформленный DMG
build-appstore.sh             App Store-версия (без Sparkle, песочница), §6
appcast.xml                   лента обновлений Sparkle (раздаётся с raw.githubusercontent.com), §6
scripts/make_appcast.sh       добавляет релиз из build/Murmur.dmg в appcast.xml с подписью EdDSA
Sources/Murmur/
  MurmurApp.swift             @main (чистый AppKit), AppDelegate: NSStatusItem + GlassPanel, окно-фолбэк, GlassHost; SelfTest
  Sound.swift                 модель звука и каталог Sound.all (28 шт.), категории, Color(hex:)
  AudioEngine.swift           AVAudioEngine-граф, каналы с плавной громкостью, NoiseGenerator (шумы/тоны), LoopBuilder (петля часов + общие хелперы)
  CallDucking.swift           «Тише во время созвонов»: MicMonitor (кто пишет с микрофона, CoreAudio) и DuckEnvelope (огибающая приглушения)
  Texture.swift               гранулярный движок: TextureGenerator / GrainLayer, HeartbeatGenerator, SourceLoader, FastRandom
  Drift.swift                 «Живой микс»: Drift (медленный дрейф уровня), DriftingGenerator, DriftSwitch
  MixStore.swift              состояние (ObservableObject): активные звуки, громкости, пресеты, таймер сна, помодоро, хоткей, автозапуск
  Pomodoro.swift              чистая модель помодоро: PomodoroPlan (ритмы), PomodoroPhase, PomodoroState (фаза + конец), countdownLabel
  Views.swift                 весь UI (панель, ленты, строки, слайдеры) + нативные NSMenu (MenuBuilder, ActionMenuItem)
  Updater.swift               автообновление (Sparkle, стандартный UI); при -DAPPSTORE — пустая заглушка
  Intents.swift               App Intents: действия для «Быстрых команд»/Spotlight/Siri, MixEntity, App Shortcuts, фильтр фокусирования
Resources/Sounds/*.mp3        19 записей (≈34 МБ), копируются в .app/Contents/Resources/Sounds
Resources/Localization/       en.lproj (английский для App Intents: Localizable.strings, AppShortcuts.strings) и ru.lproj
Resources/icon-1024.png       иконка (генерируется scripts/make_icon.swift)
scripts/make_icon.swift       рисует иконку кодом: `swift scripts/make_icon.swift Resources/icon-1024.png`
scripts/make_dmg_background.swift  фон окна DMG (логотип, название, стрелка); build.sh вызывает его сам
scripts/update_cask.sh        обновляет version/sha256 в Homebrew-каске (§6)
packaging/homebrew/murmur.rb  Homebrew-каск — источник правды, в tap копируется отсюда
CREDITS.md                    источники и лицензии звуков (кладётся в бандл)
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
- **«Тише во время созвонов»** (`CallDucking.swift`, меню ⚙, по умолчанию включено, ключ `duckDuringCalls`). Когда другое приложение в звонке — и пишет с микрофона, и играет звук (Zoom, Meet в браузере, Telegram, FaceTime…), — Murmur за 1,5 с уходит в тишину; после освобождения микрофона ждёт 2,5 с (чтобы mute/unmute не «качал» звук) и за 3 с возвращается. Это отдельный множитель `duck.gain` в `MixStore.applyMaster` (`master × таймер сна × duck`) — громкости, микс и `isPlaying` не меняются.
  - `MicMonitor` сам микрофон **никогда не открывает** (разрешение не нужно): читает HAL-объекты процессов (macOS 14+) — `kAudioHardwarePropertyProcessObjectList` и у каждого `kAudioProcessPropertyIsRunningInput` (то же, что зажигает оранжевую точку) и `…IsRunningOutput`, кроме своего PID.
  - **Что считается звонком** — `CallDetector.callApps` (чистая функция над списком «bundle ID, пишет, играет»): приложение пишет **и** играет. Процессы, чьи bundle ID вложены друг в друга (`kontur.talk` + `kontur.talk.helper`, `com.google.Chrome` + `com.google.Chrome.helper` — так Chrome называет процесс со звуком Meet), считаются одним приложением; соседи по вендору (`com.apple.VoiceMemos` и `com.apple.Music`) — нет. Safari/WebRTC пишет и играет в одном `com.apple.WebKit.GPU`. Только запись (Plaud, диктовка) не приглушает; Murmur (PID и свой bundle ID) не считается никогда. `kAudioDevicePropertyDeviceIsRunningSomewhere` сигналом быть не может: у AirPods/гарнитур вход и выход — одно устройство, и его «запускает» собственный звук Murmur; флаги устройств (все устройства со входом) служат только поводом перепроверить процессы. Слушатели на вход и выход каждого процесса (кроме себя) и на все устройства со входом; при смене списков процессов/устройств слушателей получают только новые объекты (исчезнувшие свои теряют, остальные не трогаются). Пачка уведомлений от одного звука где угодно схлопывается в одну проверку через 0,25 с плюс контрольную через 1 с после затишья.
  - **Грабли (1.11 → исправлено):** слушатели — только через C-API `AudioObjectAddPropertyListener`/`AudioObjectRemovePropertyListener` (функция + `clientData`-`Relay`). `AudioObjectRemovePropertyListenerBlock` из Swift молча ничего не снимает и всё равно возвращает `noErr`: в 1.11 каждая переподписка добавляла ещё копию всех слушателей, и каждая копия на любой звук в системе обходила все аудиопроцессы по IPC. Murmur в простое съедал до ~1 с CPU на каждый чужой звук, и чем дольше аптайм, тем больше. `--selftest`, строка «mic listeners: ok (4 calls…)»: 20 раз start/stop, затем беззвучный `afplay`; больше 12 вызовов или вызов после `stop()` — FAIL.
  - `DuckEnvelope` — чистая структура от времени (smoothstep-гейн), `--selftest` прогоняет её («duck envelope: ok») и случаи `CallDetector` («call detector: ok»), а строка «mic monitor:» печатает, кто сейчас пишет с микрофона и из-за кого Murmur приглушился бы.
  - Когда приглушение дошло до 0, движок ставится на паузу (`AudioEngine.isPaused`: `engine.pause()`, `ensureRunning`/`recover()` его не запускают); перед возвратом звука — `recover()` (за звонок устройство вывода часто меняется: AirPods → режим гарнитуры). Простой (стоп через 2 с без каналов) работает как раньше.
  - Индикация: в строке меню полоски замирают низко, в футере панели вместо динамика у общей громкости — значок микрофона цвета акцента. В тестовых режимах (`sandboxed`) монитор не запускается.
  - Риск: приложение, которое пишет в одном процессе, а играет в процессе с невложенным bundle ID, звонком не распознается; рекордер, у которого вложенный helper что-то играет, — наоборот, приглушит.
- **Гранулярные текстуры вместо петель** (`Texture.swift`) — главное средство против повторов. Раньше каждый звук был одной записью по кругу (у китов круг 27,5 с, у клавиатуры 9,5 с — ухо это слышало). Теперь:
  - `SourceLoader` декодирует запись (до 120 с), обрезает тишину по краям, нормализует громкость (`LoopBuilder.loudnessGain`: `min(0.13/RMS, 0.8/p99.9, 25) × boost`) + `softClip`. Буферы кэшируются (`NSCache`, ключ `src:<файл>:<boost>`).
  - У звука есть `layers: [Layer]` (`Sound.swift`). Каждый `GrainLayer` непрерывно запускает «гранулы»: случайный фрагмент записи случайной длины (`length`), со случайной скоростью/тоном (`rate`, линейная интерполяция), громкостью (`gainJitterDB`), панорамой (`pan`), случайным зеркалированием L/R (`swapChannels`). Соседние гранулы склеиваются равномощным кроссфейдом (`fade`); недавние позиции не повторяются. `gap > 0` делает слой разреженным (редкие события с паузами).
  - Многослойные звуки: **киты** = основная песня (rate 0.93–1.06) + «далёкая стая» (rate 0.78–0.9, −7 дБ, паузы 2–10 с) + фон `underwater.mp3` (−9 дБ); **гроза** + далёкие раскаты; **птицы** + редкие птицы по сторонам; **колокольчики** + второй слой.
  - Всё считается на аудиопотоке без аллокаций (`UnsafeMutablePointer`, `FastRandom`).
  - `--selftest` меряет «repeat»: корреляцию звука с самим собой через старую длину петли (петля = 1.00). Сейчас 0.00–0.16 у всех текстур.
- **«Живой микс»** (`Drift.swift`, ⚙ → «Живой микс», по умолчанию вкл., UserDefaults `livingMix`) — то же «не петля», но на уровне микса: громкость каждого звука медленно гуляет вокруг слайдера (дождь то усиливается, то стихает, кафе наполняется и пустеет). Это множитель поверх громкости канала: в `volumes` не пишется, слайдеры не двигаются, сохранённые миксы не меняются.
  - Смещение в дБ = сумма трёх синусов со случайными несоизмеримыми периодами (150–300 с, 80–150 с, 60–90 с; веса 1 / 0.6 / 0.3) и случайными фазами, нормированная на сумму весов → никогда не выходит за ±`Sound.drift` дБ, в среднем ровно 0 (микс в среднем такой, как выставил пользователь) и не повторяется. Скорость ≤ ~0.15 дБ/с — изменение слышно только за минуты.
  - Глубина — `Sound.drift` (±дБ, по умолчанию 2): ветер 3; дождь, гроза, птицы, улица, кафе, клавиатура 2.5; ручей, поезд, библиотека 1.5; кот, винил, чаша 1; белый шум 0.75; **часы и сердцебиение 0** (точный ритм/пульс). Часы — `AVAudioPlayerNode`, их обёртка и не касается.
  - Применяется на аудиопотоке: `AudioEngine.makeNode(_:for:)` оборачивает генератор в `DriftingGenerator`, который после `render` умножает буфер на усиление, линейно интерполированное от прошлого буфера к текущему (`last + step·i`, не накопительной суммой — иначе во Float шаги ~1e-7 теряются и на стыке буферов появляется ступенька). Без аллокаций, без таймеров: 60-Гц таймер рампы по-прежнему останавливается, движок засыпает через 2 с без каналов как раньше. Таймер сна гасит master и затем цели каналов → тишина точная (дрейф — множитель).
  - Выключение/включение — общий `DriftSwitch` (читается аудиопотоком); глубина плавно уезжает в 0 (или из 0) за `Drift.toggleTime` = 6 с, после чего множитель ровно 1.0.
  - `--selftest` первой строкой проверяет дрейф: 30 мин симуляции для каждого звука — в пределах ±drift, не быстрее 0.25 дБ/с (при выключении ≤ 0.75 дБ/с), размах ≥ половины глубины, звуки с `drift: 0` и выключенный дрейф — ровно 1.0; обёртка над постоянным сигналом без ступенек (шаг между сэмплами < 1e-5). При провале — `FAIL living mix: …` и код выхода 1.
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
- **Помодоро** (`Pomodoro.swift` + раздел `// MARK: Pomodoro` в `MixStore`):
  - Ритмы `PomodoroPlan.presets`: 25/5 (длинный 15), 50/10 (длинный 30), 90/20 (длинный 30); каждый 4-й перерыв длинный (`longEvery`). Фазы по индексу: чётные — фокус, нечётные — перерывы, перерыв № 4, 8, … — длинный.
  - `PomodoroState` — чистое значение (индекс фазы + время конца). `advanced(at:)`: если тик опоздал ≤ 5 с (`catchUp`), новая фаза начинается ровно с конца старой (без накопления дрейфа); если позже (Mac спал) или фаза пропущена досрочно — с «сейчас», на полную длину. Тик 0,5 с, как у таймера сна.
  - Перерыв: текущий микс пользователя (`active` + `volumes`) откладывается в `focusMix`, затем кроссфейд 6 с (`pomodoroCrossfade`, обычные рампы движка) в микс перерыва (по умолчанию «Море», `b.sea`; любой пресет/свой микс или «Тишина» = пустой `active`). Конец перерыва — кроссфейд обратно, **ровно** к сохранённым звукам и громкостям. Изменения во время перерыва относятся к миксу перерыва и не сохраняются; `persist()` во время перерыва пишет `focusMix`, а не микс перерыва. Пауза/Play не трогаются: на паузе смена фаз просто меняет микс беззвучно.
  - Сигнал смены фазы — один удар поющей чаши (`Chime` в `AudioEngine.swift`: первые 11 с записи `bowl.mp3`, хвост 4 с, перерыв — ниже тоном, ×0.84, фокус — ×1.0), разовый `AVAudioPlayerNode` поверх микса через master, громкость 0.22 (≈ уровень одного звука, `--playtest`: −24 dBFS). Пока чаша звучит, движок не останавливается по простою (`cues`). Системных бипов нет.
  - Таймер сна и помодоро **взаимоисключающие**: запуск одного останавливает другой (остановка помодоро во время перерыва возвращает микс фокуса). Stop (■) останавливает и помодоро.
  - Запуск — `startPomodoro()` (если звук не играет, включается, как у таймера сна); «Пропустить перерыв»/«Перерыв сейчас» — `skipPomodoroPhase()`; смена ритма во время работы перезапускает с фокуса.
  - Сохраняются только выбор: `pomodoroPlan` (id ритма) и `pomodoroBreak` (id микса или `silence`; удалённый свой микс → «Море»). Само состояние после перезапуска не восстанавливается. Тестовые режимы ничего не пишут (`sandboxed`).
- Глобальный хоткей **⌃⌥P** (Carbon `RegisterEventHotKey`, не требует прав Accessibility).
- Автозапуск: `SMAppService.mainApp` (надёжно работает из `/Applications`).
- Персистентность: ключи `active`, `volumes`, `master`, `userMixes`, `launchedBefore`, `livingMix`, `pomodoroPlan`, `pomodoroBreak`, `duckDuringCalls` (а также `theme`/`backdrop`/`accent`; + `focusSession` — что включил фильтр фокусирования, см. «App Intents»).
- `statusLine` и `suggestedMixName` — `statusLine` после редизайна в UI не используется (можно удалить).

### UI (`Views.swift`)
Структура: шапка → пресеты → список звуков со слайдерами → футер; стиль macOS 26/27 **Liquid Glass**:
- ширина 292; фон панели не задаём — им служит `NSGlassEffectView` из `GlassHost.makePanelContent`. Цвета семантические (`.primary/.secondary`), чтобы работала вибрация на стекле;
- `liquidGlass(in:tint:interactive:)` — `glassEffect(Glass.regular.tint(..).interactive())` на macOS 26+, матовый материал на 14–15; `GlassGroup` = `GlassEffectContainer`;
- шапка: стеклянные круглые кнопки «☰ все миксы» и «⚙»; в центре **Stop (38 pt) и Play (50 pt) — два отдельных круга** с зазором 10 pt, без общего `GlassEffectContainer` (в 1.1–1.8 они сливались в одну «каплю», автору не понравилось). Play — стекло, тонированное акцентным цветом, без непрозрачной заливки, чтобы уважать системную настройку стекла;
- `Aurora` — мягкое цветное свечение в цветах играющих звуков, только при подложке «В цветах микса»; иконки активных звуков окрашены `sound.tint.gradient`;
- **полоса пресетов** под шапкой (`PresetStrip`): одна горизонтальная лента — **🎲 «Наугад» всегда первая**, затем сохранённые миксы пользователя (новые сразу после «Наугад»), затем встроенные Кафе / Фокус / Костёр / Море. Лента идёт **от края до края панели** (ширина 292, внутренний отступ 12): стеклянные плитки рисуются отдельным слоем и **не обрезаются границами ScrollView** — в 1.7 «Наугад» был закреплён справа, и прокручиваемые плитки проступали под ним. До 5 плиток они ровно заполняют ширину; больше — плитки сужаются до 46 pt, и следующая выглядывает у края. Трекпад листает нативно; колесо мыши — по одной плитке (`WheelCatcher`). Правый клик по своему миксу → «Удалить микс». После сохранения лента прокручивается к началу.
- компактный список: строка 44 pt, иконка 17 pt light, название 12.5 pt, `LineSlider` — трек 2.5 pt, риска 3×11;
- футер: стеклянная «пилюля» таймеров + общая громкость. Пилюля одна на оба таймера (они не работают одновременно) и показывает то, что включено: «⏱ Таймер» (ничего), «🌙 29:59» (таймер сна), «⌖ Фокус 24:13» / «☕ Перерыв 4:59» (помодоро; `.fixedSize()`, чтобы отсчёт не обрезался). Меню пилюли (`MenuBuilder.timer`): раздел «Таймер сна» (15…120 мин, «Отменить таймер сна») и раздел «Помодоро» («Начать: фокус 25 мин» или «Сейчас: фокус, 2 из 4» + «Перерыв сейчас»/«Пропустить перерыв» + «Остановить помодоро»; подменю «Ритм» и «Звук перерыва»: Тишина / пресеты / свои миксы). Вторую пилюлю рядом не добавляли: при ширине 292 она не помещается рядом с громкостью;
- фокус-рамки отключены (`.focusEffectDisabled()`, `.focusable(false)` на кнопках);
- всплывающие подсказки (`.help`) убраны намеренно — автору они мешали; не возвращать;
- меню — нативные `NSMenu` через `MenuBuilder.popUp`. Сохранение микса — `NSAlert` с текстовым полем.
- в меню ⚙ над «О Murmur» — «Проверить обновления…» и «Проверять обновления автоматически» (только если `Updater.shared.isAvailable`: DMG-сборка с ключом EdDSA, §6).

### Строка меню и панель (`MurmurApp.swift`)
- Точка входа — `MurmurMain` (чистый AppKit, `.accessory`). **SwiftUI `App` не используется**: со сценой `Settings` он сам открывал пустое окно 900×450 при каждом запуске, а `MenuBarExtra` даёт непрозрачное серое окно, которое нельзя сделать стеклянным.
- Значок — `NSStatusItem` с иконкой `StatusIcon` (рисуется кодом: кружок + 4 полоски, template). Пока играет звук, полоски мягко покачиваются (таймер 12 fps, амплитуда ±20 %); на паузе таймер остановлен. Рядом — отсчёт таймера сна или помодоро; во время помодоро сразу за кружком рисуется маленький значок фазы (`StatusIcon.image(…, badge:)`: `scope` (прицел) — фокус, `cup.and.saucer` — перерыв), всё одно template-изображение, так что цвет строки меню соблюдается.
- **Акцент** (меню ⚙ → Акцент, `AccentChoice`): «как в системе» (`NSColor.controlAccentColor`, по умолчанию), лаванда, сирень, роза, малина, коралл, мандарин, янтарь, песок, лайм, изумруд, графит. Акцент красит только Play, линии громкости, выбранный пресет и «Таймер сна»; значки на стеклянных кнопках (☰, ⚙, Stop) и подписи пресетов — цветом текста (`.primary`), иначе при сером системном акценте они сливаются со стеклом. `Theme.tint1/tint2/gradient/link` — вычисляемые, читают `Theme.accent`, который выставляет `MixStore`. Бирюза `#49EEC8` из ранних версий автору не понравилась — не возвращать.
- Контраст: выключенные строки — `Theme.dimText/dimIcon` (тёмно-серые в светлой теме, светло-серые в тёмной), а не `.secondary` — тот на светлом стекле нечитаем.
- Настройки внешнего вида (меню ⚙): **Тема** (как в системе / светлая / тёмная → `window.appearance`) и **Подложка** (`PanelBackdrop`): системная (`NSGlassEffectView.style = .regular`, без оттенка) или в цветах микса (оттенок первого звука через `GlassHost.mixTint` + `Aurora`). **По умолчанию — «В цветах микса»** (с 1.10). `mixTint` — динамический цвет: в тёмной теме цвет микса затемняется (65 % чёрного, α 0.55), в светлой высветляется (55 % белого, α 0.3) — иначе в тёмной теме на ярких обоях стекло становилось светлым и текст терялся. `Aurora` в тёмной теме тоже тише (0.16 против 0.3). Режимы «прозрачная» (`.clear`) и «матовая» были в 1.2 и удалены — выглядели плохо. Хранятся в UserDefaults `theme`/`backdrop`, применяются `AppDelegate.applyAppearance()` ко всем стеклянным окнам.
- «О Murmur» — своё окно (`AboutView`, обычное системное окно без стекла): иконка, версия, ссылка на GitHub, описание, лицензии, «© 2026 Maksim Berezkin».
- **Грабли со скруглёнными углами (важно):** Liquid Glass рисует световую кромку чуть за пределами своей формы. Если окно заканчивается ровно по краю стекла, она обрезается прямоугольником окна → тёмные линии/«квадратные уголки» по краям (особенно в тёмной теме и снизу). Решение (`GlassHost.makePanelContent`): окно панели на `GlassHost.margin` = 22 pt больше стекла с каждой стороны, прозрачное, `hasShadow = false`. Своей тени нет — в 1.3 была CALayer-тень, автору она показалась артефактом, убрана в 1.4. Клик в прозрачный запас закрывает панель (`GlassPanel.sendEvent`). Контент дополнительно обрезан по `GlassHost.panelRadius` (22, continuous).
- Обычные окна (запасное окно микшера, «О программе») — стандартные системные окна **без** `NSGlassEffectView`: стекло во всё прямоугольное окно даёт те же артефакты в углах.
- Панель — `GlassPanel` (`NSPanel`, borderless + nonactivating, может быть key → работает пробел). Контент — `GlassHost.makePanelContent`: SwiftUI в `NSHostingView` внутри **`NSGlassEffectView`** (macOS 26+; следует системной настройке Liquid Glass «прозрачное/тонированное»), до 26 — `NSVisualEffectView(.menu)`. Закрывается по клику снаружи (global monitor), Esc, потере фокуса.
- **Грабли macOS 27:** строку меню рисует система; окно статус-айтема в нашем процессе — заглушка с фреймом `(0, -33, 32, 33)`, `screen == nil`. Поэтому: при клике по значку панель позиционируется по курсору (`showPanel(fromClick: true)`); если координат нет и это не клик — открывается окно-фолбэк.
- Окно-фолбэк (`showWindow`, `ContentView(inWindow: true)`, обычное окно): при самом первом запуске и при повторном открытии приложения (двойной клик), если панель не к чему привязать.

### App Intents: «Быстрые команды», Spotlight, Siri, фильтр фокусирования (`Intents.swift`)
- **Действия** (все `openAppWhenRun = false`, `perform()` на `@MainActor`, берут `MixStore` из `AppDelegate` через `MixStore.forIntents()`): «Включить микс» (параметр — `MixEntity`), «Наугад», «Пауза / Играть» (toggle), «Играть», «Пауза», «Остановить», «Таймер сна» (минуты 1–720, по умолчанию 30), «Выключить таймер сна», «Громкость Murmur» (0–100). Расширения (appex) нет: интенты выполняются в самом приложении; если Murmur не запущен, система запускает его в фоне.
- **`MixEntity` / `MixQuery`** (`EntityStringQuery`): встроенные пресеты + миксы пользователя, id = `Mix.id`. Список отдаёт живой `MixStore`, без него — `Mix.presets + MixStore.savedUserMixes()`. При сохранении/удалении микса и при запуске вызывается `MurmurShortcuts.updateAppShortcutParameters()`, чтобы фраза «Включи <микс> в Murmur» знала новые миксы.
- **`MurmurShortcuts`** (`AppShortcutsProvider`): 6 App Shortcuts с русскими фразами — видны в Spotlight и «Быстрых командах» без настройки. В каждой фразе обязателен `\(.applicationName)`.
- **Фильтр фокусирования** `MurmurFocusFilter` (`SetFocusFilterIntent`): Настройки → Фокусирование → режим → Фильтры фокусирования → Murmur → микс + «Пауза, когда режим выключится». Система вызывает `perform()` и при включении режима (с выбранными значениями), и при выключении (со значениями по умолчанию, т. е. `mix == nil`), поэтому решение «ставить ли на паузу» запоминается при включении (`FocusSession`, UserDefaults `focusSession`). На паузу ставится только если играет ровно тот микс, что включил режим.
- **Язык.** Всё, что попадает в метаданные (заголовки, описания, параметры, `Summary`, фразы, `shortTitle`), — **строковые литералы на русском**: build.sh извлекает их на этапе компиляции, `L()` там не сработает. Английский — в `Resources/Localization/en.lproj`: `Localizable.strings` (ключ — русский литерал; в `Summary` параметр пишется как `${mix}`) и `AppShortcuts.strings` (фразы, `${applicationName}`). `ru.lproj` нужен, чтобы русский был в списке локализаций бандла. **`--selftest` проверяет, что у каждого ключа из метаданных есть английский перевод** («FAIL no English for …»), — добавляя/меняя текст интента, обновите en.lproj.

**Как собираются метаданные (build.sh, без Xcode-проекта).** Xcode делает для интентов два шага, build.sh повторяет их вручную:
1. `swift build … -Xswiftc -emit-const-values -Xswiftc -const-gather-protocols-list -Xswiftc build/intents/protocols.json` — компилятор пишет `*.swiftconstvalues` (значения всех типов, соответствующих протоколам из списка; список взят из сборки Xcode 27 — `<Target>_const_extract_protocols.json`). Новый бэкенд SwiftPM делает это и сам, флаги — для надёжности. Файл лежит в `.build/out/Intermediates.noindex/Murmur.build/Release/Murmur-p.build/Objects-normal/arm64/Murmur-primary.swiftconstvalues`; build.sh находит самый свежий `*.swiftconstvalues` в `*release*/…/arm64/`.
2. `xcrun appintentsmetadataprocessor --compile-time-extraction --deployment-aware-processing …` → `Contents/Resources/Metadata.appintents/{extract.actionsdata,version.json}`. Метаданные не зависят от архитектуры — хватает arm64.
3. `xcrun appintentsnltrainingprocessor … --archive-ssu-assets` → `<lang>.lproj/nlu.appintents` и `Metadata.appintents/root.ssu.yaml` (модели фраз для Siri/Spotlight; ru из литералов, en из `AppShortcuts.strings`).
Затем обычная подпись — метаданные внутри `Resources`, их запечатывает codesign. Bundle ID в метаданные не попадает, поэтому `build-appstore.sh` (меняет ID на `com.docomoz.murmur`, песочница) ничего пересобирать не должен; дополнительных entitlements для интентов и фильтров фокусирования не нужно.

**Как система их находит (проверено 12.10 на macOS 27).** Демон `linkd` индексирует `Metadata.appintents` после регистрации в LaunchServices, **но только после того, как приложение хоть раз запустили** — до первого запуска в логе `Bundle … is not trusted for binding, skipping`. После запуска: `Adding …/Metadata.appintents/extract.actionsdata`, `Inserting canonical bundle`, `LNMetadataChangedNotification added`, `Interpolating AppShortcuts`, «donating to Siri»; `duetexpertd`/Shortcuts загружает все 10 действий, фильтр — как `WFFocusConfigurationLinkAction`. Как проверить, не запуская GUI:
```bash
./build.sh
# Копия с другим Bundle ID, чтобы не путать с установленным Murmur. Не в /tmp: из временных папок
# linkd бандл не находит (LS error -10814).
mkdir -p build/check && cp -R build/Murmur.app build/check/
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.murmur.check" build/check/Murmur.app/Contents/Info.plist
codesign --force -s - build/check/Murmur.app
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSREG -f build/check/Murmur.app
open -n -g build/check/Murmur.app --args --selftest     # «запуск» без окна: selftest сам завершается
/usr/bin/log show --last 1m --predicate 'process == "linkd" AND eventMessage CONTAINS "app.murmur.check"' --style compact
$LSREG -u build/check/Murmur.app && rm -rf build/check  # убрать за собой
```
(в zsh `log` — встроенная команда, поэтому `/usr/bin/log`). Сам индекс (`~/Library/Daemon Containers/…/appintents.sqlite3`) и XPC `com.apple.linkd.registry` закрыты для сторонних процессов — только логи.
- Если в «Быстрых командах» видны старые действия: копий с одним Bundle ID несколько (build/, /Applications) — `lsregister -f /Applications/Murmur.app` и запустить его.
- В ad-hoc сборке `linkd` пишет `Failed to generate bundleIdentity: Unable to get teamId` — у ad-hoc подписи нет Team ID; индексации это не мешает. Как это влияет на выполнение — не проверено (см. §7).

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

**Добавить звук:** положить mp3 в `Resources/Sounds/<id>.mp3`, добавить `Sound(...)` в `Sound.all` с подходящими `layers` и `drift` (глубина «Живого микса», 0 для ритмичных звуков) (контурный SF Symbol; проверить существование: `NSImage(systemSymbolName:)`), пересобрать, прогнать `--selftest` (RMS ≈ 0.1–0.13, repeat < 0.2, без NaN). Короткие записи — короткие гранулы (`length` 1–7 с); речь/голоса — узкий `rate` (±1 %), иначе слышно «ускорение». Для генераторов — новый `case` в `SoundSource` и ветка в `AudioEngine.load` / `NoiseGenerator`.

---

## 6. Распространение

### Mac App Store (подготовлено, ждёт аккаунта разработчика)
- Пошаговая инструкция для автора: **`AppStore/README.md`**; тексты страницы RU/EN с проверенными лимитами, ключевые слова, заметки для App Review и идеи скриншотов: `AppStore/metadata.md`; политика конфиденциальности: `AppStore/PRIVACY.md` (URL в App Store Connect указывает на неё на GitHub).
- `build-appstore.sh` берёт результат `build.sh` и делает App Store-версию: Bundle ID **`com.docomoz.murmur`** (DMG остаётся `app.murmur.mac`, чтобы не терять настройки существующих установок), `ITSAppUsesNonExemptEncryption = false`, `PrivacyInfo.xcprivacy` (только UserDefaults, причина CA92.1), песочница `AppStore/Murmur.entitlements` (только `app-sandbox`, больше ничего не нужно).
  - Без переменных — локальная тестовая сборка в песочнице с ad-hoc подписью (`build/appstore/Murmur.app`).
  - С `MAS_APP_IDENTITY` (Apple Distribution), `MAS_INSTALLER_IDENTITY` (3rd Party Mac Developer Installer) и `MAS_PROFILE` (Mac App Store Connect profile) — встраивает профиль, добавляет `com.apple.application-identifier`/`team-identifier` из профиля в entitlements, подписывает и собирает `build/appstore/Murmur.pkg` для Transporter.
- Проверено в песочнице (12.10): все записи читаются, звук играет (`--selftest`, `--playtest`), настройки пишутся в `~/Library/Containers/com.docomoz.murmur`, панель открывается. Глобальный монитор кликов, хоткей и автозапуск в песочнице допустимы, но вживую в App Store-сборке не проверялись.
- App Intents в App Store-сборке: `Metadata.appintents` переходит из `build.sh` как есть (Bundle ID в нём не записан), entitlements не нужны. Проверено 12.10: песочная ad-hoc сборка `com.docomoz.murmur` после регистрации и запуска проиндексирована `linkd` (действия + App Shortcuts). В App Store Connect стоит упомянуть действия «Быстрых команд» и фильтр фокусирования в описании.
- `scripts/make_screenshot.swift <panel.png> "Заголовок" "Подпись" out.png` — кадр 2880×1800 для App Store из снимка панели (⌘⇧4 → пробел → клик).
- Приложение бесплатное: банковские/налоговые формы не нужны. Автор: Maksim Berezkin, аккаунт Apple ID — Казахстан, карта — Киргизия (обсуждали; второй аккаунт не нужен).
- Интерфейс двуязычный (см. «Язык интерфейса» выше), английская страница App Store ему соответствует; в английском UI «Наугад» = «Shuffle».

### DMG (GitHub Releases)

- `build.sh` подписывает ad-hoc (`codesign -s -`). Без сертификата Apple Developer ($99/год) у друзей Gatekeeper ругнётся при первом запуске: «Системные настройки → Конфиденциальность и безопасность → Всё равно открыть» или `xattr -dr com.apple.quarantine /Applications/Murmur.app`. Это описано в `README.md`.
- Релизная сборка с Developer ID и нотаризацией: `DEVELOPER_ID="Developer ID Application: Maksim Berezkin (TEAMID)" NOTARY_PROFILE=murmur-notary ./build.sh`. Скрипт подписывает с hardened runtime, нотаризует и степлит сначала .app (zip), потом подписанный DMG. Без переменных — прежняя ad-hoc сборка. `NOTARY_PROFILE` без `DEVELOPER_ID` — ошибка.
- В DMG только `Murmur.app` и ссылка на `Applications`, между ними стрелка на фоне (без txt). `build.sh` создаёт записываемый образ, кладёт `.background/background.tiff` (1x+2x, рисует `scripts/make_dmg_background.swift`), раскладывает окно через AppleScript в Finder (нужен доступ Терминала к Finder, окно на секунду мелькнёт), затем кладёт `.VolumeIcon.icns` и сжимает в UDZO. Размер окна и позиции иконок — переменные `WIN_*`/`APP_X`/`APPS_X`/`ICON_Y` в `build.sh`, фон рисуется под них. `WIN_H` — высота без заголовка (заголовок Finder ≈32 pt на macOS 27, у фона есть запас снизу); при иконках 128 и `WIN_H` < 330 Finder показывает скроллбар. Подписи под иконками Finder рисует чёрными в светлой теме и белыми в тёмной, поэтому низ фона средне-тёмный.
- `.VolumeIcon.icns` нельзя класть заранее: `hdiutil -srcfolder` его пропускает, а Finder удаляет при настройке окна.
- Однократная настройка: сертификат «Developer ID Application» (developer.apple.com → Certificates, CSR из «Связки ключей»; проверить: `security find-identity -v -p codesigning`), затем `xcrun notarytool store-credentials murmur-notary --apple-id <id> --team-id <TEAMID>` с app-specific password с appleid.apple.com.
- Entitlements не нужны (ни приложению, ни Sparkle: его XPC-сервисы, которым они нужны, из бандла удаляются). До Sparkle `--selftest` проходил и с ad-hoc подписью + `--options runtime`; **теперь ad-hoc + hardened runtime не запускается**: library validation не грузит Sparkle.framework без Team ID (`different Team IDs`). С настоящим Developer ID у приложения и фреймворка один Team ID — так и задумано Sparkle; ad-hoc сборка поэтому подписывается без runtime. Чтобы не нотаризовать неработающее приложение, Developer ID-ветка `build.sh` после подписи запускает `--selftest` и падает, если dyld отказал.
- Версия задаётся в `build.sh`: `VERSION` (CFBundleShortVersionString) и `BUILD_NUMBER` (CFBundleVersion — по нему Sparkle сравнивает версии, поднимать каждый релиз). Автор: Maksim Berezkin (в «О программе», копирайте и LICENSE).

### Автообновление DMG-версии (Sparkle 2)

**Как устроено.**
- Sparkle 2.10.0 подключён через SwiftPM (`Package.swift`, точная версия; `Package.resolved` в репозитории). Первая сборка скачивает его (клон ~50 МБ + бинарный zip ~10 МБ в `.build`). `build.sh` копирует универсальный `Sparkle.framework` из `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64` в `Contents/Frameworks` (rpath `@executable_path/../Frameworks` задан в `Package.swift`), удаляет `XPCServices` (нужны только приложениям в песочнице) и заголовки, кладёт `Sparkle-LICENSE.txt`.
- Подпись — по документации Sparkle для сборок без Xcode, изнутри наружу и **без `--deep`**: `Autoupdate`, `Updater.app`, фреймворк, затем приложение (`sign_app` в `build.sh`; для Developer ID — с `--options runtime --timestamp`).
- `Updater.swift`: `SPUStandardUpdaterController` со стандартным окном Sparkle. Запускается в `applicationDidFinishLaunching` (не в `--selftest/--snapshot/--playtest`) и **только если в Info.plist есть `SUFeedURL` и `SUPublicEDKey`** — иначе меню обновлений не показывается. `SUEnableAutomaticChecks = true`: проверка раз в сутки без вопроса «проверять ли автоматически?»; выключается пунктом меню ⚙.
- Murmur — `.accessory` без Дока, поэтому окно Sparkle легко потерять. По схеме Sparkle «gentle reminders» для фоновых приложений: пока показано обновление, приложение временно становится `.regular` (значок в Доке и в ⌘Tab, для фоновой проверки — бейдж «1»), по завершении сессии — снова `.accessory`. Ручная проверка закрывает панель и делает `NSApp.activate`, чтобы окно было впереди. Вживую (глазами) окно Sparkle не проверялось — см. «Проверено».
- Ключи в Info.plist пишет `build.sh`: `SUPublicEDKey` — из `SPARKLE_PUBLIC_KEY` или файла `Resources/sparkle-public-key.txt` (публичный ключ не секрет, файл коммитится); `SUFeedURL` — `SPARKLE_FEED_URL`, по умолчанию `https://raw.githubusercontent.com/docomoz/Murmur/main/appcast.xml`. Без ключа сборка идёт как раньше, с подсказкой «автообновление выключено».
- **Лента** — `appcast.xml` в корне репозитория, раздаётся raw.githubusercontent.com (кэш ~5 мин; GitHub Pages не нужен). `enclosure` указывает на DMG в релизе: `https://github.com/docomoz/Murmur/releases/download/vX.Y/Murmur.dmg`. Sparkle сам монтирует DMG и берёт `Murmur.app`; карантин с обновления снимает.
- `scripts/make_appcast.sh [notes.md|.html|.txt]` монтирует `build/Murmur.dmg`, читает версию/сборку/минимальную ОС и `SUPublicEDKey` **из приложения внутри DMG**, подписывает DMG `sign_update` (ключ из связки ключей или `SPARKLE_KEY_FILE`), **проверяет подпись публичным ключом из приложения** (CryptoKit; ловит «подписал не тем ключом») и вставляет `<item>` первым в `appcast.xml` (повторный запуск заменяет элемент с тем же `sparkle:version`). Заметки в Markdown показываются в окне Sparkle (`sparkle:format="markdown"`). Переопределения: `DMG`, `APPCAST`, `DOWNLOAD_URL`.
- Осторожно: `sign_update` с XML-файлом (например, `appcast.xml`) не просто печатает подпись, а **встраивает её в файл** — подписывать надо только DMG (скрипт так и делает).

**Ad-hoc vs Developer ID (выяснено по исходникам Sparkle `SUUpdateValidator.m` и проверено).** Для обновления-приложения Sparkle требует, чтобы прошла *хотя бы одна* проверка: подпись EdDSA из ленты или совпадение подписи Apple нового и старого приложения; если EdDSA прошла, а Apple-подписи разные, новое приложение должно иметь просто *валидную* подпись (ad-hoc годится). Значит:
- ad-hoc → ad-hoc работает (через EdDSA), проверено от начала до конца (ниже); ad-hoc → Developer ID тоже пройдёт (EdDSA), Developer ID → Developer ID — по обеим проверкам;
- без EdDSA-ключа ad-hoc обновляться не может, поэтому автообновление включается только при наличии `SUPublicEDKey`;
- переход «Developer ID → ad-hoc» Sparkle тоже пропустит (EdDSA), но так делать не стоит; а убрать ключ EdDSA в новой версии Sparkle запрещает.
- Gatekeeper обновление не трогает: Sparkle снимает карантин. У ad-hoc-установок при первой установке остаётся прежний ритуал «Всё равно открыть» — один раз.

**Один раз (автор).**
1. `swift package resolve` (или `./build.sh`) — появятся инструменты в `.build/artifacts/sparkle/Sparkle/bin/`.
2. `.build/artifacts/sparkle/Sparkle/bin/generate_keys` — создаёт ключ Ed25519 **в связке ключей входа** (аккаунт `ed25519`) и печатает публичный ключ. Публичный записать в `Resources/sparkle-public-key.txt` и закоммитить.
3. Резервная копия приватного ключа: `generate_keys -x ~/sparkle-murmur.key` → положить в менеджер паролей/надёжное место, файл удалить. Потеря ключа = установленные копии больше не примут обновления (только при смене через совпадающую Developer ID-подпись). На другом Mac: `generate_keys -f файл` импортирует ключ в связку. Приватный ключ **не коммитить**.
4. Можно без связки ключей: `SPARKLE_KEY_FILE=путь scripts/make_appcast.sh` (`sign_update --ed-key-file`).

**Чек-лист релиза DMG.**
1. Поднять в `build.sh` `VERSION` и `BUILD_NUMBER`.
2. `DEVELOPER_ID=… NOTARY_PROFILE=murmur-notary ./build.sh` (или просто `./build.sh` — ad-hoc тоже обновляется). Ключ должен попасть в Info.plist (нет строки «автообновление выключено»).
3. `scripts/make_appcast.sh notes.md` — подписывает **именно этот** `build/Murmur.dmg`; после него DMG не пересобирать.
4. `gh release create vX.Y build/Murmur.dmg` (тег строго `v` + `VERSION` — на него указывает ссылка в ленте).
5. Закоммитить и запушить `appcast.xml` **после** того, как DMG загружен в релиз (иначе Sparkle скачает 404).
6. Проверка: в установленной предыдущей версии ⚙ → «Проверить обновления…».

Версии ≤ 1.10 Sparkle не содержат: их пользователи один раз ставят новую версию вручную, дальше — автоматически.

**Проверить обновление локально** (как проверялось 12.10, ничего не трогая в `/Applications` и настройках `app.murmur.mac`): одноразовый ключ без связки ключей — 32 случайных байта в base64 (`Curve25519.Signing.PrivateKey().rawRepresentation` из CryptoKit; `sign_update --ed-key-file` такой файл принимает), публичный ключ — `publicKey.rawRepresentation` в base64. Затем `SPARKLE_PUBLIC_KEY=… SPARKLE_FEED_URL=http://127.0.0.1:8765/appcast.xml ./build.sh`; две копии во временной папке с Bundle ID `app.murmur.mac.updatetest` (старая 1.10 и новая 1.11/12, переподписать `codesign --force -s -`), DMG новой, `DMG=… APPCAST=… DOWNLOAD_URL=http://127.0.0.1:8765/Murmur.dmg SPARKLE_KEY_FILE=… scripts/make_appcast.sh`, `python3 -m http.server 8765 --bind 127.0.0.1`; `defaults write app.murmur.mac.updatetest SUAutomaticallyUpdate -bool YES` и `launchedBefore -bool YES`, запустить старую копию → через ~5 с она скачивает ленту и DMG, запускает `Autoupdate`; после завершения процесса копия становится 1.11. После теста — `defaults delete app.murmur.mac.updatetest`, удалить `~/Library/Caches/app.murmur.mac.updatetest` и `~/Library/HTTPStorages/app.murmur.mac.updatetest`. HTTP на 127.0.0.1 ATS не блокирует.

**App Store.** `build-appstore.sh` вызывает `MURMUR_APPSTORE=1 DEVELOPER_ID= NOTARY_PROFILE= ./build.sh`: код Sparkle вырезан (`-Xswiftc -DAPPSTORE`, `Updater` — заглушка, пунктов меню нет), фреймворк не линкуется (`-Xlinker -dead_strip_dylibs`) и не копируется, ключей `SU*` нет; `build.sh` в этом режиме останавливается после подписи (без нотаризации и DMG). `build-appstore.sh` дополнительно падает, если в бандле есть Sparkle.framework, ссылка на него в `otool -L` или `SUFeedURL`. Следствие: после `build-appstore.sh` в `build/` лежит Murmur.app **без** Sparkle и нет DMG — для релиза DMG снова `./build.sh`.

### Homebrew (свой tap; ничего не опубликовано)

Решение: **сейчас — свой tap `docomoz/homebrew-tap`** (`brew install --cask docomoz/tap/murmur`), официальный `homebrew/cask` — позже. В официальный не пройти по двум причинам (проверено `brew audit --cask --new` 12.10): (1) Gatekeeper — ad-hoc сборка не проходит проверку подписи, а по Acceptable Casks приложения обязаны её проходить; такие каски Homebrew депрекейтит и удаляет; (2) notability (Package Acceptance Policy): ≥30 форков / 30 watchers / 75 звёзд, а для самоподачи владельцем репозитория ≥90 / 90 / 225; репозиторию должно быть ≥30 дней. Свой tap этих требований не имеет.

Файлы: `packaging/homebrew/murmur.rb` — каск (источник правды), `scripts/update_cask.sh` — подставляет версию и sha256 (по умолчанию берёт digest опубликованного ассета через `gh`, без `gh` скачивает; `--local` — хеш `build/Murmur.dmg`; `--tap <путь>` — копирует в checkout tap и прогоняет `brew style`). Скрипт ничего не коммитит и не пушит.

Каск: `depends_on macos: :sonoma` (сейчас это «не ниже»; строка `">= :sonoma"` устарела), `uninstall quit:` (приложение в строке меню обычно запущено), `zap` — `~/Library/Preferences/app.murmur.mac.plist` (кроме UserDefaults приложение ничего не пишет) и Saved Application State. Автозапуск через `SMAppService.mainApp` в каск не вписан: `uninstall login_item:` работает только со старыми login items, а запись SMAppService Homebrew не трогает: без приложения она становится недействительной (не проверено руками). Пока сборка ad-hoc, в каске блок `caveats` про «Всё равно открыть» / `xattr` (Homebrew ставит карантин; флага `--no-quarantine` больше нет).

С Homebrew 6 сторонние tap требуют доверия: `brew install --cask docomoz/tap/murmur` (полное имя) работает сразу; короткое `brew install --cask murmur` — только после `brew tap docomoz/tap` и `brew trust --cask docomoz/tap/murmur`. В README давать полное имя.

**Чек-лист автора**
1. ✓ Сделано 12.10: репозиторий https://github.com/docomoz/homebrew-tap, клон в `~/Projects/homebrew-tap` (`Casks/murmur.rb` + README).
2. ✓ Сделано 12.10: опубликован cask 1.11 (`auto_updates true` — в 1.11 есть Sparkle; `zap` чистит и кэши Sparkle). `brew audit --cask --strict --online docomoz/tap/murmur` проходит, строка установки добавлена в README.
3. Каждый релиз: `./build.sh` → `gh release create vX.Y build/Murmur.dmg` → `scripts/update_cask.sh --tap ~/Projects/homebrew-tap` (версию берёт из `build.sh`) → коммит `packaging/homebrew/murmur.rb` здесь и `Casks/murmur.rb` в tap. Хешировать нужно ровно тот DMG, что загружен: DMG не воспроизводим, повторный `./build.sh` даёт другой sha256. `brew livecheck --cask docomoz/tap/murmur` показывает, отстал ли каск.
4. После первой нотаризованной сборки (Developer ID, §6 DMG): удалить блок `caveats` в каске, опубликовать.
5. Официальный `homebrew/cask` — когда релизы нотаризованы, а у репозитория ≥90 форков / 90 watchers / 225 звёзд (самоподача) или кто-то другой подаёт его при ≥30 / 30 / 75. Проверить локально: `brew tap-new --no-git <user>/test`, положить каск в `Casks/`, `brew audit --cask --new <user>/test/murmur` должен пройти без ошибок; затем `brew untap`. PR — в Homebrew/homebrew-cask (`Casks/m/murmur.rb`, токен `murmur` свободен); после принятия убрать каск из своего tap (или оставить, но не держать два источника).
6. Sparkle (если появится автообновление): добавить `auto_updates true` (иначе `brew upgrade` и Sparkle будут спорить о версии), можно перейти на `livecheck` со `strategy :sparkle` по appcast; в `zap` добавить `~/Library/Caches/app.murmur.mac` и `~/Library/HTTPStorages/app.murmur.mac`.

---

## 7. Проверено / не проверено

Проверено автоматически: сборка обеих архитектур; все петли (стыки чистые, уровни выровнены, костёр/сверчки/парусник чуть тише — природа записей); все пресеты и тоны реально играют через движок; вёрстка (снапшоты светлой/тёмной темы); автор подтвердил: «всё работает».

Автообновление (12.10): `./build.sh` и `./build-appstore.sh` собираются, `codesign --verify --deep --strict` проходит, `--selftest` проходит в обеих сборках; в App Store-сборке нет ни фреймворка, ни ссылки на него, ни строк Sparkle в бинарнике. Сквозной тест с одноразовым ключом и лентой на localhost (§6): ad-hoc 1.10 сама скачала и поставила 1.11, подпись нового бандла валидна, карантина нет, `--selftest` проходит; лента с подписью чужим ключом — обновление отклонено (осталась 1.10), а `make_appcast.sh` с чужим ключом падает. Не проверено: Developer ID + нотаризация с Sparkle (нет сертификата; ad-hoc + runtime не годится для имитации, см. §6), окно Sparkle при ручной проверке и смена `.accessory/.regular` глазами.

Не проверено руками ассистентом (нет доступа к UI): нативные меню (миксы/таймер/настройки), горячая клавиша ⌃⌥P, таймер сна до конца, автозапуск, поведение при смене аудиоустройства. Помодоро: логика смены фаз, подмена/возврат микса и взаимоисключение с таймером сна проверяются в `--selftest`, сигнал реально играет в `--playtest`, пилюля — в снапшотах; живой цикл 25 мин с кроссфейдами, значок фазы в строке меню и меню «Помодоро» вживую не смотрели.

App Intents (12.10): проверено, что метаданные собираются и `linkd` их индексирует (обычная и песочная сборки), Shortcuts загружает все 10 действий и фильтр фокусирования, App Shortcuts интерполируются; `--selftest` сверяет метаданные и английские переводы. **Не проверено** (нужен живой GUI): реальный запуск действий из «Быстрых команд»/Spotlight/Siri (в т. ч. фоновый запуск незапущенного Murmur и ad-hoc сборка без Team ID), список миксов в параметре, срабатывание фильтра при включении/выключении режима фокусирования, распознавание русских фраз Siri.

---

## 8. Идеи / TODO

- Не открывать окно при автозапуске (определять запуск как login item) или сделать настройку «Показывать окно при запуске».
- Удалить мёртвый `statusLine` из `MixStore`.
- Анимированные иконки активных звуков, сейчас «пульсируют» только шумы/тоны.
- Liquid Glass проверен только сборкой и офлайн-снапшотом с подменой — живой вид на macOS 26/27 стоит посмотреть глазами.
- Возможно, стоит дать пользователю регулятор «разнообразия» (ширина `rate`/частота событий).
- Media keys / Now Playing (`MPRemoteCommandCenter`) — осознанно не сделано, чтобы не перехватывать клавиши у Музыки.
- Локализация (EN), настройка хоткея, больше звуков из Moodist (там 80+: airport, night-village, rain-on-tent, singing-bowl и т. д.).
- Developer ID + нотаризация: `build.sh` готов (§6), ждём одобрения Apple Developer Program и первой реальной нотаризации (теперь вместе с Sparkle.framework).
- Автообновление: сгенерировать ключ (`generate_keys`), закоммитить `Resources/sparkle-public-key.txt`, выпустить первый релиз со Sparkle по чек-листу §6.
- Репозиторий: https://github.com/docomoz/Murmur (публичный). DMG выкладывается в Releases: `gh release create vX.Y build/Murmur.dmg`.
