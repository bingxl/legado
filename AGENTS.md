# AGENTS.md

## Project Overview

Legado is an Android novel/ebook reader app (Kotlin). It includes a Vue 3 web UI sub-module for remote bookshelf/source management.

## Build Commands

### Android App (Gradle)
- `./gradlew assembleAppDebug` — debug APK
- `./gradlew assembleAppRelease` — release APK (requires signing keys in `gradle.properties`)
- `./gradlew clean` — clean build outputs
- Lint: `./gradlew lint`
- Cronet update: `./gradlew app:downloadCronet` (update `CronetVersion` in `gradle.properties` first)

### Web Module (modules/web)
- `cd modules/web && pnpm install` — install dependencies
- `pnpm dev` — dev server on port 8080 (requires running Android app as backend)
- `pnpm build` — production build (syncs to `app/src/main/assets/web/vue` in CI only)
- `pnpm type-check` — TypeScript type checking
- `pnpm lint:fix` — ESLint auto-fix
- `pnpm format` — Prettier formatting

## Architecture

### Modules
- `app/` — Main Android application (namespace: `io.legado.app`)
- `modules/book/` — Book model library (namespace: `me.ag2s`)
- `modules/rhino/` — Mozilla Rhino JavaScript engine wrapper (namespace: `com.script`)
- `modules/web/` — Vue 3 web UI (standalone, not part of Gradle build)

### Key Directories in app/
- `ui/` — Activities, Fragments, Adapters (MVVM pattern)
- `data/` — Room database, DAOs, entities
- `model/` — Book parsing, source rules
- `help/` — Utilities, crypto, network
- `service/` — Background services
- `web/` — Built-in web server (NanoHTTPD)

### Build Variants
- Product flavors: `app` (standard)
- Build types: `debug` (suffix `.debug`), `release` (suffix `.release`)
- Version auto-generated: `3.{yy}.{MMddHH}` with versionCode = `10000 + git commit count`

## Conventions

- Kotlin with Java 17 toolchain
- Room database with KSP annotation processing (schemas in `app/schemas/`)
- View Binding enabled (not Compose)
- Dependencies managed via Gradle version catalog (`gradle/libs.versions.toml`)
- Commit messages follow Commitizen conventional format (`package.json` configured)

## Important Notes

- Do not commit `gradle.properties` signing keys or `app/gradle.properties`
- Mirror repositories in `settings.gradle` are commented out — do not uncomment for PRs
- Web module build output (`app/src/main/assets/web/vue`) is gitignored; only synced in CI
- ProGuard rules: `app/proguard-rules.pro` and `app/cronet-proguard-rules.pro`
