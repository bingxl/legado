# AGENTS.md

> **当前主线（2026-11-19 起）**：`legado-flutter/` —— 纯 Dart 内核 + Flutter 应用，
> 用 Flutter 全量重写原版 `app/`（Kotlin，119k 行）的全部功能。
>
> **仓库结构**：
> - `legado-flutter/packages/legado_core` —— 纯 Dart 内核（领域模型、书源规则引擎、持久化、服务层），
>   **禁止 import flutter**；由 `test/no_flutter_import_test.dart` 强制检查。
> - `legado-flutter/packages/legado_cli` —— CLI 宿主，可用 `dart run legado_cli:legado` 直接跑内核。
> - `legado-flutter/app` —— Flutter 应用（Android / Windows）。
> - `app/`、`modules/`、`cli/` —— Kotlin 原版 Android 工程与其 JVM CLI（保留，仍是语义基准）。
>
> **已从本分支移除**：`legado-go/`（Go 书源引擎）、`core/`（Go 业务层）、`hosts/`（Go 三宿主）、
> `desktop/`（Wails 桌面端）。旧的设计文档已归档到 `docs/archive/`。
> 遇到提到 desktop / hosts / `go build` / `wails3` / `task` 的历史资料，一律视为作废，仅作参考。
>
> 迁移计划、里程碑与功能缺口见 `docs/flutter-全量迁移规划.md`。

## Project Overview

Legado 是一个小说/电子书阅读器。当前以 Flutter 全量重写原 Kotlin 版 `app/` 的全部功能：
业务与非 UI 逻辑沉淀在纯 Dart 内核 `legado_core`，Flutter 应用只负责 UI 与平台通道。
原 Kotlin 工程 `app/` 与 `modules/web`（Vue 3 Web UI）仍保留，作为功能与语义的对照基准。

## Build Commands

### 构建环境（Java 25 / Gradle 9.2.1）

2026-11 起 Kotlin 侧统一用 **JDK 25** 构建，版本组合已实测通过（app APK、cli、Flutter APK）：

| 组件 | 版本 | 说明 |
|---|---|---|
| JDK | 25 | Gradle daemon 与所有编译任务都用它 |
| Gradle | 9.2.1 | Java 25 运行 Gradle 的最低要求是 9.1 |
| AGP | 8.13.2 | 8.x 末代；Gradle 9 上可用（官方只对 9.x 测 AGP 9.x，故不再往上） |
| Kotlin | 2.4.21 | 支持 Gradle ≤9.7 / AGP ≤9.3 |
| KSP | 2.3.12 | KSP2 独立版本号，与 Kotlin 版本解耦 |
| Dart / Flutter | SDK ^3.10.0 | `legado-flutter/pubspec.yaml` 钉住；Flutter 3.38.3 与 Gradle 9 兼容 |

- **daemon JVM 由仓库固定**：`gradle/gradle-daemon-jvm.properties`（`toolchainVersion=25`）。
  `JAVA_HOME` 指向别的版本也不会偷偷换 JDK；换机器只需装任一 JDK 25。
  该文件是手写的 —— `gradle updateDaemonJvm` 要求先在 `settings.gradle` 配 foojay 下载仓库，
  本项目不需要自动下载 JDK。Flutter 宿主 `legado-flutter/app/android/gradle/` 下有同名文件。
- **字节码目标不要跟着提到 25**：Android 模块（`app`、`modules/*`）必须保持
  `sourceCompatibility/targetCompatibility = 17` + `jvmTarget = JVM_17`。
  D8/AGP 8.x 不认 class file 69，dex 阶段会直接失败。
  注意 `jvmToolchain(25)` 会把 Kotlin 的默认 `jvmTarget` 也带到 25，必须显式钉回 17，
  否则报 `Inconsistent JVM-target compatibility ... (17) and (25)`。
  Kotlin 2.3 起 `kotlinOptions` 已移除，用 project 作用域的 `kotlin { compilerOptions { jvmTarget } }`。
- `cli` 是纯 JVM 模块，产物就是 **class file 69**，运行需要 JDK 25
  （`JAVA_HOME` 或 PATH 上的 java 必须是 25）。

### Flutter（主线）

`legado-flutter/` 是一个 pub workspace（根 `pubspec.yaml` 为 `legado_workspace`），
一个 lockfile 管 `packages/legado_core`、`packages/legado_cli`、`app` 三个包，避免版本漂移。

```bash
cd legado-flutter
dart pub get                         # workspace 统一取依赖
dart test packages/legado_core       # 纯 Dart 内核全量测试（不需要 Flutter）
dart run legado_cli:legado selftest  # CLI 冒烟；--help 看全部命令

cd app
flutter test                         # Flutter 应用测试
flutter analyze                      # 静态检查（要求 0 error）
flutter build apk --debug            # Android debug APK
flutter build apk --release
flutter build windows --release      # Windows 桌面
```

- 内核约束：`legado_core` 只能依赖纯 Dart 包，**不得出现 `flutter` / `dart:ui`**；
  新增依赖后跑 `dart test packages/legado_core/test/no_flutter_import_test.dart`。
- sqlite3 分平台取源（见根 `pubspec.yaml` 的 `hooks`）：Android 用 `third_party/sqlite`
  的 amalgamation 本地编译（系统 `libsqlite3.so` 不对应用开放）；其它平台用系统库
  （Windows 用 `winsqlite3.dll`），不下载、不编译。换机构建坑见 `docs/flutter-全量迁移规划.md` §八。
- 测试基线：**core 全量 `dart test` 全绿、app `flutter test` 全绿、`flutter analyze` 零 error**，
  改动后跑全量再提交。

### Android App — Kotlin 原版 (Gradle)

原版 `app/`，作为功能与语义基准保留。

- `./gradlew assembleAppDebug` — debug APK
- `./gradlew assembleAppRelease` — release APK (requires signing keys in `gradle.properties`)
- `./gradlew clean` — clean build outputs
- Lint: `./gradlew lint`
- Cronet update: `./gradlew app:downloadCronet` (update `CronetVersion` in `gradle.properties` first)

### Desktop CLI — Kotlin (cli/)

纯 JVM 模块，复用 `app/` 的书源规则引擎源码。注意与 Flutter 的 `legado_cli`（Dart）区分。
编译用 JDK 25、产物目标 25（class file 69），因此运行环境也必须是 JDK 25。

- `./gradlew :cli:run --args="selftest"` — verify CSS/XPath/JSONPath/JS rule execution on desktop JVM
- `./gradlew :cli:installDist` — build runnable distribution at `cli/build/install/legado-cli/bin/`
- CLI commands (run the built binary, or via `:cli:run --args="..."`):
  - `source add <file|dir>` / `source list` / `source show <name>` / `source remove <name>`
  - `search <keyword> [--source <name|all>] [--page n] [--json]`
  - `explore --source <name> [--kind <kind> | --url <url>] [--page n] [--list]`
  - `info|toc|content|download <bookUrl|index|bookName>` — index refers to the previous search/explore result
  - `download ... [--from n] [--to n] [--chapters 1,3,5-9] [--out dir] [--resume] [--jobs n]`
  - global: `--dir --jobs --retries --timeout --proxy --verbose --json --quiet`
- Data dir defaults to `~/.legado-cli` (`sources.json`, `last-search.json`, `cache/`, `books/`)
- Engine sources are synced by the `syncEngineSource` / `syncRhinoSource` `Sync` tasks into `cli/build/generated`; do not copy files by hand

### Web Module (modules/web)

- `cd modules/web && pnpm install` — install dependencies
- `pnpm dev` — dev server on port 8080 (requires running Android app as backend)
- `pnpm build` — production build (syncs to `app/src/main/assets/web/vue` in CI only)
- `pnpm type-check` — TypeScript type checking
- `pnpm lint:fix` — ESLint auto-fix
- `pnpm format` — Prettier formatting

## Architecture

### Modules
- `legado-flutter/packages/legado_core/` — 纯 Dart 内核：`domain`（模型）、`rules`（书源规则引擎）、
  `net`、`js`（QuickJS）、`store`（SQLite/DAO）、`service`（业务服务）、`format`、`kernel`。
- `legado-flutter/packages/legado_cli/` — Dart CLI 宿主，无 UI，直接调内核。
- `legado-flutter/app/` — Flutter 应用：`lib/features/{book,explore,reader,rss,search,settings,shelf,shell,source,tools}`、
  `lib/core`（路由等共享设施）；平台目录 `android/` / `windows/`。
- `app/` — Kotlin 主 Android 应用（namespace `io.legado.app`，语义基准）
- `modules/book/` — Book model library (namespace: `me.ag2s`)
- `modules/rhino/` — Mozilla Rhino JavaScript engine wrapper (namespace: `com.script`)
- `modules/web/` — Vue 3 web UI (standalone, not part of Gradle build)
- `cli/` — Kotlin Desktop JVM CLI；直接编译 `app/` 与 `modules/rhino/` 的规则解析源码，
  用最小 `android.*` / `androidx.*` 替身运行在 JVM。引擎源码不改，只重写外围基础设施。

### Key Directories in app/ (Kotlin 原版)
- `ui/` — Activities, Fragments, Adapters (MVVM pattern)
- `data/` — Room database, DAOs, entities
- `model/` — Book parsing, source rules
- `help/` — Utilities, crypto, network
- `service/` — Background services
- `web/` — Built-in web server (NanoHTTPD)

### Build Variants (Kotlin 原版)
- Product flavors: `app` (standard)
- Build types: `debug` (suffix `.debug`), `release` (suffix `.release`)
- Version auto-generated: `3.{yy}.{MMddHH}` with versionCode = `10000 + git commit count`

## Conventions

- **主线用 Flutter + 纯 Dart 内核**：新功能优先落在 `legado_core` / `legado-flutter/app`，
  Kotlin 侧只作为语义基准，不再新增功能。规则引擎语义以 Kotlin 原版为准。
- `legado_core` 禁止 import flutter（CI/测试强制）；内核与 UI 之间的调用走统一 RPC 入口。
- Kotlin 侧：JDK 25 toolchain，字节码目标 17（Android/D8 上限，见「构建环境」）。
- Kotlin 侧 Room database with KSP annotation processing (schemas in `app/schemas/`)。
- Kotlin 侧 View Binding enabled (not Compose)。
- Dependencies managed via Gradle version catalog (`gradle/libs.versions.toml`)。
- Commit messages follow Commitizen conventional format (`package.json` configured)。

## Important Notes

- Do not commit `gradle.properties` signing keys or `app/gradle.properties`。
- Mirror repositories in `settings.gradle` are commented out — do not uncomment for PRs。
- Web module build output (`app/src/main/assets/web/vue`) is gitignored; only synced in CI。
- ProGuard rules: `app/proguard-rules.pro` and `app/cronet-proguard-rules.pro`。
- Flutter workspace 只有一个 lockfile（`legado-flutter/pubspec.lock`），内核/CLI/应用共用，不要单独为某个包生成 lock。
- 平台相关的 sqlite3 来源配置写在根 `pubspec.yaml` 的 `hooks.user_defines.sqlite3`，改前先读 `docs/flutter-全量迁移规划.md` §八。
