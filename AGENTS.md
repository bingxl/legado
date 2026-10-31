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

### Desktop CLI (cli)
Pure-JVM module that reuses the book-source rule engine sources from `app/`. Requires JDK 17+.
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

### Desktop App (desktop/)
Wails **v3.0.0** — Go backend + Vue 3/Vite frontend (pnpm), business logic in `internal/{domain,port,app,adapter}`.
- `cd desktop && wails3 dev` — dev mode (Vite on port 9245, hot reload); `task dev` is the same
- `cd desktop && wails3 build` — production binary at `desktop/bin/legado-desktop.exe`
- `wails3 generate bindings -ts` after changing anything under `desktop/api/` (bindings are generated; never hand-edit)
- `go test ./internal/...` — backend tests; `go build -tags mcp ./...` — sanity-check the MCP build compiles
- `internal/app/` must never import Wails, so business logic stays GUI-testable

#### Android (same Wails project, `desktop/`)
安卓端复用 `desktop/` 的 Go 业务层与 Vue 前端，只有宿主不同（applicationId `cn.bingxl.legado`，
改包名要同时改 `desktop/build/android/app/build.gradle` 与根 `desktop/Taskfile.yml` 的 `android.vars.APP_ID`）。
- `cd desktop && task android:build ARCH=arm64` — 用 NDK 把 Go 编成 `libwails.so`（含嵌入的前端产物）
- `task android:assemble:apk` — Gradle 打 debug APK → `desktop/bin/legado-desktop.apk`
- `task android:icons` — 从 `build/appicon.png` 重生成各密度启动图标（含圆形与自适应图标）。
  安卓图标不是手改 PNG：脚本 `build/android/scripts/gen-icons.py` 是唯一入口，改了应用图标就跑一次
- `task android:run:device` — 装到真机并启动；`task android:run` — 装到模拟器
- `task android:logs` — adb logcat（过滤 Wails/应用）；`task android:studio` — 用 Android Studio 打开工程
- 平台差异只写在 `platform_desktop.go`（`!android`）与 `platform_android.go`（`android`），`main.go` 不得出现 GOOS 分支
- `main_android.go` 由 `wails3 android overlay:gen` 自动生成，**不要手写**；`build/android/main_android.go` 这份模板副本必须删除，否则 `go build ./...` 报 `undefined: main`
- 业务层须始终满足 `GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build ./internal/... ./api/...` 通过
- **安卓端 WebView 的资源请求带不上查询串**：宿主用 `WebViewAssetLoader.PathHandler` 拦截
  `https://wails.localhost`，它只把路径交给 Go，`?p=` / `?u=&src=` 在到达 `assetHandler` 前就丢了。
  所以 `/raw/` 与 `/img/` 的参数一律编进路径段（`base64url`，见 `desktop/asset_url.go` 与
  `frontend/src/utils/assetUrl.ts`），末尾保留扩展名给安卓侧定 Content-Type。
  写错的表现很有迷惑性：安卓端返回 400/404 会被 Wails 转成 `null`，WebView 回落到真实网络，
  前端只看到 `Failed to fetch`（「从文件导入书源」失败就是这么来的）。
- **安卓端 SQLite 没有临时目录可用（disk I/O error 6410）**：modernc sqlite 在大结果集
  `ORDER BY` 溢出内存时要写临时文件，找目录依次试 `SQLITE_TMPDIR`/`TMPDIR`/`/var/tmp`/
  `/usr/tmp`/`/tmp`，安卓进程里全都不存在也不可写 → `SQLITE_IOERR_GETTEMPPATH (6410)`。
  `platform_android.go` 的 `dataDir()` 已在打开数据库前 `os.Setenv` 补上
  `<getFilesDir>/../cache`。关键在于 modernc libc 的 environ 是**首次 getenv 时**才从
  `os.Environ()` 拍快照，而全进程只有 sqlite 会 getenv——所以任何新的环境变量读取
  （新依赖 modernc libc 的库）都可能让快照提前固化，改动时留意这一点。
- Windows 下 NDK/Gradle 有四个已知坑（gosh 的 `ls` 行为、`uname` 分支、clang 要用 `.cmd`、`gradlew.bat` 路径），修法见 `desktop/ARCHITECTURE.md` §11.5

### Web Module (modules/web)
- `cd modules/web && pnpm install` — install dependencies
- `pnpm dev` — dev server on port 8080 (requires running Android app as backend)
- `pnpm build` — production build (syncs to `app/src/main/assets/web/vue` in CI only)
- `pnpm type-check` — TypeScript type checking
- `pnpm lint:fix` — ESLint auto-fix
- `pnpm format` — Prettier formatting

## Desktop UI Testing — Always Use the Wails v3 MCP Mode

Wails v3 ships an **experimental MCP server** that drives the running WebView. It is the **only** sanctioned
way to test/verify the desktop UI: do not use Playwright, ad-hoc screenshot tools, or hand-rolled harnesses
for `desktop/` UI work. Anything that needs the app's real UI state (layout, navigation, clicks, form entry,
visual claims) goes through these MCP tools.

### Start it

```bash
cd desktop
task ui:mcp          # 推荐：前端产物 + 带 mcp 标签的生产构建 + 运行
```

> **不要用 `task dev:mcp`**（即 `WAILS_MCP=1 wails3 dev`）。dev 模式会把页面反代到 Vite
> dev server，而 Wails 的 AssetServer 对 WebSocket 一律返回 501，Vite 的 HMR 客户端握手
> 失败后触发整页 reload 并循环往复 —— 窗口全白，且所有 MCP 探针超时。详见文末
> Troubleshooting。

- `WAILS_MCP=1` makes the CLI add the `mcp` build tag (`wails3 build -tags mcp` is equivalent), which compiles
  the in-app server into the binary; it starts automatically inside `App.Run()`. **Without the tag the server is
  a no-op stub** — if no endpoint responds, you forgot the env var, not the code.
- Endpoint: `http://127.0.0.1:9099/mcp` (Streamable HTTP).
- Env knobs: `WAILS_MCP_PORT` (default 9099, `0` = free port), `WAILS_MCP_HOST` (default `127.0.0.1`),
  `WAILS_MCP_TOKEN` (required only for non-loopback binds), `WAILS_MCP_TIMEOUT` (JS eval ms, default 30000),
  `WAILS_MCP_HIDE_CURSOR=1` to hide the animated cursor overlay when taking snapshots.

Register it once with the MCP client (Claude Code example, adjust for others):

```bash
claude mcp add --transport http wails-legado http://127.0.0.1:9099/mcp
```

### Tools

`app_info`, `windows_list`, `window_control`, `js_eval`, `dom_html`, `dom_query`, `screenshot_dom`,
`mouse_move`, `mouse_click`, `mouse_drag`, `mouse_scroll`, `keyboard_type`, `keyboard_press`,
`call_bound_method`, `emit_event`, `wait_for_event`.

### Rules of use

- Assert with `dom_query` / `js_eval` (read text, classes, counts, scroll position) — not by eyeballing pixels.
  `screenshot_dom` returns a *structural* snapshot, not a raster image; use it only when the claim is visual
  (spacing, overlap, truncation) and still back it with a DOM assertion where possible.
- Prefer selector arguments on `mouse_click` / `keyboard_type` / `mouse_scroll` over hard-coded coordinates;
  coordinates break the moment spacing changes.
- Set up fixtures through `call_bound_method` (call the Go service directly, e.g. import a book, add a source)
  instead of replaying long UI flows; reserve real clicks/typing for the flow actually under test.
- Guard against races by waiting on state (`dom_query` until the expected node appears, or `wait_for_event`)
  rather than sleeping fixed durations.
- Keep it single-instance: two running apps fight over port 9099. Use `WAILS_MCP_PORT` when you need a second one.
- **Never ship an `mcp` build.** The production path (`wails3 build` / `task build` without `WAILS_MCP`) does not
  include the tag; don't add it to Taskfile defaults or CI release builds.

> `wails3 mcp` (the CLI subcommand) is a **different** server: it exposes project-lifecycle tools
> (`wails_project_build`, `wails_project_dev_start`, `wails_project_task_run`, `wails_job_status`, …) for
> building/running the project. It cannot inspect or click inside a window. For UI testing use `task ui:mcp`.

### Troubleshooting: `unable to open database file (14)` at startup

If the app exits immediately with `设置 pragma 失败: unable to open database file (14)` (SQLite
`SQLITE_CANTOPEN`), Windows Defender **受控文件夹访问 (Controlled Folder Access)** is blocking
`bin/legado-desktop.exe` from writing into protected folders such as `%LOCALAPPDATA%`, so SQLite
cannot create `legado.db` and its `-wal` / `-shm` companion files.

Rebuilding changes the binary and re-triggers the block; signing with the dev self-signed
certificate (`task sign:dev`) does **not** clear it — CFA decides on reputation, not local trust.

Confirm: `Get-MpPreference` → `EnableControlledFolderAccess = 1`, and Defender event ID **1123**
("已阻止 … 通过"受控文件夹访问权限"修改 …").

Fix — once, from an elevated PowerShell (the entry is path-based, so it survives rebuilds):

```powershell
Add-MpPreference -ControlledFolderAccessAllowedApplications "C:\<repo>\desktop\bin\legado-desktop.exe"
```

Workaround without admin — point the data dir at an unprotected location:

```bash
LEGADO_DESKTOP_HOME=C:\<repo>\.devdata task dev:mcp
```

Note this starts with an empty library; the existing one lives in
`%LOCALAPPDATA%\legado-desktop\legado.db`.

### Troubleshooting: dev 模式白屏（`task dev:mcp` 窗口全白，MCP 探针全部超时）

症状：应用进程活着、窗口正常显示且标题正确、`MCP server started` 也打印了，但窗口内容全白；
`js_eval` / `dom_html` / `dom_query` / `screenshot_dom` 一律超时并报：

```
timed out after … waiting for the page to respond;
the window may be reloading, busy or showing a native dialog
```

根因是 **dev 模式 + WebSocket** 的组合，不是前端代码的问题：

1. `wails3 dev` 会设置 `FRONTEND_DEVSERVER_URL`，应用把页面反向代理到 Vite dev server
   （日志里 `AssetServer Info: … devServerURL=http://localhost:9245`）。
2. Wails 的 AssetServer 不支持 WebSocket：`internal/assetserver/common.go` 的
   `isWebSocket()` 命中后直接 `http.StatusNotImplemented`
   （`assetserver.go` 的 `serveHTTP` 第一行就是这个分支，早于任何用户 handler）。
3. Vite 的 `/@vite/client` 靠 WS 做 HMR；握手被 501 后客户端判定连接断开并触发整页
   reload，重载之后 WS 再次失败 —— 页面陷入无限重载，永远是"正在加载"状态。

判定方法（不需要读像素）：

- `app_info` / `windows_list` 正常（它们不进渲染进程），但任何需要页面执行的工具超时。
- 同一份二进制，只加 `FRONTEND_DEVSERVER_URL` 就复现，去掉就正常 —— 这是最干净的 A/B。

处理：UI 测试改用 `task ui:mcp`（构建前端产物 + 带 `mcp` 标签的生产构建 + 运行，不设
`FRONTEND_DEVSERVER_URL`），已验证 UI 完整渲染且探针可用。改前端后需重跑一次，没有热更新。

顺带一提，排查过程中容易踩的两个假线索：
- 残留的 `msedgewebview2.exe` 会锁住 WebView2 用户数据目录，导致下一轮启动报
  `800700aa`（resource in use）。换目录前先确认没有上一轮泄漏的实例。
- `CreateCoreWebView2Controller` 返回 `0x8000ffff` 多半是 WebView2 Runtime 155+ 在部分
  Intel 核显上的 GPU 回归；`main.go` 已默认带 `--disable-gpu`
  （可用 `LEGADO_WEBVIEW_ARGS` 覆盖）。

## Android Testing — adb 安装 + scrcpy 虚拟显示

安卓端的 UI 验收**不碰手机主屏**：用 scrcpy 的 `--new-display` 在手机上新建一块虚拟显示，
把应用启动到那块屏上，画面只出现在电脑的 scrcpy 窗口里。手机这边屏幕内容不变、在用的人不受打扰
（实测：虚拟显示上跑着 legado 时，主屏仍可正常显示微信等其它应用）。

这是安卓端唯一推荐的 UI 验收方式 —— 比投屏整机更干净（不影响用户），比模拟器更真实（真机 WebView、
真机 GPU、真机字体渲染）。

### 命令

```bash
cd desktop
task android:update:device     # 构建 .so + 打 APK + adb install -r（保留应用数据）
task android:vd                # 起虚拟显示窗口，应用在其中启动（阻塞，Ctrl+C 结束）
task android:vd:shot           # 无窗口跑一遍，抓一帧到 bin/vd-shot.png（自动化验收用）
task android:uninstall:device  # 卸载，连数据一起删掉
```

- 三者都可传 `DEVICE_ID=<serial>` 指定设备；不传则取第一台非模拟器设备。
  无线调试的 serial 长这样，**每次重连都可能变**，别写死：
  `adb-3e7de6d6-vSyHwu._adb-tls-connect._tcp`
- `VD_SIZE`（默认 `720x1280`）/ `VD_DPI`（默认 `320`）调虚拟显示尺寸；
  `VD_DPI=420` 更接近 1080p 手机的实际观感，`240` 相当于 720dp 宽（平板/分屏）.
- `vd:shot` 另有 `SEC`（默认 12 秒）。

### 安装 / 卸载 / 更新的分工

| 场景 | 命令 | 数据 |
| --- | --- | --- |
| 迭代验证（改了代码，书架要留着） | `task android:update:device` = `adb install -r -d` | **保留** `/data/data/<APP_ID>` |
| 干净重装（复现首次安装问题） | `task android:run:device` = 先 `uninstall` 再 `install` | **清空** |
| 只卸载 | `task android:uninstall:device` | **清空** |

`run:device` 会先 `uninstall` —— 这是它和 `update:device` 唯一的区别，也是最容易踩的坑：
以为只是换包，结果书源和书架全没了。想保留数据一律用 `update:device`。

### scrcpy 版本是硬门槛：>= 3.3.3

scrcpy **≤ 3.3.2 在 Android 16+ 上创建虚拟显示会直接崩**，服务端报
`AbstractMethodError: onDisplayAnimationsDisabledChanged`（Android 16 给
`IDisplayWindowListener` 加了方法，老版本 scrcpy-server 的实现没跟上），3.3.3 才修。
本机曾装 3.2，表现就是 `--new-display` 一跑服务端就挂、只有主屏被投出来。

`task android:vd*` 会读 `scrcpy --version` 做数值比较，低于 3.3.3 直接拒绝执行并给升级命令
（`winget upgrade --id Genymobile.scrcpy` / `brew install scrcpy`）。可用 `SCRCPY=<路径>` 覆盖。

### 实测踩过的坑（都会让结论反过来）

1. **`--record` 的相对路径以 go-task 的工作目录为准**。included taskfile 的 cmds 从 `desktop/`
   起跑（不是 `build/android/`，那个目录是 `assemble:apk` 里自己 `cd` 进去的）。写
   `../../bin/x.mp4` 会报 `Failed to open output file`。用 `bin/x.mp4`。
2. **`adb screencap` 抓不到虚拟显示**。它抓的是主屏（display 0），而虚拟显示是 scrcpy 建的、
   进程退出即销毁。要留证据只能用 `--record` 录下来再抽帧。
3. **不要按固定时间点抽帧**。scrcpy 只编码**变化**的帧，静止界面时视频很短，`-ss 5` 会因越界报
   `Output file is empty`；而末尾的帧又可能是黑屏（还没首帧渲染 / 显示正在销毁）。
   `vd:shot` 的做法是 `-sseof` 从末尾回退取 4 个候选帧，选**文件体积最大**的那张
   （纯黑 PNG 只有十几 KB，正常界面几十 KB 以上）。
4. **渲染时长依密度而变**：1080x1920/240 实测要 10 秒以上才出画面，8 秒录到的全是黑帧。
   所以 `vd:shot` 取不到内容时会自动把时长翻倍重试一次 —— 否则很容易把黑图误判成「页面没渲染」。
5. **虚拟显示退出后紧接着再建，偶发失败**（`Recording failed` / 起不来）。重跑一次即可，
   别去改代码。

### 什么时候**不要**用虚拟显示

- 需要验证真机的传感器、通知、后台保活、返回键行为 —— 虚拟显示上的 Activity 生命周期与主屏不同，
  这类结论不可信，必须真机主屏验证（`task android:run:device` 后手动操作）。
- 需要看多窗口/分屏/画中画 —— scrcpy 的虚拟显示是独立 display，不参与主屏的分屏。
- 需要跑 Wails MCP 探针（`task ui:mcp`）—— 那是**桌面端** WebView 的能力，安卓端没有对应实现。
  安卓侧能自动断言的只有 adb 侧证据（`dumpsys` / `logcat` / `vd:shot` 出的 PNG），没有 DOM 探针。

## Architecture

### Modules
- `app/` — Main Android application (namespace: `io.legado.app`)
- `modules/book/` — Book model library (namespace: `me.ag2s`)
- `modules/rhino/` — Mozilla Rhino JavaScript engine wrapper (namespace: `com.script`)
- `modules/web/` — Vue 3 web UI (standalone, not part of Gradle build)
- `desktop/` — Wails v3 desktop app (Go + Vue 3); consumes `legado-go` via a `replace` directive
- `legado-go/` — Go port of the book-source rule engine (rules, search/explore/toc/content, download); used by `desktop/` and its own CLI
- `cli/` — Desktop JVM CLI; compiles the rule-parser and Rhino sources straight from `app/` and `modules/rhino/` via `Sync` tasks, with minimal `android.*` / `androidx.*` stand-ins in `cli/src/main/kotlin`. Engine sources stay unmodified — only the surrounding infrastructure (HTTP, cookies, cache, `appDb`, `AppConfig`) is reimplemented for JVM

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
- Desktop UI changes are verified through the Wails MCP server (see *Desktop UI Testing* above), not by screenshots from external tools

## Important Notes

- Do not commit `gradle.properties` signing keys or `app/gradle.properties`
- Mirror repositories in `settings.gradle` are commented out — do not uncomment for PRs
- Web module build output (`app/src/main/assets/web/vue`) is gitignored; only synced in CI
- ProGuard rules: `app/proguard-rules.pro` and `app/cronet-proguard-rules.pro`
