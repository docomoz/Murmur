# Публикация Murmur в Mac App Store

Приложение бесплатное. Всё техническое уже готово в проекте:

| Что | Где |
|---|---|
| Песочница (App Sandbox) | `AppStore/Murmur.entitlements` |
| Файл приватности | `AppStore/PrivacyInfo.xcprivacy` |
| Сборка для App Store (Bundle ID `com.docomoz.murmur`, подпись, `.pkg`) | `build-appstore.sh` |
| Тексты страницы, ключевые слова, заметки для проверяющих, идеи скриншотов | `AppStore/metadata.md` |
| Политика конфиденциальности | `AppStore/PRIVACY.md` |
| Оформление скриншотов | `scripts/make_screenshot.swift` |

Версия для App Store — отдельное приложение со своим Bundle ID (`com.docomoz.murmur`). DMG с GitHub остаётся
как есть (`app.murmur.mac`), его настройки не трогаются.

---

## Шаг 1. Аккаунт разработчика (один раз, 99 $ в год)

1. Приложение **Apple Developer** на iPhone или Mac → Account → войти своим Apple ID (с двухфакторной защитой) →
   **Enroll Now** → имя и фамилия латиницей как в документе → тип **Individual** → оплата картой из Apple ID.
   Через приложение попросят сфотографировать документ; через сайт
   (developer.apple.com/programs/enroll) этого шага обычно нет, но Apple может запросить документ позже.
2. Дождаться письма о подтверждении членства (обычно до 24 часов; если нет — developer.apple.com/contact
   с Enrollment ID).
3. App Store Connect (appstoreconnect.apple.com) → **Business** (Agreements): проверить, что соглашение
   для бесплатных приложений принято. Банковские и налоговые формы для бесплатного приложения не нужны.

## Шаг 2. Bundle ID (5 минут)

developer.apple.com/account → **Certificates, Identifiers & Profiles** → **Identifiers** → **+** →
**App IDs** → **App** →
- Description: `Murmur`
- Bundle ID: **Explicit**, `com.docomoz.murmur`
- Capabilities: ничего не отмечать

→ **Continue** → **Register**.

## Шаг 3. Сертификаты (5 минут, через Xcode)

Xcode → **Settings** → **Accounts** → **+** → Apple ID → выбрать свою команду (Team) → **Manage Certificates…** →
**+** → создать два:
- **Apple Distribution** — подпись приложения;
- **Mac Installer Distribution** — подпись `.pkg`.

Проверить, что они появились, и скопировать их точные имена:
```bash
security find-identity -v
```
Понадобятся строки вида `Apple Distribution: Maksim Berezkin (ABCDE12345)` и
`3rd Party Mac Developer Installer: Maksim Berezkin (ABCDE12345)` (так в связке ключей называется
Mac Installer Distribution). `ABCDE12345` — твой Team ID.

## Шаг 4. Профиль (3 минуты)

Certificates, Identifiers & Profiles → **Profiles** → **+** → в разделе Distribution выбрать
**Mac App Store Connect** → App ID `com.docomoz.murmur` → сертификат Apple Distribution → имя
`Murmur Mac App Store` → **Generate** → **Download**. Файл попадёт в `~/Downloads`.

## Шаг 5. Карточка приложения в App Store Connect (5 минут)

App Store Connect → **Apps** → **+** → **New App**:
- Platforms: **macOS**
- Name: `Murmur — звуки для фокуса` (если занято — см. варианты ниже)
- Primary Language: **Russian**
- Bundle ID: `com.docomoz.murmur`
- SKU: `murmur-mac`
- User Access: Full Access

Если название занято: `Murmur: звуки для фокуса и сна`, `Murmur — шум дождя и природы`, `Murmur Ambient`.

## Шаг 6. Сборка и загрузка

Из папки проекта (подставь свои имена сертификатов и Team ID):
```bash
MAS_APP_IDENTITY="Apple Distribution: Maksim Berezkin (ABCDE12345)" MAS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Maksim Berezkin (ABCDE12345)" MAS_PROFILE=~/Downloads/Murmur_Mac_App_Store.provisionprofile ./build-appstore.sh
```
Получится `build/appstore/Murmur.pkg`. Скрипт сам проверяет, что профиль выписан на этот Bundle ID.

Загрузка: поставь бесплатное приложение **Transporter** из Mac App Store → войди тем же Apple ID →
перетащи `Murmur.pkg` → **Deliver**. Через 15–30 минут сборка появится в App Store Connect (придёт письмо).
Если Apple что-то не понравится в самой сборке, ошибка придёт письмом — пришли её мне.

## Шаг 7. Заполнить страницу

App Store Connect → приложение → версия **1.0 Prepare for Submission**. Всё берём из `AppStore/metadata.md`:
1. **Скриншоты** — минимум один 2880×1800 (как сделать — в `metadata.md`).
2. Промотекст, описание, ключевые слова, URL поддержки и маркетинга, авторские права.
3. **Build** → выбрать загруженную сборку.
4. **App Review Information**: вход не требуется (снять галочку Sign-in required), контактные данные,
   **Notes** — текст из `metadata.md`.
5. **Version Release**: вручную или автоматически после одобрения.
6. Слева **App Information**: категории (Производительность / Здоровье и фитнес), возрастной рейтинг
   (все ответы «нет» → 4+), Privacy Policy URL.
7. **App Privacy** → Get Started → «Нет, мы не собираем данные» → Publish.
8. **Pricing and Availability** → Free, все страны.

Английскую локализацию добавь там же (Localization → English): тексты в `metadata.md`. Интерфейс
приложения сам переключается на английский, если язык системы не русский.

## Шаг 8. Отправить на проверку

**Add for Review** → **Submit**. Обычно проверка занимает 1–3 дня. Если отклонят — придёт сообщение в
App Store Connect (раздел App Review); пришли его мне, разберёмся и отправим заново.

---

## Обновления

1. Внести изменения, поднять в `build.sh` `VERSION` (например, `1.11`) и `CFBundleVersion` (каждая загрузка —
   номер сборки строго больше прежнего).
2. Запустить шаг 6, загрузить через Transporter.
3. В App Store Connect: **+ Version**, «Что нового», выбрать сборку, отправить на проверку.

## Проверить версию для App Store без аккаунта

```bash
./build-appstore.sh
```
Соберёт `build/appstore/Murmur.app` в песочнице с локальной подписью — можно запустить и убедиться, что всё
работает так же, как в обычной версии. Загрузить такую сборку нельзя.

## Бонус: DMG без предупреждения Gatekeeper

С тем же аккаунтом можно выпускать DMG для GitHub с подписью Developer ID и нотаризацией — у друзей
пропадёт «не удалось проверить разработчика». Нужен сертификат **Developer ID Application** (Xcode → Manage
Certificates → + ) и профиль для `notarytool` (один раз):
```bash
xcrun notarytool store-credentials murmur-notary --apple-id <твой Apple ID> --team-id ABCDE12345
```
Команда спросит пароль — нужен не обычный, а **пароль приложения**: appleid.apple.com → Вход и безопасность →
Пароли приложений → создать (например, `murmur-notary`).
Затем:
```bash
DEVELOPER_ID="Developer ID Application: Maksim Berezkin (ABCDE12345)" NOTARY_PROFILE=murmur-notary ./build.sh
```
