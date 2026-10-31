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
