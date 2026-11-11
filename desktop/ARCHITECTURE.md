# Legado Desktop 架构规范

> 本文是 `desktop/` 项目的**强制约束**。任何新增代码必须遵守，Code Review 以此为准。

## 1. 技术选型

| 项 | 选择 | 理由 |
|---|---|---|
| 桌面框架 | Wails **v3.0.0** | stable；`application.NewService` 自动生成 TS 绑定 |
| 前端 | Vue 3 + TypeScript + Vite + Pinia + Element Plus | 与 `modules/web` 技术栈一致 |
| 存储 | SQLite（`modernc.org/sqlite`） | **纯 Go**，保住 `CGO_ENABLED=0` 与全平台交叉编译 |
| 书源引擎 | 复用 `legado-go`（本地 `replace`） | 规则引擎已跑通，不重复造 |
| EPUB | `github.com/raitucarp/epub` | MIT，Reader/Writer/Editor |

---

## 2. 分层与依赖方向

```
                 ┌──────────────────────────────────────┐
   frontend      │  views / components / stores         │
                 │            ↓ 只用                     │
                 │  src/api  （防腐层，唯一引用 bindings）│
                 └───────────────┬──────────────────────┘
                                 │ wails bindings（自动生成，禁止手改）
   ──────────────────────────────┼──────────────────────────────────
                                 ↓
                 ┌──────────────────────────────────────┐
     api/        │  Wails 绑定层（极薄）                 │  ← 可 import wails
                 │  参数校验 · DTO 转换 · 错误包装        │
                 └───────────────┬──────────────────────┘
                                 ↓
                 ┌──────────────────────────────────────┐
     internal/   │  应用服务层（用例编排）                │  ← 禁止 import wails
     app/        │  dto/ 定义前后端契约                   │
                 └───────────────┬──────────────────────┘
                                 ↓ 依赖倒置：只面向接口
                 ┌──────────────────────────────────────┐
     internal/   │  端口 port/（接口）                    │  ← 零实现
     domain/     │  领域 domain/（实体 + 领域错误）        │  ← 零外部依赖
                 └───────────────┬──────────────────────┘
                                 ↑ 实现
                 ┌──────────────────────────────────────┐
     internal/   │  适配器 adapter/                      │
     adapter/    │  sqlite · bookparser · webdav · legado│
                 └──────────────────────────────────────┘
```

**依赖只能向下，禁止反向、禁止跨层。**

---

## 3. 目录职责

| 目录 | 职责 | 允许依赖 |
|---|---|---|
| `internal/domain/` | 领域实体、值对象、领域错误 | 仅标准库 |
| `internal/port/` | 端口接口（仓储、事件、外部服务） | `domain` + 标准库 |
| `internal/app/` | 用例编排、事务边界、DTO 定义 | `domain` + `port` |
| `internal/adapter/` | 端口的具体实现 | 全部（含第三方库） |
| `internal/platform/` | 数据目录、日志等平台能力 | 标准库 + xdg |
| `api/` | Wails 服务绑定（薄壳） | `app` + `dto` + wails |
| `main.go` | **组合根**：装配依赖、注册服务、建窗口 | 全部 |

---

## 4. 解耦铁律（硬性）

### R1 · `api/` 层不得包含业务逻辑
`api/` 只做三件事：**校验入参 → 调用 `app` 层 → 转换 DTO 并包装错误**。
禁止在 `api/` 里写 SQL、解析文件、编排流程、做格式转换。

```go
// ✅ 正确
func (s *BookService) ListBooks(groupID int64) ([]dto.BookBrief, error) {
    books, err := s.bookshelf.List(groupID)      // 业务在 app 层
    if err != nil { return nil, apperr.Wrap(err) }
    return dto.NewBookBriefs(books), nil
}

// ❌ 错误：业务逻辑泄漏到绑定层
func (s *BookService) ListBooks(g int64) ([]dto.BookBrief, error) {
    rows, _ := s.db.Query("SELECT * FROM books WHERE group_id=?", g) // 禁止
}
```

### R2 · `internal/app/` 不得 import Wails
应用服务层**不允许出现** `github.com/wailsapp/wails`。
需要向前端推送事件时，依赖 `port.EventBus` 接口，由 `adapter` 实现（Wails 版适配器放在 `api/` 或 `adapter/eventwails/`）。

> 目的：业务逻辑可脱离 GUI 做单元测试，也可被 CLI / server 模式复用。

### R3 · 领域实体不得直接暴露给前端
对外一律经 `internal/app/dto` 转换。避免数据库 schema 泄漏到 UI，也让 Go 侧重构不影响前端。

### R4 · 前端只有 `src/api/` 可引用 `bindings/`
组件、store、view 一律通过 `src/api/*.ts` 访问后端。`frontend/bindings/` 为**生成物，禁止手改**。

### R5 · 面向接口编程
`app` 层只依赖 `port` 接口，具体实现在 `main.go` 注入。便于测试替换（如内存仓储）。

### R6 · 错误语义化
- `domain/` 定义领域错误（`ErrNotFound`、`ErrInvalidArgument`…）
- `app` 层返回领域错误
- `api/` 层统一包装为**前端可展示的消息**
- 禁止把 Go 原始错误（如 `sql: no rows`）直接抛给前端

---

## 5. 命名约定

| 对象 | 约定 | 例 |
|---|---|---|
| 端口接口 | 名词，不加 `I` 前缀 | `port.BookRepository` |
| 适配器实现 | 包名体现技术 | `sqlite.BookRepo` |
| 应用服务 | `XxxService`，构造 `NewXxxService` | `app.BookshelfService` |
| DTO | 放 `dto` 包，`NewXxx()` 构造函数转换 | `dto.NewBookBrief(b)` |
| 绑定服务 | `api.XxxAPI` | `api.BookshelfAPI` |

---

## 6. 持久化策略

### 6.1 书源以「原始 JSON」持久化
Legado 书源有上百个字段且随版本演进。若做 ORM 映射，每次上游加字段都要改表。

**决策**：`book_sources.raw` 存书源 JSON 原文（与 Legado 生态完全兼容，导入导出即 JSON 数组），
仅把管理必需的字段（`name` / `group` / `enabled` / `order`）**冗余成列**用于查询与排序。
抓取时由 `adapter/legado` 将 raw 反序列化为 `legado-go` 的 `model.BookSource`。

替换规则、TXT 目录规则同理。

### 6.2 表清单
`books` · `book_groups` · `book_chapters` · `book_sources` · `source_subscriptions`
`replace_rules` · `txt_toc_rules` · `reading_progress` · `chapter_cache`
AI 相关（`004_ai.sql`）：`ai_chunks` · `ai_summaries` · `ai_index_state` · `ai_chats` · `ai_messages`
登录相关（`005_source_login.sql`）：`source_login`

---

## 7. 构建与开发

```bash
wails3 dev                        # 开发（热重载 + 自动重新生成绑定）
wails3 generate bindings -ts      # 手动重新生成 TS 绑定
wails3 build                      # 生产构建
```

修改 `api/` 下服务签名后**必须**重新生成绑定（`-ts` 不能省，否则产出 `.js`）。

---

## 8. cgo 边界（实测结论）

业务层**零 cgo**：`internal/domain`、`internal/port`、`internal/app` 以及全部
adapter（sqlite / bookparser / exporter / webdav / filesystem / legado）已在
`CGO_ENABLED=0` 下实测通过 darwin-arm64、linux-amd64、windows-amd64 三平台交叉编译。
SQLite 用 `modernc.org/sqlite`，EPUB、WebDAV、漫画解压（zip / rar / 7z，
`nwaples/rardecode` + `bodgit/sevenzip`）同样为纯 Go 实现。

**但 Wails v3 框架本身**在 macOS 依赖 Objective-C、在 Linux 依赖 GTK4/WebKitGTK，
因此**完整应用无法从 Windows 交叉编译到这两个平台**，需在对应系统上构建。
这是框架约束：引入新依赖时仍必须守住「业务层不引入 cgo」，否则会额外加剧构建复杂度。

## 9. 禁止事项清单

- ❌ 在 `api/` 写业务逻辑或直接操作数据库
- ❌ 在 `internal/app/` import Wails
- ❌ 手改 `frontend/bindings/`
- ❌ 前端组件直接 `import ... from '@/bindings/...'`
- ❌ 把 `domain` 实体直接作为绑定方法的返回值
- ❌ 引入任何需要 cgo 的依赖（会破坏 `CGO_ENABLED=0`）
- ❌ 用 Playwright / 外部截图工具 / 临时脚本验证 UI —— 桌面端 UI 测试统一走 Wails MCP 模式（`task ui:mcp`，见根 `AGENTS.md`）

## 10. 书源规则引擎的兼容性陷阱

书源是**为 Java 版 legado 写的**，规则字符串里隐含了大量 jsoup / Java 正则 / Rhino 的
行为假设。Go 侧重写时，下面几类差异不会报错，只会静默返回空结果——排查成本极高，
因此全部固化为「必须支持」的行为并配有回归测试：

| 陷阱 | 表现 | 正确做法 |
| --- | --- | --- |
| 分组选择器含非法子选择器 | 整条规则返回 0 个节点 | 按顶层逗号逐组求值，单组非法只跳过该组 |
| `li.col-4` 这类「标签+类」写法 | 被当成属性名，`NodeAttr` 取空 | 判定选择器时把 `.` `#` 也算作选择器特征 |
| JS 用 `result.parentNode()` | 抛 `parentNode is not a function`，标题空 → 0 章 | 节点包装需同时提供 `parent()` 与 `parentNode()` |
| 正则含 `(?<=` `(?!` | RE2 编译失败、规则静默失效 | 交 `dlclark/regexp2`（回溯引擎）编译；TXT 目录规则必需 |
| JS 里内嵌 `{{$.sid}}` | goja 报 `Unexpected token {` | 静态校验前先把 `{{...}}` 换成占位值 |

**判定原则**：任何「规则解析不出来」的路径都必须能报出**具体的规则串与原因**，
不允许以「列表为空」「正文为空」草草收尾——否则线上只能靠猜。

---

## 11. 安卓端（Android）

安卓端与桌面端**共用一套 Go 业务层和一套 Vue 前端**，只有宿主不同。
本节是新增平台能力时的强制约束。

### 11.1 复用边界（已实测）

`internal/{domain,port,app,adapter}` 与 `api/` 在 `GOOS=android GOARCH=arm64 CGO_ENABLED=0`
下**原样编译通过**，含 `modernc.org/sqlite`、书源引擎、WebDAV、漫画解压（zip/rar/7z）。
因此业务层**不得**为安卓新增分支——差异只允许出现在组合根。

平台差异集中在两个 build-tag 文件，`main.go` 里禁止出现任何 `GOOS` / `GOARCH` 分支：

| 文件 | 标签 | 提供 |
|---|---|---|
| `platform_desktop.go` | `!android` | `dataDir`（xdg / `LEGADO_DESKTOP_HOME`）、`windowOptions`、`windowsOptions`、`webviewBrowserArgs`、`safeAreaJSON`、`platformName` |
| `platform_android.go` | `android` | 同上，安卓实现 |

### 11.2 平台能力对照

| 关注点 | 桌面 | 安卓 |
|---|---|---|
| 数据目录 | `xdg.DataHome` | `application.Android.StoragePath()` = `Activity.getFilesDir()`，app 私有、无需存储权限 |
| 窗口 | 1200×780 + Mac 装饰 | WebView 铺满 Activity；`Width/Height/Title/Mac` 在 `webview_window_android.go` 里全是 no-op，**只给 `URL`**，别设无用字段误导读者 |
| 安全区 | 无 | `application.Android.SafeAreaJSON()`（`{top,bottom,left,right}`，像素） |
| WebView 参数 | `WebviewUserDataPath` + `AdditionalBrowserArgs` | 无此概念，返回零值 |
| 返回键 | — | `MainActivity.onBackPressed` 已处理：WebView 能回退就回退（正好配合前端 history 路由），否则退出。**不要**再自己接一套 |

`StoragePath()` 的调用时机是安全的：Java 侧 `onCreate` 先 `new WailsBridge(this)`，
`bridge.initialize()` 才经 JNI 调 `nativeInit`，后者先 `storeBridgeRef` 再 `go mainFunc()`。

### 11.3 入口：不要手写 `main_android.go`

c-shared 模式不会自动调 `main()`，需要 `application.RegisterAndroidMain(main)`。
这由 **`wails3 android overlay:gen` 自动生成** `build/android/.overlay/gen/main_android.gen.go`，
再通过 `.overlay/overlay.json` 虚拟注入到项目根（main 包），项目目录保持干净。

> 输出目录以 `.` 开头是**刻意的**：生成物是 `package main` 且引用 `main()`，
> 若落在普通目录下，`go build ./...` 会把它扫进来报 `undefined: main`。
> Go 工具链会跳过点/下划线开头的目录，因此必须放在 `.overlay/`。
> 改动 `generate:android:overlay` 的输出路径时，`compile:go:shared` 的
> `-overlay` 参数要同步改。

> ❌ 模板资产里带了一份 `build/android/main_android.go` 参考副本。它留在磁盘上会被
> `go build ./...` 当成 main 包的一部分，报 `undefined: main`。**生成后必须删掉**。

### 11.4 构建链路

```bash
wails3 generate build-assets ...   # 生成 build/android 全套 Gradle 工程（只需一次）
task android:build ARCH=arm64      # 编译 .so（含嵌入的前端产物）
task android:assemble:apk          # Gradle 打 debug APK → bin/legado-desktop.apk
task android:run:device            # 装到真机并启动（ARCH 固定 arm64）
task android:logs                  # adb logcat，过滤 Wails/应用
```

applicationId 用 **`cn.bingxl.legado`**（自有包名，与官方 legado 的 `io.legado.app` 并存不冲突）；
Java 源码仍在 `com.wails.app` 包下，两者不同是 Android 允许的，`am start` 用
`{{.APP_ID}}/com.wails.app.MainActivity`。改包名必须同时改 `build/android/app/build.gradle`
的 `applicationId` 与根 `Taskfile.yml` 的 `android.vars.APP_ID`。

### 11.5 Windows 构建的四个坑（都已修在 `build/android/Taskfile.yml`）

go-task 用**内置的 gosh**（`mvdan.cc/sh`）执行 `cmds`，不是系统 bash，行为有差异：

| 现象 | 根因 | 修法 |
|---|---|---|
| `Android NDK not found` | gosh 的 `ls <dir>` 回显**绝对路径**，而系统 bash 回显 basename；无条件拼接会得到 `…/ndk/C:\Users\…\29.0.x` | 先判 `ls` 结果本身是否为有效目录，是就直接用，不是才拼 |
| `Unsupported host OS` | 上游只认 `Darwin`/`Linux`；Git Bash 的 `uname -s` 是 `MINGW64_NT-*` | 补 `MINGW*|MSYS*|CYGWIN*` 分支 → `windows-x86_64` |
| cgo 报找不到编译器 | NDK 里无扩展名的 clang 是 **bash 脚本**，Go cgo 直接 exec 跑不了 | Windows 下 CC/CXX 用 `.cmd` 版本 |
| `'.' 不是内部或外部命令` / `gradlew.bat: executable file not found` | cmd 不认 `./` 前缀，gosh 又不会把当前目录加入 PATH | 用 `GRADLEW` 变量按平台切换 `./gradlew` / `cmd /c gradlew.bat` |

Gradle 发行版走 `services.gradle.org` 在本机会卡住。可从镜像手动下载后放进
`~/.gradle/wrapper/dists/gradle-<ver>-bin/<hash>/` 并用 `jar xf` 解压（JDK 自带），
wrapper 会直接复用；依赖仓库（Google Maven / Maven Central）直连正常，不需要配镜像。

### 11.6 cgo 边界

安卓宿主**必须** `CGO_ENABLED=1`（框架走 JNI）。这**不违反 §8**：
§8 约束的是「业务层不引入 cgo 依赖」，业务层依旧零 cgo，只是宿主构建开启 cgo。
新增依赖时仍须满足 `GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build ./internal/... ./api/...` 通过。

### 11.7 前端

平台判定**只信后端** `SystemAPI.Platform()`，前端不得用 userAgent 或视口宽度猜——
安卓分屏、平板、桌面窄窗口都会误判。结果集中在 `stores/platform.ts`：
`isMobile` 为真时外壳渲染底部 Tab（桌面渲染左侧栏），视图组件本身共用。
安全区经 `SystemAPI.SafeArea()` 取，给底部 Tab 加 `padding-bottom`、给内容区加 `padding-top`。

#### 11.7.1 布局预览：`?ui=mobile`

移动端外壳在真机之外本来看不到（桌面端永远返回 `desktop`），而 APK 装机看一眼的
反馈周期太长。因此在 `platform.ts` 留了覆盖开关：

| URL | 效果 |
| --- | --- |
| `?ui=mobile` | 强制按安卓端外壳渲染（底部 Tab） |
| `?ui=desktop` | 强制桌面外壳（左侧栏） |
| `?ui=auto` | 清除覆盖，交回后端判定 |

覆盖值写入 `localStorage`（键 `legado.ui.override`），刷新后仍生效。
**覆盖期间外壳顶部会显示提示条**并给出一键还原——否则在桌面端切成移动布局后刷新，
会误以为「安卓端本来就这样」。

`mobile` 是 `android` 的别名：对用户说「移动端布局」，内部仍按后端 `Platform()`
的取值命名，两者不混用（见 `normalize()`）。

有了这条链路，安卓端 UI 可以直接在 Windows 上验证：渲染的是与真机完全相同的组件
分支，差异只剩安全区数值与 `Platform()` 的返回值。回归脚本
`tmp-mcptest/s8_ui_parity.py` 同时覆盖两种外壳。

#### 11.7.2 窄屏适配的分工

- **横切规则**放在 `App.vue` 的非 scoped 样式里，只收两类最常见的溢出：
  内联固定宽度的控件（`style="width:300px"` 优先级高于选择器，只能靠
  `max-width:100% !important` 压住，只压上限，不影响小尺寸控件）与弹窗宽度。
- **逐页差异**由各视图自己的 `@media (max-width: 640px)` 处理。
- 新建页面一律用**卡片列表**而非 `el-table`：表格在 360px 下只能横向滚动，
  操作列会被挤出去；卡片在 360–1200px 都读得顺。

#### 11.7.3 功能入口的两档布局

桌面侧边栏放全部 10 个入口；移动端底部 Tab 只放 5 个（书架/发现/搜索/书源/我的），
替换规则、订阅、缓存、WebDAV 收进「我的」页，AI 则从**书籍详情的「AI 总结」Tab** 与
阅读器「问 AI」抽屉进入（移动端不需要第五个并列入口）。
**两端功能集合完全一致**，只是入口深度不同——这是刻意的：10 个 Tab 会让每个
不到 60px 宽，手指点不准。导航高亮用 `isActive()` 统一处理，子功能页仍点亮「我的」。

#### 11.7.4 阅读器本章进度条

底部导航条之上有一条 `ChapterProgress`（`components/ChapterProgress.vue`），
显示「本章 N%」，按住/拖动可直接滚到对应位置。

- **只做显示与换算**：组件把指针横坐标换成百分比抛 `seek`，滚到哪里由 `ReaderView`
  决定（文本 `.text`、漫画 `.comic` 是两个容器，PDF 的滚动归 iframe，谁能滚只有
  阅读器知道）。
- **拖动期间滑块跟本地值走**，不用父组件的 `percent`：父组件把百分比换算成
  `scrollTop` 时会被内容高度夹住（章节不足一屏、漫画图片还在懒加载），回流值低于
  手指位置，滑块会在手指底下往回跳。
- **落盘只在抬手**（`seek-end`）：`saveProgress` 是异步的，`pointermove` 一帧几十次
  会把请求堆起来。拖动中滚动位置变了但进度不写库，这是有意的。
- 换算公式集中在 `utils/chapterProgress.ts`（`percentFromScroll` /
  `scrollTopForPercent` / `percentFromX`），三处共用一份，避免「拖到 50%、松手跳到 47%」。
  **不足一屏的章节算 100% 并置灰不可拖**——整章都看得见，就是已读到头。
- `onScroll` 里进度条的刷新排在「朗读让位」判定**之前**：朗读期间不写进度库，
  但进度条要跟着朗读的自动滚动走。
- 位置在 `.stage` 与 `.nav` 之间，随 `chromeShown` 一起隐藏（移动端沉浸模式）。
  这一行只有 ~20px，是从正文可视高度里扣的，所以内边距/行高压到最小，
  别在顶栏里塞（`s22` 断言顶栏 ≤60px）。
- 回归：`tmp-mcptest/s23_reader_progress.py`（13 项，含真实 `mouse_drag` 与落库校验；
  书目动态挑，不依赖预置数据目录）+ `utils/chapterProgress.test.ts`。

#### 11.7.5 PC 全屏阅读

桌面端阅读器可把窗口切成全屏并让出左侧栏，正文拿到整屏空间。

- **沉浸判定两端共用一条表达式**：`stores/readerLayout.ts` 的
  `immersive = platform.isMobile || fullscreen`，`ReaderView` 里
  `chromeShown = !immersive || chromeVisible`。移动端 `immersive` 恒真，退化成原来的
  `chromeVisible`（行为一字未改）；桌面端非全屏恒真，只有全屏后才能点中间收起栏位。
  **别为桌面另写一套栏位逻辑**——两端同一条路径才不会在安卓上悄悄回归。
- **窗口能力走 `safeAreaFunc` 同款注入**：`api/system.go` 的
  `SystemAPI.SetFullscreen/IsFullscreen` 调 main 注入的函数，桌面实现在
  `platform_desktop.go`（`application.Get().Window.Current()` 的
  `Fullscreen()/UnFullscreen()/IsFullscreen()`），安卓在 `platform_android.go` 里是
  返回 false 的 no-op。`api/` 层因此仍然零 `GOOS` 分支，安卓端没有窗口层也不需要。
- **`SetFullscreen` 返回真实状态而不是回显入参**：窗口可能因平台限制或时序没切成，
  前端拿返回值回填，否则会显示"已全屏"而窗口没动。
- **系统级退出要对账**：用户用 Win+↓ / mac 绿灯退出全屏不经过我们的按钮。
  全屏切换必然伴随窗口 resize，所以 `readerLayout` 在 `resize`/`focus` 上去抖查一次
  `IsFullscreen()`——比订阅窗口事件少一条不可验证的依赖。
- **切换后按章内百分比还原位置**：窗口宽高变了，同一章的可滚动范围也变了，只留
  像素 `scrollTop` 会让人觉得"跳了一段"。记 `chapterPct`，等 `scrollHeight` 连续两次
  稳定（最多 8×60ms）再 `scrollTopForPercent` 写回，换算复用进度条那一套。
- **Esc 逐层退**：浮层 > 取词 > 收起栏位 > 退出全屏；`F11` 直接切换。
  离开阅读器（`onBeforeUnmount`）**必须** `setFullscreen(false, true)`，
  否则回到书架还是满屏且没有侧栏。
- 状态**不跨会话记忆**：启动即全屏会让人以为侧栏丢了。字号/行距那类偏好才进
  `readerPrefs`，全屏是临场姿态。
- 回归：`tmp-mcptest/s24_reader_fullscreen.py`（16 项，含真实窗口全屏切换与后端
  `IsFullscreen` 校验）。

#### 11.7.6 阅读器分层：外壳 + 窗格

阅读器拆成**外壳**（`views/ReaderView.vue`）与**单书窗格**
（`components/reader/ReaderPane.vue`）两层。M2 是纯重构、行为零变化；拆的理由是
分屏要同时渲染两本书——`book / chapters / content / index / chapterPct / tocVisible`
都是组件内的单例 ref，不搬进窗格就会互相覆盖。

| 层 | 负责 | 不负责 |
| --- | --- | --- |
| 外壳 | 路由（`:id` / `?index=` / `?hl=`）、返回、离开时的试读入架询问、全屏态挂载与对账、`DictPopover`（全局唯一） | 任何一本书的内容 |
| 窗格 | 加载详情/目录/正文、渲染（文本/漫画/PDF）、进度条、目录抽屉、取词与朗读会话、缓存任务、`AskAIDrawer` | 路由（`bookId` 由 props 给，右栏不从 `:id` 来） |

- **DOM 与类名原样保留**：外壳根仍是 `.reader`，窗格内部仍是
  `.bar / .stage / .text / .comic / .pdf / .nav / .toc / .chapter-progress`，
  所以 s3 / s6 / s13 / s22 / s23 / s24 的选择器一条都不用改——这是这次重构
  唯一可靠的"没改坏"判据。
- **窗格不读路由**：`bookId` / `startIndex` / `highlight` 全走 props。
  窗格内部仍保留 `boundBookId`（进入时固定），因为朗读会话在窗格卸载后
  还要继续拉章、写进度。
- **`active` 是分屏的前置约定**（单栏恒真）：键监听挂在窗格上但非活动栏直接返回
  （否则两栏抢方向键）；进度落盘也只在活动栏写，**变成非活动栏时补最后一笔**
  （两栏可以开同一本书，都写就是互相覆盖）。
- **字号/行距是模块级单例**（`utils/readerPrefs.ts` 的 `useReaderStyle`）：
  分屏两栏必须一致，各存一份 ref 会出现"只改了一半"。
- 回归：`tmp-mcptest/s25_reader_pane.py`（10 项，盯「拆组件时最容易漏接线」的路径：
  目录跳章 / 问 AI / 缓存下拉 / 字号滑块落盘 / 朗读启停 / 返回后章节不丢）。

#### 11.7.7 并排阅读（分屏）

桌面端同一屏并排读两本书：左栏仍是路由 `:id`，右栏是**查询串** `?split=`。

| query | 含义 |
| --- | --- |
| 无 `split` | 单栏（默认，行为与分屏功能之前完全一致） |
| `?split=0` | 已开分屏、右栏是空态选书面板（**不猜用户想读哪本**） |
| `?split=<id>` | 右栏读这本书 |

- **一律 `router.replace`**：分屏是视图状态，不该在历史栈里留一步（否则返回键要多按
  一次才回详情页）；`smartBack` 依赖 `history.state.back`，replace 不动它。
  好处是分屏态能熬过整页刷新，不再需要一份内存状态去持久化。
- **右栏可以不填**：点「分屏」先出空态面板（`components/reader/SplitPicker.vue`），
  选书来源**限书架内**（从搜索/发现点开的试读书想并排，先入架）——这条限制是为了
  让"离开时询问是否入架"继续"最多问一次"，不是产品洁癖。
- **允许两栏同一本书**（同书不同章对照是用户的明确用法）。代价只在进度写入上，
  由 active 约定解决：只有活动栏写 `saveProgress`，变成非活动栏时补最后一笔。
- **`active` 是分屏的唯一互斥开关**：方向键、Esc、进度落盘都看它。右栏还是空态时
  左栏必须继续算活动（`leftActive`），否则"开了分屏还没选书"的阶段键盘全死。
- **分隔条不能用 `setPointerCapture`**：本机 WebView2 上它不生效（实测指针一离开
  6px 的分隔条就收不到 `pointermove`，拖动只挪 2px 就断线）。改成拖拽期间铺一层
  透明遮罩（`.split-veil`）接管指针——遮罩在父文档里，既能盖住正文，也能盖住
  PDF 的 `iframe`（iframe 内的指针事件不冒泡到父文档，这正是当初想用 capture 的理由）。
  比例夹在 20%~80%：再窄正文就只剩几个字一行，拖不回来比拖不准更难受。
- **窄窗口自动收单栏**（<900px）：两栏各剩不到 450px 时正文没法读，留着不如退出；
  主动点「分屏」但窗口本来就不够宽时先提示，别"开了立刻被收"看起来像坏了。
- **移动端恒不分屏**：`splitOpen` 里带了 `!platform.isMobile`，安卓端 UI 零变化。
- 回归：`tmp-mcptest/s26_reader_split.py`（15 项：空态 / 两栏独立翻章 /
  只有活动栏吃键盘 / 拖分隔条 / Esc 关闭 / 窄窗自动收 / 移动端无入口）。

---

## 12. AI 总结与问答

设计取舍见仓库根 `desktopAI总结与问答设计方案.md`，这里是**实现约束**。

### 12.1 组成

| 层 | 位置 | 职责 |
| --- | --- | --- |
| domain | `internal/domain/ai.go` | `AIConfig` / `AIChunk` / `AISummary` / `AIIndexState` / `AIChat` / `AIMessage` |
| port | `internal/port/ai.go` | `LLMClient`（`Chat` / `ChatStream` / `Embed`）与四个仓储接口 |
| adapter | `internal/adapter/aihttp` | OpenAI 兼容协议：`/chat/completions`、`/embeddings`、SSE 解析 |
| app | `internal/app/ai*.go` | `ai.go` 配置、`ai_text.go` 切片、`ai_index.go` 索引与摘要链、`ai_retrieve.go` 召回装配、`ai_chat.go` 流式问答 |
| api | `api/ai.go` | 15 个绑定方法（配置 3 / 索引 6 / 会话 6；`Ask` 与 `StopAnswer` 立即返回，结果走事件） |
| 前端 | `api/ai.ts`、`stores/aiIndex.ts`、`stores/aiChat.ts`、`AIPanel` / `ChatPanel` / `AskAIDrawer` / `AIView` | 索引面板（书籍详情 Tab）、完整问答页、阅读器抽屉 |

### 12.2 为什么向量是 BLOB + 暴力余弦

`modernc.org/sqlite` 是纯 Go 实现，**不能加载 sqlite-vec / vss 这类原生扩展**（§8 的零 cgo 铁律的结果）。
所以 `ai_chunks.embedding` 直接存**小端 float32 BLOB**，检索时整本取出在 Go 里算余弦。
单本几十万字的切片量级是几百到几千条，暴力算完全够；换 ANN 索引要到十万级切片才需要考虑。
`emb_dim` 与当前配置不一致的向量会被跳过并计数，提示用户重建索引，而不是静默降质。

### 12.3 embedding 必须独立于 chat 配置

DeepSeek、Moonshot 这类兼容网关**没有** `/embeddings`。若把向量化绑死在主模型上，
配好这些服务后检索会整体失效。因此 `AIConfig` 里 embedding 有独立的
`EmbeddingBaseURL` / `EmbeddingModel` / `EmbeddingDim`，缺省留空。

留空时索引照常跑（只切片 + 摘要），问答走 bigram TF-IDF 关键词召回，
并在回答的 `Note` 里如实说明「未启用向量检索」。**降级必须可感知**，否则用户会以为 AI 变笨了。

### 12.4 摘要链按 token 预算打包，不按章节数

按「每 N 章归并一次」写会让 100 万字、两千章的书要发起上千次 chat 请求。
`groupByTokenBudget` 按 `aiSummaryGroupTokens`（6000）把待摘要单元打包，
每轮归并产出的上层摘要继续参与下一轮打包，递归到只剩 1 条，形成 map-reduce 树。

**进度分母必须累加**：每上升一层就产生新的工作量，`SummaryTotal += len(nextGroups)`。
早期只把分母设成第一层的条数，于是出现 `summaryDone: 23 / summaryTotal: 22` 这种荒谬比值——
进度条还会倒退。单测里保留了 `SummaryDone <= SummaryTotal` 的自洽断言守这条。

### 12.5 成本保护：正文没变就不重新花钱

- 向量：`ai_chunks.PutBulk` 用 `CASE WHEN src_hash = ?` 保留旧向量；
- 摘要：`summarizeLevel` 命中 `old.OK && old.SrcHash == hash` 直接复用。

`s10_ai_index.py` 用 mock 的 `/stats` 实测：重复建索引时 `chat 23→23`、`embed 7→7`，
即**一次也不额外调用**。改动前是每次重建都把全书重新摘要一遍。

### 12.6 长任务范式（与内容缓存一致）

索引可能跑几分钟，不能挂在请求 ctx 上（绑定方法一返回 ctx 就取消了）：
`context.WithCancel(context.Background())` 派生 + goroutine + `port.EventBus.Emit` 推进度，
单书一把互斥锁，`doneCh` 等 goroutine 真正退出（取消后才算结束，避免状态机撕裂）。
`IndexStatus` 每次都从库里读，前端刷新页面也能接上正在跑的任务。

### 12.7 中止语义三态

流式回答被中止时三种情况要分开处理，否则会出现「助手气泡是空的还留在库里」：

| 情况 | 状态 | 落库内容 |
| --- | --- | --- |
| ctx 取消（用户点停止） | `canceled` | 保留已生成的部分 |
| 已经出了内容后出错 | `failed` | 保留内容 + 错误说明 |
| 一个字都没出就失败 | `failed` | **不写助手消息** |

### 12.8 两个前端坑（都会表现成「功能完全不工作」）

1. **事件订阅必须走 `window.wails.Events`，且要等它注入完成。**
   `@wailsio/runtime` 打包副本的 `Events` 与宿主是两套注册表，用它能编译、能 `On`，
   但**永远收不到后端事件**。而 `window.wails` 的注入时机晚于应用脚本首屏执行。
   早先 `subscribe()` 只等 5 秒就退回打包副本兜底——冷启动稍慢的机器上，AI 回答一个字都不显示。
   现在改为「先挂兜底 + 最长等 60 秒 + 真身出现立即迁移订阅」，`aiChat` store 另有
   2 秒轮询从库里回填，`AIAnswerDone` 还带完整正文用于覆盖丢分片的会话。
2. **引用高亮要忽略空白做匹配。**
   切片文本的空白被归一化过（全角空格→普通空格、连续空白折叠），正文渲染的是原始 HTML，
   同一句话两边空白往往不同，直接 `indexOf` 会「明明有这段却高亮不上」。
   `ReaderView.highlightQuery()` 两边都去掉空白再比，再用下标映射还原真实位置后插 `<mark>`。

### 12.9 回归用例

| 脚本 | 覆盖 |
| --- | --- |
| `tmp-mcptest/s9_ai.py` | 配置读写、连接测试、错误提示（16 项） |
| `tmp-mcptest/s10_ai_index.py` | 索引全流程、进度、取消、成本复用、删除（23 项） |
| `tmp-mcptest/s11_ai_chat.py` | 提问流式回答、引用、跳章高亮、会话落库（17 项） |

三者已并入 `run_all.py`，且 `run_all.py` 会自动拉起 `mockai.py`（端口已有实例则复用），
不再需要手工开第二个窗口。

---

## 13. 书源 / 漫画源登录

登录是「能读多少书」的开关：账号型书源不登录，搜索直接被登录墙挡住，
详情/正文也全是「请先登录」。本功能对齐 Kotlin 原版
（`ui/login/*` + `BaseSource.login()/putLoginHeader()`），但受桌面端宿主限制，
走了一条与原版不同、效果等价的路。

### 13.1 与原版的对应关系

| 原版（Android） | 桌面端 | 说明 |
| --- | --- | --- |
| `SourceLoginDialog`（`loginUi` 表单） | `SourceLoginDialog.vue` | 按 `RowUi` 渲染 text / password / button |
| `BaseSource.login()`（跑 `loginUrl` 的 `login()`） | `Loginer.RunLoginJS(CallLogin=true)` | 用 goja 执行，绑定同原版（`source` / `java` / `cookie` / `baseUrl`） |
| `SourceLoginActivity` + `WebViewLoginFragment` | **不实现**，改为「浏览器打开登录页 + 粘贴 Cookie」 | 见 13.3 |
| `putLoginHeader(json)` | `SourceLoginService.SaveHeader()` | 支持 JSON / 请求头行 / 裸 Cookie 三种粘法 |
| `CookieStore`（进程内 + 可落盘） | `legado-go/pkg/store` + `cookies.json` | 同一套，抓取/图片请求自动带上 |
| `loginCheckJs` | `Loginer.Probe()` | 语义见 13.5 |

### 13.2 三条登录路径与判定

判定只读书源字段，不联网（`Loginer.LoginKind`）：

| `loginUrl` | 判定 | 行为 |
| --- | --- | --- |
| 空 | `none` | 只能手动粘贴 Cookie |
| `@js:` / `<js>` 开头，或一段裸脚本 | `js` | 渲染 `loginUi` 表单 → 执行脚本 → Cookie 落地 |
| `http(s)://`、`/`、`./`、`../` 开头 | `page` | 打开浏览器登录 → 用户粘贴 Cookie |
| 其它 | `js` | 与原版 `getLoginJs()` 一致（不写前缀也当脚本） |

**`login()` 必须被调用**：书源脚本普遍写成

```js
var info = source.getLoginInfoMap();
function login() { java.post(baseUrl + '/login', 'user=' + info['账号'] + ...); }
```

直接执行脚本体只会定义函数、什么都不做——表现就是「点登录毫无反应」。
所以 `CallLogin=true` 时统一包一层 `if (typeof login==='function') login.apply(this)`。
而 `loginUi` 里自定义按钮的脚本**不能**这么包（它本身就是动作片段），
`CallLogin=false` 且把表单塞进 `result`（原版是 `loginJS + buttonJS` 拼接）。

### 13.3 为什么不做内置浏览器（关键取舍）

原版靠 `WebView` + `CookieManager.getCookie(url)` 抓登录态。桌面端做不到：

- Wails v3 **没有** cookie API（`pkg/application` 里搜不到 Cookie 相关导出）；
- WebView2 的 cookie 存在独立进程的用户数据目录里，登录态 cookie 绝大多数是
  **HttpOnly**，JS 的 `document.cookie` 读不到；
- 想用「给登录窗口挂本地代理抓 `Cookie:` 头」也不行：Wails 不暴露
  `AdditionalBrowserArguments`，只能靠 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`
  影响**整个应用**（连自身资源都要过代理），且 Windows 专属。

结论：**不做假的「内置登录窗口」**（用户登进去却发现登录态没保存，比没有更糟），
改成「系统浏览器登录 + 粘贴 Cookie」。这条路对用户多一步复制，但结果可靠，
且 HttpOnly cookie 在 DevTools 里本来就可见。

真正的登录态只认一个地方：**引擎的 `CookieStore`**。所以三条路径最后都落到它，
抓取、图片下载、`/img/` 代理共用同一份（漫画源登录后图片才能取到）。

### 13.4 两处必须改对的引擎行为

1. **Cookie 必须落盘**：`bootstrap.New()` 里
   `store.Default().SetCookieFile(<root>/cookies.json)`。不设置就只有内存副本，
   重启应用要重新登录，书源自己的 `Set-Cookie` 也一起丢。
2. **`enabledCookieJar` 缺省应为 `true`**（`model.BookSource.EnabledCookieJarOn`）。
   Kotlin 原版默认 true，而 Go 侧早先 `nil → false`：登录脚本 `java.post` 拿到了
   `Set-Cookie` 却不保存，典型症状是「登录成功，一刷新掉登录态」。

### 13.5 登录检测：`loginCheckJs` 是「替换响应」

原版语义（`WebBook.kt`）：`res = analyzeUrl.evalJS(checkJs, res)`，
脚本**返回新的响应体**，返回内容被当作 body 继续解析。所以判定必须是：

- 返回空 / 抛错 → 没替换 → Cookie 有效；
- 返回**与原文相同**的 body → 等于没替换 → 有效；
- 返回另一段正文 → 被登录墙顶掉了 → 需要登录。

按「返回非空即未登录」来判会踩坑：脚本只要写 `return result`，
已登录的书源会永远显示「未登录」。

没有 `loginCheckJs` 的书源退回「首屏 4000 字节内找关键词 + 401/403」，
结论标为参考（探测地址里 `{{key}}`/`{{page}}` 会被替换成具体值，
`searchUrl` 是 JS 规则时跳过它——否则会把整段脚本当 URL 发出去）。

### 13.6 登录信息存哪、为什么不加密

- **Cookie**：引擎 `cookies.json`（按二级域名，明文）——这部分由 legado-go 管理，
  原版同样如此。
- **表单值与登录头**：`source_login(source_url PRIMARY KEY, form_json, header, updated_at)`。
  主键用书源地址而非 id：登录态跟着站点走，重新导入同一份 JSON 换 id 也不该丢；
  改了域名则自然失效。

原版把表单值用 AES（key 来自 androidId）存 SharedPreferences；桌面端**不重复加密**：
同一份 cookie 反正以明文躺在 `cookies.json` 里，只加密数据库那一份是自我安慰。
真正要做的是**别让它出现在日志/界面上**：`dto.SourceLoginView` 只给 `cookieMask`
（`sid=abcd…（共 3 项，128 字节）`），完整头只在用户主动点「查看已保存」时读取。

**已知限制**：登录头里**只有 Cookie 会真正生效**。非 Cookie 的鉴权头
（如 `Authorization: Bearer …`）会原样存下来、可在界面查看，但不会自动附加到请求上——
`legado-go` 的 `AnalyzeUrl` 只从书源 `header` 字段取请求头，没有「登录头覆盖」这一层
（Kotlin 原版有，Go 移植版没有）。这类书源要么把该头写进 `header` 规则，要么依赖 Cookie。

### 13.7 回归用例

`tmp-mcptest/s12_source_login.py`（23 项，自带 mock 站点，不依赖预置书目）：

- 书源列表 →「登录」入口 → 对话框、漫画源标记、按 `loginUi` 渲染字段
- 密码错误 → 有结论且不留登录态；密码正确 → 已登录 + Cookie 掩码
- **登录后 `SourceAPI.Search` 能拿到需要登录才返回的结果**（证明 Cookie 真进了请求头）
- 检测登录 → 结论有效；清除登录 → 搜索重新被拦住
- 粘贴 Cookie 登录 → 搜索可用 → 查看已保存登录头
- 刷新页面登录态仍在（`cookies.json` + `source_login` 都落盘）
- 连账号密码一起删除 → 表单与 Cookie 均为空
- 网页登录型书源（`loginUrl` 是页面地址）→ 提示到浏览器打开 + 不渲染账号表单

## 14. 书源管理界面（列表 / 编辑器 / 分组）

这一页的目标是**功能与原生 `BookSourceActivity` / `BookSourceEditActivity` 对齐**，
不是「够用的简化版」。原生的多选批量、分组、拖拽排序、行内校验消息都保留了，
差异只在与桌面形态相关的地方（见 14.5）。

### 14.1 分层

| 层 | 位置 | 职责 |
|---|---|---|
| 领域 | `internal/domain/source_meta.go` | 从 Raw 推派生元数据（类型/发现/登录/权重）、分组字符串的增删改、带 `UseNumber` 的 Raw 补丁 |
| 应用 | `internal/app/source.go` / `source_manage.go` | 单条 CRUD 在 `source.go`；批量启停/分组/排序/源变量/清 Cookie 在 `source_manage.go` |
| 适配 | `adapter/persistence/sqlite/source.go`、`source_variable.go` | 列 + Raw 双写；`UpdateOrders` 批量落序 |
| 界面 | `views/SourceView.vue`、`SourceEditView.vue`、`components/source/*` | 列表（工具条/筛选/批量条/拖拽）、编辑器三栏、分组管理对话框 |

### 14.2 派生字段在服务端算

列表不能带 Raw：单条几 KB~几十 KB，上千书源会把响应撑到几十 MB。
所以「发现开关 / 有无登录地址 / 响应时间 / 权重」这些**原本从 Raw 里读的展示字段**
由 `dto.NewSourceBriefViews` 在服务端算好下发，前端不再 parse Raw。

### 14.3 分组必须「列 + Raw」双写

`book_sources.group_name` 供查询/分组菜单统计，Raw 里的 `bookSourceGroup` 供导出到
其他 Legado 客户端。只改一处会导致「桌面端看着在 A 组，导出到手机却在 B 组」。
所有分组动作统一走 `applyGroup`。

改 Raw 一律用 `domain.PatchSourceRaw`（`json.Decoder.UseNumber()`），否则 `1704296786421`
这样的时间戳会被写成 `1.704296786421e+12`，导入手机的 legado 直接认不出。

**重新命名分组是原位替换**（`domain.RenameGroup`），不是「先删后加」：多分组时
先删后加会把分组挪到末尾，用户只是改个名字却发现顺序变了。

### 14.4 编辑器：撤销粒度按「一次编辑会话」合并

`dirty` 由「当前序列化 vs 打开时的快照」推出，而不是每次改动手动置位——否则
改一下再撤销回来仍显示「未保存」，离开时还要多弹一次确认。

历史栈按**字段**合并（`sessionKey` / `sessionTop`）：输入框「先清空再输入」会先产生
一个空值中间态，不合并的话一次撤销只回到「空」而不是原值，用户会以为撤销坏了。
`frontend/src/stores/sourceEdit.test.ts` 守着这条不变量。

编辑页必须监听 `route.params.id`：同一路由只换参数时组件被复用（`onMounted` 不再触发），
不监听就会一直显示上一个书源的草稿——列表里连着点两个「编辑」就能踩到。

### 14.5 与原生的有意差异

| 原生 | 桌面端 | 原因 |
|---|---|---|
| 下拉刷新 | 工具条「刷新」按钮 | 桌面没有下拉手势 |
| 一次渲染全表 | 增量渲染，`PAGE_SIZE = 300`，触底追加 | DOM 太多会卡；不用虚拟列表是为了保留 `Ctrl+F`/无障碍 |
| 校验逐条弹「成功/失败」toast | 汇总进度条 + 行内「成功/失败：原因」 | 上百个源弹上百次 toast 会把界面顶死 |
| 编辑页无撤销 | 撤销/重做（`Ctrl+S` 保存） | 桌面输入习惯 |

批量改动做完就退出多选（`exitSelection`，对齐原生 `finishActionMode`）：留着选中态
会让用户以为还要再点一次，而且列表已经变了，旧选中集合容易和新列表对不上。

### 14.6 回归用例

- `tmp-mcptest/s5_sources_webdav.py`（19 项）：列表行数、工具条、按词过滤、编辑/调试入口、启停落库、校验确认框
- `tmp-mcptest/s8_source_edit.py`（32 项，自带 mock 站点）：三栏布局、7 组字段、脏标记/撤销、JSON 视图与非法 JSON、保存、调试面板流式输出、未保存离开拦截、新建校验
- `tmp-mcptest/s16_source_pagination.py`（9 项）：300 行首屏、触底追加、搜索后重置第一页
- `tmp-mcptest/s19_source_groups.py`（16 项）：分组下拉与计数、分组管理改名/新建（收拢无分组）/删除（不删源）、批量启停/进出分组/置顶/删除
- Go：`internal/domain/source_meta_test.go`（默认值、Raw 补丁保格式、分组增删改）、`internal/app/source_manage_test.go`（双写、幂等、顺序语义）

## 15. 词典（英汉互译取词）

> 完整方案（含数据源选型实测、体积、许可、交互设计）见
> `../desktop英汉互译功能设计方案.md`。这里只记结构与硬约束。

### 15.1 分层与文件

| 层 | 文件 | 职责 |
|---|---|---|
| domain | `internal/domain/dict.go` | `DictEntry` / `DictHit` / `DictPackage`；归一化、方向判定、规则还原候选、中文切分、变形中文标签 |
| port | `internal/port/dict.go` | `DictionaryRepository`（只读）、`DictPackageInstaller`（M4） |
| adapter | `internal/adapter/dictsqlite/` | `modernc.org/sqlite` 只读打开（`mode=ro&immutable=1`）+ 四种查询 |
| app | `internal/app/dict.go` | 解压内置库、五级回退、最长匹配、来源与命中方式标注 |
| app | `internal/app/dictdata/` | `go:embed en-zh.core.v1.db.gz`（2.14 MB） |
| app | `internal/app/dict_install.go` | 扩展包下载/校验/导入（**M4，未实现**） |
| api | `api/dict.go` | `Lookup` / `DictStatus` |

**词典库不进主库迁移**：`<data>/dict/*.db` 是外部构建产物，结构固定、永不写入，
坏了删掉重装即可，不牵连 `legado.db`。所以它是 `mode=ro` 打开的，
`DictRepo` 也没有任何写方法。

### 15.2 表结构（由 `cmd/dictbuild` 生成）

```sql
CREATE TABLE word(w TEXT PRIMARY KEY, ph TEXT, tr TEXT, pos TEXT,
                  collins INT, oxford INT, tag TEXT, bnc INT, frq INT) WITHOUT ROWID;
CREATE TABLE form(v TEXT PRIMARY KEY, l TEXT, t TEXT) WITHOUT ROWID;  -- v 变体 / l 原型 / t 关系码
CREATE TABLE zh(z TEXT, py TEXT, en TEXT, trad TEXT);                -- 汉英包，另有 idx_z/idx_t
```

- `form.t` 是 ECDICT `exchange` 的关系码：`p` 过去式、`d` 过去分词、`i` -ing、
  `3` 三单、`s` 复数、`r` 比较级、`t` 最高级，逗号分隔（`had` 是 `p,d`）。
  **没有它，had / were / been 只能显示「变形」**——这几个词与原型没有共同前缀，
  后缀猜不出来，而它们恰恰是阅读里最高频的词。
- 词形表由「正向关系」（原型的 `p:/d:/i:`）与「反向关系」（`0:lemma`）**合并**建表，
  同一变体从多条记录汇合（`had` 同时来自 have 的 p 与 d）。
  构建时先在内存合并再写库，直接 `INSERT OR IGNORE` 会丢掉其中一个关系。

### 15.3 两条不能改的规则

1. **主体词条按词频裁，词形表一律全量保留。** ECDICT 把 `had/were/been` 这类
   自动生成的变化形式也收成独立词条，但它们没有 bnc/frq 标注。按词频裁而不单独保留
   词形表，这批词会整批消失（实测损失 3.74% 词次，丢的全是最常用的词）。
   核心档实测：主体 38,243 条 + 词形 58,152 条 = 4.48 MB（gz 2.14 MB）。
2. **查不到不返回错误。** 「词库未收录」是正常状态，用 `DictResultView.Hint` 表达；
   只有核心库损坏/解压失败才返回 error。汉英包未安装同样走 Hint（用户可自行安装）。

### 15.4 命中方式的标注

`matchedBy` 必须传到前端：`exact` / `form` / `rule` / `prefix` / `single` / `none`。
词形命中还要给 `lemma` + `formLabel`（「perceived 是 perceive 的过去式」），
否则用户会以为查错了词。`ruleGuess=true` 表示来自规则还原而非词形表，前端应弱化提示。

### 15.5 构建词库

```bash
go run ./cmd/dictbuild -csv ecdict.csv -tier core -out internal/app/dictdata/en-zh.core.v1.db
```

重建后**必须同步** `dictdata.CoreVersion`（文件名里的 `v1` 与常量要一致，否则升级后仍读旧库）
与 `CoreEntries` / `CoreBuiltAt`。旧的 `en-zh.core.*.db` 会在下次解压时自动清理。

### 15.6 扩展包：清单里存的是**上游源文件**，不是我们打包的 .db

这一点与初版设计不同，必须记住：**扩展包由上游原始数据在本机转换**。

| | 初版设想 | 实际做法 |
| --- | --- | --- |
| 分发物 | 我们自己构建的 `en-zh.full.db` | 上游 `ecdict.csv` / `cedict_ts.u8` |
| 托管 | 需要自建仓库并发布 Release | 直接用上游仓库的固定提交 |
| 校验对象 | 产物哈希 | **源文件**哈希（`manifest.json`） |
| 转换 | 无 | 下载后本地转换（与 `cmd/dictbuild` 同一份实现） |

理由：自建仓库是一条没人维护就会烂掉的依赖——第一次下载失败时，用户拿到的是
「404」而不是词库。改用上游固定提交后，只要 GitHub 还在，下载路径就成立；
镜像选得好不好只影响速度，不影响能不能装。

代价与对策：
- **61 MB 的 CSV 要用户自己下**（ghfast 实测 283 KB/s，约 4 分钟）→ 因此保留
  「导入本地文件」入口，也因此在源选择器上做能力过滤与测速；
- **上游更新会让哈希变化** → `ref` 一律钉死提交号（`39cfb96…` / `0155512…`），
  不用 `master`；换版本必须发版更新清单，这是有意为之（可复现优先）。

`manifest.json` 里只有：包 ID、体积、源文件坐标（`repo/ref/path/form`）、
源文件 `size` 与 `sha256`、词条数、构建日期。**一个镜像地址都不存**。

### 15.7 下载源与安装（M4）

| 文件 | 职责 |
| --- | --- |
| `internal/app/dictsource.go` | 源注册表、三种自定义写法解析、URL 拼装、按包做能力过滤、测速 |
| `internal/app/dict_install.go` | 下载（Range 续传）→ 校验 → 转换 → 体检 → 原子落位；取消/删除/本地导入 |
| `internal/adapter/dictbuild/` | CSV / u8 → SQLite，`cmd/dictbuild` 与运行时共用 |

四条不能改的规则：

1. **安装不挂在请求 ctx 上。** 绑定方法返回后请求 ctx 就被取消，任务会在几秒后被
   无声掐断。全部用 `context.WithCancel(context.Background())` 派生。
2. **单包互斥。** 两个 goroutine 争写同一个 `.part` 不会报错，产物却是两段文件拼接。
3. **失败不动旧文件。** 下载到 `<packID>.part`、转换到 `<fileName>.tmp`，
   sha256 + 体检通过才 `rename`。
4. **哈希来自内置清单，不走网络。** 否则恶意镜像可同时换包和哈希。
   跨源续传是安全的（各源转发同一份字节），但**校验失败必须整包重下**，
   不能把半截坏文件继续补成另一个坏文件。

能力过滤是硬要求而不是优化：jsDelivr 有 20 MB 单文件上限（实测 403），
全量包 63 MB 用它必然失败，所以源列表按包计算 `usable/reason`，
**自动换源顺序里也直接跳过它**，不让用户下到 100% 才报错。

自定义地址按固定顺序识别：`{url}` 模板 → 具体文件（`.db/.gz/.csv/.u8/.zip/.txt`）→
前缀（自动补尾 `/`）。`file://` 等非 http(s) 一律拒绝。
`PreviewDictSource` 只拼字符串不发请求，用于设置页「将请求：…」回显——
填了前缀却生效成另一种意思，是这类配置项最常见的坑。

**体检必须按包类型选查询**：汉英库只有 `zh` 表，拿英文库的 `word` 表去探会得到
`no such table: word`，表现是「汉英包永远装不上、界面只闪一下」。
失败一律走 `s.fail()`：写 `slog` + 发事件，否则事后完全无从排查。

### 15.8 取词浮层（M2）

| 文件 | 职责 |
| --- | --- |
| `stores/dict.ts` | 浮层状态、取词偏好、安装进度（按 `seq` 丢弃迟到事件） |
| `components/DictPopover.vue` | 词条渲染；桌面贴选区、移动端底部卡片 |
| `components/DictSourceDialog.vue` | 按包过滤的源选择、测速、地址回显、本地导入 |
| `ReaderView.vue` | 选区监听、移动端取词模式、与翻页/朗读的优先级 |

三处冲突的处置顺序（都在 `onStageClick` 里，**取词必须排在翻页与朗读之前**）：

1. 取词模式下点正文 → 只取词，不翻页；
2. 浮层开着 → 这一下点击只关闭浮层，不叠加翻页；
3. 有选区 → 让位给选词。

其它约束：
- 浮层用 `position: fixed` + 选区 `getBoundingClientRect()`；正文是滚动容器，
  用 absolute 会随滚动跑。滚动、换章、路由离开一律关闭浮层。
- **不用全屏遮罩**：遮罩会挡住正文，用户想「再选一个词」时第一次点击只关浮层、
  选不中任何东西。改成文档级 `mousedown`（捕获阶段）判定点在浮层外。
- 移动端不做「长按选中即弹」：安卓 WebView 长按会拉起系统 ActionMenu 抢焦点，
  改成底栏「词典」按钮进入取词模式，点词不产生选区。

### 15.9 当前进度

M1（内核）、M2（阅读器浮层）、M4（下载源管理与扩展包）已完成。
M3（汉英方向的首版验收 + 在线 MT 引擎链）未开始：汉英库已能下载与查询，
但 `Translate` 绑定方法与 `internal/adapter/mt/` 尚未实现。

回归：`tmp-mcptest/s20_dict.py`（25 项，覆盖包状态、回退链、源能力过滤、
三种自定义写法、设置页与下载对话框、阅读器取词与 Esc 关闭）。
Go 侧：`app/dictsource_test.go`（解析/拼装/过滤/续传/校验/落位）。
