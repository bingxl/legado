---
name: android-app-dev
description: Use when developing or modifying the Legado Android app (Kotlin): adding Room entities/DAOs, creating Activities/Fragments/ViewModels, following MVVM and View Binding conventions, building, linting, or working with the version catalog, ProGuard rules, or the app/web-server/API controller code. Do NOT use for book source rules (see book-source-author) or the web API integration scripts (see legado-web-api).
---

# Legado Android App Development

Kotlin Android app in `app/` (namespace `io.legado.app`). Java 17 toolchain, View Binding (no Compose), Room with KSP. Dependencies via Gradle version catalog `gradle/libs.versions.toml`.

## Build commands

- Debug APK: `./gradlew assembleAppDebug` (output: `app/build/outputs/apk/app/debug/`)
- Release APK: `./gradlew assembleAppRelease` (requires signing keys)
- Lint: `./gradlew lint`
- Cronet update: `./gradlew app:downloadCronet` after bumping `CronetVersion` in `gradle.properties`

Version is auto-generated as `3.{yy}.{MMddHH}` with `versionCode = 10000 + git commit count`.

## Architecture & conventions

MVVM. Feature code lives in `app/src/main/java/io/legado/app/`.

- **Activity**: extend `VMBaseActivity<Activity<Name>Binding, <Name>ViewModel>()` (base in `app/src/main/java/io/legado/app/base/VMBaseActivity.kt`). Binding is inflated automatically; access views via `binding.`.
- **Fragment**: extend `VMBaseFragment<VM>(R.layout.fragment_...)` or `VMBaseFragment<VM>(layoutId)`.
- **ViewModel**: extend `BaseViewModel(application) : AndroidViewModel(application)` (`app/src/main/java/io/legado/app/base/BaseViewModel.kt`). Use its coroutine helpers (`execute {}`, `executeAsync {}`, etc.) for background work; don't launch raw coroutines from the UI layer.
- Layouts: `app/src/main/res/layout/`, XML only (View Binding). Menu XML in `res/menu/`, strings in `res/values/`.
- Package-by-feature under `ui/` (e.g. `ui/book/source/edit/`, `ui/book/read/`, `ui/association/`).

## Database (Room)

- DB class: `app/src/main/java/io/legado/app/data/AppDatabase.kt`.
- Entities: `app/src/main/java/io/legado/app/data/entities/` (e.g. `BookSource.kt`, `Book.kt`). Use `@Entity(tableName = ...)`, `@PrimaryKey`, `@ColumnInfo(defaultValue = ...)`, and `@TypeConverters` for objects that need GSON serialization (see `BookSource.Converters`).
- DAOs: `app/src/main/java/io/legado/app/data/dao/`. Prefer reactive Flow queries (e.g. `flowAll()`) over blocking `all` when the UI should observe changes. Register new DAOs in `AppDatabase`.
- Schema migrations: Room schemas live in `app/schemas/` (exported by KSP). When changing an entity, add an `autoMigrations`/migration entry and update the schema, or the installed app will crash with a migration error.
- App DB instance is accessed as `appDb` (see `App.kt`); `getDb()`/`appDb` pattern.

## Adding a feature end-to-end

1. Entity in `data/entities/` (+ `@TypeConverters` if nested objects).
2. DAO in `data/dao/` + register in `AppDatabase`.
3. ViewModel in the feature package extending `BaseViewModel`.
4. Layout XML + Activity (`VMBaseActivity`) or Fragment (`VMBaseFragment`) using the ViewModel.
5. Adapter if lists are shown (see existing `ui/.../...Adapter.kt` files; often `RecyclerAdapter`-based).
6. Wire navigation (intent with extras, or `callStartActivity`).
7. Register the Activity in `app/src/main/AndroidManifest.xml`.

## Key subsystems

- **Rule engine** (`model/analyzeRule/`): `AnalyzeRule`, `AnalyzeUrl`, `AnalyzeByJSoup`, `AnalyzeByXPath`, `AnalyzeByJSonPath`, `AnalyzeByRegex`, `RuleAnalyzer`. Used by all source scraping.
- **JS host** (`help/JsExtensions.kt`, `model/analyzeRule/AnalyzeUrl.kt`): the `java.*` object exposed to Rhino scripts; `modules/rhino/` wraps the Rhino engine with a class shutter.
- **Web server** (`web/HttpServer.kt`, `web/WebSocketServer.kt`): NanoHTTPD HTTP (port 1234) and WebSocket (port 1235) endpoints; API controllers in `api/controller/`.
- **HTTP client**: OkHttp wrappers in `help/http/`; `CookieStore.kt` handles cookie jar persistence.
- **Cache**: `help/CacheManager.kt` (exposed as `cache` in JS).
- **Storage/import**: `help/storage/`, `help/source/SourceHelp.kt` (insert/delete orchestration incl. 18+ blocklist), `ui/association/ImportBookSourceViewModel.kt`.

## Rules of thumb

- Match existing code style: 4-space indent, trailing commas, KDoc only where helpful. No new comments unless asked.
- Never commit `gradle.properties` signing keys or `app/gradle.properties`.
- Keep ProGuard rules updated in `app/proguard-rules.pro` / `app/cronet-proguard-rules.pro` for anything reflection-based (e.g. new Rhino-exposed classes, GSON models).
- The web module (`modules/web`) is a standalone Vue 3 app — do NOT wire it into Gradle; its build output is gitignored and synced in CI.
- Before finishing, run the relevant verification: `./gradlew lint` for Android code; `pnpm type-check` + `pnpm lint` inside `modules/web`.
