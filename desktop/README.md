# Legado Desktop

基于 **Wails v3** 的 Legado 桌面阅读器：Go 后端承载全部业务逻辑，Vue 3 前端只负责呈现，
两者通过自动生成的 TypeScript 绑定通信。

## 技术栈

| 层 | 选型 | 说明 |
|---|---|---|
| 桌面框架 | Wails **v3.0.0** | 服务绑定 + 自动生成 TS 客户端 |
| 前端 | Vue 3 + TypeScript + Vite + Pinia + Element Plus | 与 `modules/web` 技术栈一致 |
| 存储 | SQLite（`modernc.org/sqlite`） | 纯 Go，无 cgo |
| 书源引擎 | `legado-go`（本地模块，经 `replace` 引入） | 规则引擎、搜索/发现/目录/正文 |
| EPUB | `github.com/raitucarp/epub` | MIT，Reader / Writer / Editor |
| WebDAV | `github.com/studio-b12/gowebdav` | 纯 Go 客户端 |

## 快速开始

```bash
# 首次：安装 wails3 CLI
go install github.com/wailsapp/wails/v3/cmd/wails3@latest

# 开发（热重载，自动重新生成绑定）
wails3 dev

# 生产构建 → bin/legado-desktop.exe
wails3 build            # 或 task build
```

前端包管理器固定用 **pnpm**（仓库里是 `pnpm-lock.yaml` + `node_modules/.pnpm` 布局）：
`Taskfile.yml` 的 `PACKAGE_MANAGER` 默认值已改为 `pnpm`，若强行用 npm 会报
`Cannot read properties of null (reading 'edgesOut')`。

### Windows 本机运行：为什么"双击打不开、必须以管理员身份运行"

**这是环境问题，不是应用 bug。** 本仓库位于 `C:\Users\<用户>\work` 下，`work`
目录上有一条显式的 `Mandatory Label\Low Mandatory Level:(OI)(CI)(NW)`
（外加 `Everyone` 的 `DENY(DELETE_CHILD)`），子目录和文件全部继承。Windows 创建
进程时会把新进程的令牌**降到镜像文件的完整性级别**，所以普通权限双击工作区里的
exe 得到的是 Low IL 进程：写不了 `%LOCALAPPDATA%` 下的 `app.log` / 数据库
（NO_WRITE_UP），WebView2 创建 controller 报 `800700aa`，进程随即退出。
以管理员身份运行得到 High IL，绕过上述限制，于是看起来像「程序要求管理员权限」，
实际与 UAC manifest（`asInvoker`）、签名、Defender CFA、数据目录 ACL 都无关。

对照实验：同一时刻、同一非提升会话，从 `desktop\bin\legado-desktop.exe` 启动
退出码 1 且 `app.log` 一字不增；把 exe 复制到工作区外启动则页面完整加载、日志正常写入。

**修复方式（构建链已自动处理）**：给产物文件本身设一条显式 Medium 标签即可，
**不需要管理员权限**，也不需要改动 `work` 目录（那会削弱工作区写保护）：

```powershell
task fix:il    # 手工补一次；build / ui:mcp / publish 都会自动调用
```

产物每次落地后都会重设标签（`build/windows/fix-integrity.ps1`），因为删除重建或
签名工具替换文件时会重新继承 Low 标签。

**备用入口**：把 exe 发布到工作区之外（默认 `%LOCALAPPDATA%\Programs\legado\`）：

```powershell
task publish        # 复制 + 顺手修源产物标签
task run:published  # 发布并启动（等价于在发布目录双击）
```

若确实要把整个工作区标签改回 Medium（会削弱写保护、可能被沙箱重新施加，谨慎，
需要管理员）：

```powershell
icacls "C:\Users\<用户>\work" /setintegritylevel (OI)(CI)M
```

另外：启动失败现在**不再静默**了——应用会把日志写到 `%LOCALAPPDATA%\legado-desktop\app.log`，
并在致命错误（如 WebView2 初始化失败）时弹出原生错误框。

### Windows 产物签名（可选，仅开发机）

`wails3 build` / `task build` 会自动调用 `build/windows/sign-dev.ps1`，用本机自签名证书签名。
首次需要以管理员身份配置一次（导入受信任根 + 把产物路径加入 CFA 允许列表）：

```powershell
# 管理员 PowerShell
pwsh -File build/windows/setup-dev-cert.ps1
```

- 证书在 `Cert:\CurrentUser\My`（主题 `CN=Legado Desktop Dev`，有效期 5 年），公钥导出为
  `build/windows/legado-dev-codesign.cer`。
- 指纹存在 `%USERPROFILE%\.legado-codesign-thumbprint`；也可用环境变量 `LEGADO_CODESIGN_THUMBPRINT` 覆盖。
- 没配置证书的机器（CI、他人）签名步骤会自行跳过，**不影响构建**。

**签名能解决什么、不能解决什么**（这块很容易误判成「签名没生效」）：

| 现象 | 签名 + 装根证书后 |
| --- | --- |
| `Get-AuthenticodeSignature` 显示 `UnknownError`/无法验证 | ✅ 变成 `Valid` |
| UAC 提示「未知发布者」 | ✅ 显示 `CN=Legado Desktop Dev` |
| Defender 受控文件夹访问拦写盘（事件 1123） | ✅ 不再拦（CFA 按发布者认人） |
| **SmartScreen「无法识别的应用」** | ❌ **照旧拦** |

SmartScreen 的应用信誉是**微软云端判定**：拿文件哈希 + 签名证书去查 app reputation，
查不到就判「无法识别」。它**完全不参考本机 `LocalMachine\Root` / `TrustedPublisher`**。
自签名证书在微软侧永远没有信誉记录，所以签多少次都一样。`wails3 build` 每次都重链接、
哈希全变，每次都算一个全新的未知文件。

要让本机双击直接跑，只有三条路：

1. **关掉本机「检查应用和文件」**（开发机最省事，代价是不再对下载的 exe 做信誉预警）：
   ```powershell
   # 管理员 PowerShell；-On 可恢复 Warn
   pwsh -File build/windows/smartscreen-dev.ps1 -Off
   ```
2. **每次点「更多信息 → 仍要运行」**：不动系统设置，但每次重建都得点一遍。
3. **买 OV/EV 代码签名证书**：分发给他人的唯一正解（EV 即时获得 SmartScreen 信誉，
   OV 需要累积下载量）。

把产物拷到别的机器时，先在那边导入公钥，否则会退化成「未知发布者」、MSIX 旁加载也会报
`0x800B0109`：

```powershell
# 那台机器的管理员 PowerShell
pwsh -File build/windows/trust-dev-cert.ps1 -CerPath .\legado-dev-codesign.cer
```

它同样不影响 SmartScreen。

修改 `api/` 下服务签名后，**必须**重新生成前端绑定（`frontend/bindings/` 为生成物，禁止手改）：

```bash
wails3 generate bindings -ts     # -ts 不能省，否则产出 .js
```

后端测试：

```bash
go test ./internal/...
```

## 已实现

- **书籍管理**：书架分组、列表、搜索、删除、移动分组、阅读进度
- **书籍导入导出**：TXT / EPUB / PDF / 漫画（zip、cbz、rar、cbr、7z、cb7、图片目录）；导出 TXT / EPUB
- **阅读器**：TXT·EPUB 正文渲染、漫画图片流、PDF 交 WebView 内置能力；目录、翻页、进度保存、字号调节
  - 翻页方式：底部按钮、点击阅读区左右各 1/3、键盘 `←` / `→`（中间 1/3 留给选词与滚动）
  - 网络书按 `ruleContent.nextContentUrl` 自动拼接正文分页：单链逐页跟进、多链并发抓取，
    撞上「下一章」链接即停，单章上限 50 页
  - 漫画源按图片流渲染：后端把正文里的 `<img>` 抽成图片列表，网络图片经 `/img/` 代理补齐 Referer
- **书籍详情**：封面、作者、分类、简介、阅读进度与完整目录；「继续阅读 / 从第一章开始」与一键复制书籍地址；
  从「发现」和「搜索」的列表点书直接进入（**只是试读，不会自动进书架**；详情页或退出阅读器时确认才入架），
  点任意章节跳到阅读器对应位置，返回时保留来源列表的状态
- **书源管理**：增删改查、启停、JSON 导入导出（兼容 Legado 备份格式）、**从 URL 导入**（地址指向含多书源
  的 JSON 文件，导入一次即止；想跟随远程更新请用「订阅」）、规则校验、搜索与发现、结果试读与入架
- **发现（探索）**：照原生 `ExploreFragment` 的两级结构实现——书源手风琴列表（每条 6px 圆角灰条、12px 行距，展开后缩进 8px 铺分类胶囊，同时只展开一个）→ 点分类整页进入书单（80×110 封面 + 触底自动加载），分类按需解析并缓存 10 分钟
- **WebDAV**：连接配置、连接测试、远端浏览、备份上传下载与删除
  - **从 WebDAV 选书导入**：在目录里逐层浏览、勾选文件或整个目录（目录会被递归展开），
    下载到 `<数据根>/webdav/...` 后自动解析入架；支持进度、取消与失败明细，
    已下载且未变更的文件不会重复传输
- **内容缓存（离线阅读）**：手动把章节正文与漫画图片落到本地，断网仍可正常翻章
  - 四种范围：当前章、剩余章节、缺失章节、整本；分卷标题自动跳过
  - 管理页按书汇总章数与占用空间，支持按章多选删除、按书清空、全部清空；删书时自动级联清理
  - 阅读器目录里已缓存章节显示绿点，全局进度条可随时查看/取消正在进行的任务
- **朗读（TTS）**：系统语音朗读文本章节，跨章节连续朗读、当前句高亮跟随；可调语速与音色，
  离开阅读器后仍继续播放

## 架构

分层与解耦约束见 **[ARCHITECTURE.md](./ARCHITECTURE.md)**，
真实调用链与页面跳转（20 张 Mermaid 图）见 **[ARCHITECTURE-FLOWS.md](./ARCHITECTURE-FLOWS.md)**。
核心是四条铁律：

1. `api/` 只做参数校验、调用与 DTO 转换，**不含业务逻辑**
2. `internal/app/` **禁止 import Wails**（业务可脱离 GUI 测试）
3. 领域实体不直接外泄，一律经 `internal/app/dto` 转换
4. 前端只有 `src/api/` 可引用 `frontend/bindings/`

## 关键设计决策

**书源以原始 JSON 持久化。** Legado 书源字段上百且随上游演进，
因此 `book_sources.raw` 存原文，仅把 `name/group/enabled/order` 冗余成列用于查询排序。
导入导出天然兼容 Legado 生态，上游加字段无需迁移表。

**发现页分类按需解析。** 部分书源的 `exploreUrl` 是一段要联网执行的 JS
（如 ESJ Zone 的分类榜单），进页面就全量解析会让首屏卡十几秒。
因此只在展开某个书源时才解析它的分类，结果按「书源 + 原始规则」缓存 10 分钟；
布局尺寸直接对齐原生 `item_find_book.xml` / `item_fillet_text.xml` / `item_search.xml`，
桌面端只额外加了列表居中限宽与标题栏分组筛选。

**缓存以「章节 URL」而非序号判定有效。** 目录随时可能增删章节，同一个 `index`
在两次抓取之间完全可能指向另一章，所以 `chapter_cache` 连 URL 一起存：
读取时 URL 比对不上就视为未缓存并重抓。这样不必做全量失效，
也不会出现「缓存的是旧第三章、读出来却是新第三章」的错位。

**漫画缓存落盘而非入库。** 一章上百张图若走 base64 存 SQLite，体积膨胀三分之一以上，
且每次读章都要把整章载入内存。改为下载到 `cache/chapter/<bookId>/<idx>/`，
数据库只存 `/local/...` 路径；写新版本前先删旧目录，任一张失败则整章回滚，
避免留下半套图片让阅读器渲染出断图。图片请求必须带书源 `scheme://host` 作 Referer，
否则多数图床直接 403。

**PDF 不在 Go 侧解析。** 安卓端 PDF 本质是按页渲染的位图（无文本层）；
桌面端交给 WebView（pdf.js 或内置 PDF 能力），既拿到真实文本层又避开 CJK CID 字体与 cgo 问题。
PDF 大纲由前端解析后经 `ReaderAPI.SyncOutline` 回写。

**漫画图片必须走 `/img/` 代理。** 漫画图床普遍校验 Referer，`<img src="https://cdn...">`
发出的 Referer 是应用自身（`wails://`），会被判盗链直接 403（实测漫蛙的图床：无 Referer 403、
带站点域名 200）。因此后端提供 `/img/<base64url(图片地址 + "\n" + 书源地址)>[.ext]`，
用书源的 `scheme://host` 作 Referer 转发，只放行 http/https，并把图片内容交给 WebView 缓存一天。

**本地资源与图片代理的参数一律走路径段，不要用查询串。** 安卓宿主的资源拦截器
（`WebViewAssetLoader.PathHandler`）只把路径交给 Go，查询串在到达后端前就丢了：
`/raw/?p=<路径>` 到后端时 `p` 为空 → 400 → 安卓侧把非 200 当成「找不到资源」返回 `null`
→ WebView 回落到真实网络 → 域名不存在，前端只能看到 `Failed to fetch`
（曾导致安卓端「从文件导入书源」失败）。现统一为 `/raw/<base64url(绝对路径)>[.ext]`，
末尾保留扩展名是因为安卓侧按路径扩展名定 Content-Type（PDF 靠它才能内嵌预览）。
旧 `?p=` / `?u=&src=` 写法仍兼容，仅桌面端可用。

**书源 JS 扩展按「实际会用到」补齐。** 引擎用 goja 模拟 Rhino：`java.*` 是显式实现的扩展对象，
没有 Java 运行时。漫画源（如漫蛙）会把章节图片清单用 AES 加密后塞进页面，
需要 `base64DecodeToByteArray` / `hexDecodeToByteArray` / `bytesToStr` / `createSymmetricCrypto`
以及 `Packages.java.util.Arrays.copyOfRange` 一整套才能解开；字节数组统一用「数字数组」表示，
这样 `buf.length`、`buf[i]` 与 Rhino 的 Java byte[] 行为一致。
另有一类坑：页面里的 base64 常被 JS 转义成 `\/`、`\u002b`，浏览器解析字符串字面量时会还原，
引擎拿到的是原文，所以解码前先过一遍 `util.UnescapeJSString`。

**漫画图片走本地路由而非 base64。** 压缩包解压到缓存目录后以 `/local/...` 提供，
避免把整本漫画塞进内存。

## 开发辅助：bookprobe

`cmd/bookprobe` 对本地书籍做端到端解析探测，绕过 UI 与数据库直接验证解析器，
用于快速定位"某本书打不开/目录乱/封面坏"这类问题。

```bash
go build -o bin/bookprobe.exe ./cmd/bookprobe

bin/bookprobe.exe 一本.epub                  # 元数据 + 目录预览
bin/bookprobe.exe -chapter 3 一本.epub       # 另读第 3 章正文
bin/bookprobe.exe -chapter 10,11,12 一本.epub  # 连读多章，可观察翻页开销
```

## UI 测试（Wails v3 MCP 模式）

Wails v3 带一个**实验性**的 MCP 服务，能把运行中的 WebView 交给 AI 代理驱动。**桌面端 UI 的验证统一走这条路**，
不再用 Playwright / 自写截图工具 / 临时脚本（旧的 `tmpshot` 已删）。

```bash
task dev:mcp          # 等价于 WAILS_MCP=1 wails3 dev
```

- `WAILS_MCP=1` 让 wails3 CLI 追加 `mcp` 构建标签（也可直接 `wails3 build -tags mcp`），
  应用内 MCP 服务被编进二进制，`App.Run()` 时自动启动；**不加标签时是无操作的空实现**，
  连不上端点先检查环境变量而不是代码。
- 端点 `http://127.0.0.1:9099/mcp`，Streamable HTTP。可调环境变量：`WAILS_MCP_PORT`（0 = 随机端口）、
  `WAILS_MCP_HOST`、`WAILS_MCP_TOKEN`（仅非 loopback 绑定时必需）、`WAILS_MCP_TIMEOUT`（JS eval 毫秒，默认 30000）、
  `WAILS_MCP_HIDE_CURSOR=1`（隐藏动画指针，便于快照）。
- 客户端注册（以 Claude Code 为例）：`claude mcp add --transport http wails-legado http://127.0.0.1:9099/mcp`
- 工具集：`app_info`、`windows_list`、`window_control`、`js_eval`、`dom_html`、`dom_query`、`screenshot_dom`、
  `mouse_move`、`mouse_click`、`mouse_drag`、`mouse_scroll`、`keyboard_type`、`keyboard_press`、
  `call_bound_method`、`emit_event`、`wait_for_event`。
- 约定：断言用 `dom_query` / `js_eval`，不靠肉眼看图（`screenshot_dom` 给的是**结构快照**不是位图）；
  点击优先传选择器而非像素坐标；造数据用 `call_bound_method` 直接调 Go 服务，只有被测流程本身才走真实点击；
  等待用 `dom_query` / `wait_for_event` 轮询状态，不要固定 sleep；同一时间只跑一个实例（端口 9099 会冲突）。
- `mcp` 标签只用于开发/测试：`task build` 的生产链路不带它，别把标签加进 Taskfile 默认值或发布构建。

> `wails3 mcp` 子命令是另一个服务：它暴露的是项目生命周期工具（`wails_project_build`、
> `wails_project_dev_start`、`wails_project_task_run`、`wails_job_status` 等），看不到也点不到窗口。
> 测 UI 用 `WAILS_MCP=1` 起应用。

## 真机回归测试

EPUB 体积大且不便入库，因此针对真实书籍的回归默认关闭，
设置样本目录后启用（会遍历其中所有 `.epub`）：

```bash
LEGADO_EPUB_SAMPLE_DIR=~/Downloads go test ./internal/adapter/bookparser -run TestRealEPUBSamples -v
```

它校验解析不报错、章节均有标题与定位、首末章正文非空。
构造样本发现不了的问题（畸形文件引发 panic、封面被声明为损坏文件等）都靠它兜住。

## 安卓端构建（Windows）

安卓端与桌面端共用同一套 Go 业务层与 Vue 前端，宿主工程在 `build/android/`（applicationId
`cn.bingxl.legado`）。所有安卓任务定义在 `build/android/Taskfile.yml`，经根 `Taskfile.yml`
以 `android:` 命名空间引入，**统一在 `desktop/` 目录下执行**。

### 环境要求

| 依赖 | 说明 |
|---|---|
| JDK 17+ | `assemble:apk` 会检查 `java` / `JAVA_HOME` |
| Android SDK | 设 `ANDROID_HOME`（或 `ANDROID_SDK_ROOT`），需含 platform-tools（adb） |
| Android NDK | 设 `ANDROID_NDK_HOME`，或装在 `<SDK>/ndk/` 下（任务自动取版本号最新的一个） |
| go-task、wails3、pnpm | 与桌面构建相同 |

### 环境依赖纪律：不依赖 Git Bash / 执行环境

所有 Taskfile 只依赖 **go-task 内置 sh**（`mkdir/rm/cp/mv/ls` 等文件操作与 shell 语法均为
内置实现）+ **go-task 模板**（`OS`/`ARCH` 解析期展开）+ 显式声明的工具（go/pnpm/adb/pwsh）。
gosh **没有** `uname/awk/sed/grep/chmod/seq/sleep` 这些命令——它们来自 Git Bash 等执行环境，
曾在纯 pwsh/System32 环境下让构建静默失败（`uname -s` 求值变空）。因此：

- 平台判定用 `{{if eq OS "windows"}}` 模板，不用 `uname`；
  gradlew 在 Windows 上由模板直接展开为 `cmd /c gradlew.bat`（gosh 执行不了 `./gradlew`）
- NDK 的 Windows 工具链用 `windows-x86_64` + `aarch64-linux-android21-clang.cmd`
  （无扩展名 clang 是 bash 脚本，cgo 的 `exec` 跑不了）
- 文本/设备解析用纯 sh（`case`/`while read`/参数展开/算术）；复杂逻辑抽成 pwsh 脚本
  （`build/android/scripts/vd-shot.ps1`、`build/scripts/vendor-puppertino.ps1`）
- `chmod +x ./gradlew` 仅 POSIX 分支执行（Windows 无 exec 位概念）

Windows 还有两个坑已在任务里兜住，无需手工干预：`main_android.go` 由
`wails3 android overlay:gen` 生成到 `build/android/.overlay/`（点开头目录，Go 工具链不扫描），
不要手写、也不要在 `build/android/` 下留模板副本；SDK/NDK 定位依次取
`ANDROID_HOME` → `ANDROID_SDK_ROOT` → 各平台默认路径。

### 常用命令

```bash
cd desktop

# 一条龙：构建（Go→libwails.so + 前端）→ Gradle debug APK → 装到真机并启动
# 注意：run:device 会先卸载旧版，书架/书源等应用数据全部清空
task android:run:device

# 迭代开发首选：构建 + 打包 + adb install -r -d 覆盖安装（保留应用数据）
task android:update:device

# 只构建不部署
task android:build ARCH=arm64        # 编译 libwails.so（默认取宿主架构；真机用 arm64）
task android:assemble:apk            # Gradle debug APK → bin/legado-desktop.apk
task android:package                 # 生产 release APK（默认 arm64；模拟器加 ARCH=amd64）
task android:package:fat             # 全架构 fat APK（arm64 + amd64）
task android:bundle                  # 生产 AAB（Play 商店上传用）
task android:bundle:fat              # 全架构 AAB
```

发布 AAB 默认用 debug keystore 签名（仅本机验证用）；正式上传前需设置
`ANDROID_KEYSTORE_FILE` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD`。

### 设备与调试

```bash
task android:device:list       # 列出在线设备/模拟器序列号
task android:deploy-device     # release APK 装真机（先卸载，数据清空）
task android:deploy-emulator   # release APK 装模拟器（无 AVD 时自动用已装系统镜像创建）
task android:logs              # logcat（过滤 Wails / 应用名）
task android:studio            # 用 Android Studio 打开 build/android
task android:icons             # 从 build/appicon.png 重生成各密度启动图标
task android:clean             # 清理 bin/、Gradle 产物、jniLibs 的 libwails.so
```

多设备时用 `DEVICE_ID=<serial>` 指定目标（如 `task android:update:device DEVICE_ID=abcdef`）。

### 真机 UI 验收

见下节「安卓端测试」，走 scrcpy 虚拟显示：`task android:vd`（开窗口）/
`task android:vd:shot`（无窗口抓帧到 `bin/vd-shot.png`），要求 scrcpy >= 3.3.3。

### 已知问题

- Gradle wrapper 直连官方发行版地址可能卡住：可手动从腾讯云镜像
  （`https://mirrors.cloud.tencent.com/gradle/`）下载对应版本 zip，
  放到 `~/.gradle/wrapper/dists/gradle-<版本>-bin/<hash>/` 下用 `jar xf` 解压
- 安卓 WebView 资源请求不带查询串（`/raw/`、`/img/` 参数必须编进路径段），
  详见下文「关键设计决策」

## 安卓端测试（adb + scrcpy 虚拟显示）

安卓 UI 的验收不碰手机主屏：scrcpy 用 `--new-display` 在手机上开一块**虚拟显示**，
应用跑在那块屏上，画面只出现在电脑的窗口里 —— 手机屏幕照旧，用手机的人不受打扰。

```bash
cd desktop
task android:update:device   # 构建 + 打包 + adb install -r（保留应用数据）
task android:vd              # 电脑上开窗口跑，手机不显示（Ctrl+C 结束）
task android:vd:shot         # 无窗口跑一遍，抓帧到 bin/vd-shot.png
```

- `update:device` 用 `install -r` 覆盖安装、**保留数据**；`run:device` 会先卸载，数据清空。
- 需要 scrcpy **>= 3.3.3**：更早的版本在 Android 16+ 上创建虚拟显示会崩
  （`AbstractMethodError: onDisplayAnimationsDisabledChanged`），任务里已做版本校验。
- `VD_SIZE` / `VD_DPI` 调尺寸（默认 `720x1280` / `320`）；`DEVICE_ID` 指定设备。
- 局限：虚拟显示上的 Activity 生命周期与主屏不同，验证通知、后台保活、返回键仍需真机主屏。
  细节与踩坑记录见根 `AGENTS.md` 的「Android Testing」。

## 已知限制

- 漫画压缩包支持 zip / cbz / rar / cbr / 7z / cb7，全部纯 Go 解压（rardecode + sevenzip），
  无需 cgo；扩展名与实际格式不符时按文件头识别
- EPUB 正文图片内联为 data URI（自包含但占内存），后续可改为按需路由
- 尚未实现：替换规则 UI、RSS、备份恢复界面、TTS 的 PDF 朗读与 HTTP 语音引擎
- 缓存仅由用户手动触发，不做后台自动预缓存；已缓存章节不会因书源规则更新而变化，
  只有章节 URL 变了（目录重排后同序号指向另一章）才判定失效并重新抓取
- WebDAV 只做备份上传下载，不自动覆盖运行中的数据库（需重启应用生效）
- WebDAV 导入是一次性拷贝：书目指向 `<数据根>/webdav/...` 的本地副本，
  之后远端改动**不会**自动同步到本地（重新导入同一路径会按文件大小与修改时间判断是否需要重新下载）
- WebDAV 导入不支持断点续传；中途取消会丢弃当前文件的 `.part`，已完成的书保留
- 底层 `raitucarp/epub` v0.5.1 有两处会 panic 的缺陷（`CoverBytes` 空指针、
  `Description` 未校验 nil 节点）。已用原始字节取封面 + 解析边界 recover 规避，
  升级该依赖后需重跑真机回归确认是否可移除兜底

## 平台构建说明

业务层（`internal/domain|port|app` 及各 adapter）**零 cgo**，已实测在
`CGO_ENABLED=0` 下可交叉编译 darwin/arm64、linux/amd64、windows/amd64。

但 **Wails v3 框架本身**在 macOS 需 Objective-C 工具链、在 Linux 需 GTK4/WebKitGTK，
因此完整应用无法从 Windows 交叉编译到这两个平台——需在对应系统上构建。
这是框架约束，与业务代码无关。
