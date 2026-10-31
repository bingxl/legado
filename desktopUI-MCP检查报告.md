# Legado 桌面端 UI / 逻辑实测报告（Wails MCP 模式）

- 日期：2026-10-29
- 被测版本：`desktop/` 当前工作区，Wails v3.0.0，`-tags mcp`
- 驱动方式：Wails v3 实验性 MCP 服务（`WAILS_MCP=1` → `http://127.0.0.1:9099/mcp`），16 个工具，
  断言全部走 `dom_query` / `js_eval`，用 `mouse_click` / `keyboard_*` 做真实输入，`call_bound_method` 取后端真值
- 数据：真实数据目录（4 本书 / 29 个书源）。**未做任何删除、入架、保存类操作**

> 启动注意：应用必须由**中完整性**进程启动。当前 agent 会话跑在低完整性沙箱里，WebView2 创建
> controller 会直接失败（`800700aa` / `8000ffff`），但 MCP 服务本身已经起来了。提权（UAC）后正常。
> 这条已写进 `AGENTS.md` 与 `desktop/README.md`。

---

## 1. 发现的问题

### P1-1 `@put` 变量在「搜索/发现 → 详情/目录」链路丢失（功能性阻断）

**现象**：选 `17k小说` 搜索或发现里点任意分类，点书后必然失败，提示：

```
获取目录失败: 章节列表为空：目录规则 "$.data.volumes..chapters[*]" 在
http://api.17k.com/book//volumes?youthModel=0&... 上未匹配到任何章节
```

注意 `book//volumes` —— `{book}` 变量是空的。书籍详情/阅读器都进不去。

**根因（两层都要改）**

1. **引擎层**：`legado-go/pkg/webbook/webbook.go:491` `getSearchItem` 复用一个绑定在 `RuleData` 上的
   `AnalyzeRule`，`@put:{book:id}` 因此落到 `ar.RuleData`（`pkg/rule/analyze_rule.go:220-233` 的
   RuleData 分支），而且是**所有列表项共享一份**（后一条覆盖前一条），从不写进 `SearchBook.VariableHolder`。
   Kotlin 原版是每个 item 先 `analyzeRule.setRuleData(searchBook)`（`model/webBook/BookList.kt:213`），
   `@put` 直接落在该书的 `variableMap`。
2. **应用层**：即便引擎修好，桌面的入架接口也带不走变量 ——
   `internal/domain/search.go:5` 的 `SearchResult`、`internal/app/dto/source.go:105` 的 `SearchResultView`
   都没有变量字段，`internal/app/source.go:439` 的 `AddToShelf` 只接收 `(sourceID, bookURL, name, author, groupID)`。
   Kotlin 的 `SearchBook.toBook()` 会把 `variableMap` 一起带进 `Book`。

**影响面**：29 个书源里 3 个用到 `@put`，其中 `17k小说` 是「列表 `@put` → 目录 `@get`」的真实依赖
（`"name": "$.bookName@put:{book:id}"` + `tocUrl: ".../book/@get:{book}/volumes"`）。
这类 API 型源在 Android 上可用，在桌面上 100% 打不开。

**建议修法**
- 引擎：给 `AnalyzeRule` 加一个 per-item 的变量落点（如 `varSink`，`Put/Get` 优先用它），
  `getSearchItem` 进函数时设为 `sb.VariableHolder`，退出复位；`@put` 就不再污染共享 RuleData。
- 应用：`SearchResult` / `SearchResultView` 增加 `variables`，前端点书时回传，`AddToShelf` 落库前
  `book.LoadJSON(variables)`。这样详情/目录/正文都能读到。

---

### P2-2 SPA 深链接 404：`/book/:id`、`/reader/:id` 刷新即白屏

**现象**（页面内 fetch 实测）：

| 路径 | 状态码 | Content-Type |
|---|---|---|
| `/` | 200 | text/html |
| `/book/2` | **404** | text/plain |
| `/reader/2` | **404** | text/plain |
| `/nope` | 404 | text/plain |

**根因**：`frontend/src/router/index.ts` 用 `createWebHistory()`，而 `main.go:121` 的
`application.AssetFileServerFS(assets)` 对不存在的路径直接 404（Wails 的 `asset_fileserver.go`
没有 index.html 回退）。所以只要发生整页加载（F5 / Ctrl+R / 窗口重建）停在详情页或阅读器，
就会显示空白 404，且窗口内已没有应用界面可退回，只能重开。

**建议修法**：二选一
- 桌面端改用 `createWebHashHistory()`（桌面应用最常见，改动 1 行）；或
- 在 `assetHandler` 包一层：GET 且路径无扩展名、文件不存在时回 `index.html`。

---

### P2-3 详情页「复制书籍地址」失败

点详情页右上角复制按钮，实际提示 **“复制失败，请手动复制”**。

**根因**：`frontend/src/utils/clipboard.ts:7` 先试 `navigator.clipboard.writeText`（WebView 里不可用），
回退 `textarea + execCommand('copy')`，在 WebView2 里同样被拒。`views/BookDetailView.vue:75` 只判断返回值。

**建议修法**：改走 Wails runtime 的 Clipboard（`/wails/runtime.js`）或加一个
`SystemAPI.CopyText(text)` 绑定，前端优先用它，失败再落到现有兜底。

---

### P3-4 阅读器字号不持久化

`views/ReaderView.vue:39` 是 `const fontSize = ref(17)`，没有存储。实测把字号滑到 28px（再键盘调到 23px）
后，重新进入阅读器又回到 17px。用户每本书、每次进阅读器都要重调。

**建议**：`localStorage` 记住字号/行距（或走后端设置），进阅读器时读回。

---

### P3-5 书架「新建分组」空名点“创建”无任何反馈

`views/ShelfView.vue:59` 是 `if (!newGroupName.value.trim()) return;`——弹窗不动、没有任何提示。
对比：`新建书源` 空保存会提示「参数不合法: 书源 URL 不能为空」，`WebDAV 保存` 会提示
「参数不合法: 服务地址不能为空」。

**建议**：加一行 `ElMessage.warning("请输入分组名称")`。

---

### P3-6 WebDAV 未配置时点「测试连接」提示「资源不存在」

空配置直接点“测试连接”，toast 是 **“资源不存在”**——用户看不懂（成因是后端返回 `ErrNotFound`，
被通用错误文案兜住了）。同页“保存”的提示是正常的「参数不合法: 服务地址不能为空」。

**建议**：`Test()` 里先校验服务地址是否为空，给专门的提示；或把 `ErrNotFound` 在 WebDAV 场景映射为
「还没有配置 WebDAV 服务地址」。

---

### 观察（不算 bug，但值得定夺）

- **书源「校验」按钮未选中任何行时会校验全部 29 个源**，没有二次确认、弹窗里也没有进度条
  （只有“正在校验…”），实测 10 秒还没出第一行结果，只能关闭。关闭后后台是否继续跑未验证。
  建议：无选中时提示“将校验全部 N 个书源，是否继续？”，并给逐条进度。
- **发现页分类里的分组标题**（`url` 为空的项，如 17k 的“男生·全部”）渲染为 `disabled` 按钮，不可点 ——
  与 legado 语义一致，属正确行为，记录以免以后被当成 bug。

---

## 2. 已验证通过的部分

| 区域 | 验证点 | 结果 |
|---|---|---|
| 全局 | 侧栏 5 项（书架/发现/搜索/书源/WebDAV）+ 路由高亮同步；`管理书源` 跳 `/sources` | ✅ |
| 全局 | 全程 `window.onerror` / `unhandledrejection` / `console.error` 钩子 | ✅ 0 条 |
| 书架 | 4 本书渲染、卡片结构（封面/元信息/操作）、搜索框过滤（“承渊”→ 1 本，清空→ 4 本）、分组 tab | ✅ |
| 书架 | 点封面/书名 → 直接进阅读器（设计如此，详情页由搜索/发现进入） | ✅ |
| 详情页 | 标题/作者/格式/章数/进度（读至 进阶篇·41%）/简介/展开全部；目录跳章 | ✅ |
| 详情页 | 返回键回到来源页（从详情进阅读器后返回 → 仍回 `/book/2`） | ✅ |
| 阅读器·漫画 | 112 图渲染、`下一章` 切章（第04话→第05话）、目录 126 项、TOC 跳第10话、键盘 ←/→ 切章 | ✅ |
| 阅读器·文字 | EPUB 正文 6.9k 字、章节切换、首章“上一章”禁用、`从第一章开始` 落到 index 0（1/24） | ✅ |
| 阅读器·文字 | 字号：滑块点右侧 17→28px，键盘 ← 28→23px；左右 1/3 区域翻页并跨章 | ✅ |
| 阅读器 | 进度落库：`ReaderAPI.GetProgress(2)` 的 chapterIndex/title 与界面一致 | ✅ |
| 发现 | 29 个书源、手风琴展开（17k 展开出 179 个分类）、分组标题不可点、点分类拉到真实书单 | ✅ |
| 搜索 | 空关键词 → 「请输入关键词」；选源下拉 30 项；`18mh`/`17k` 真实搜索出结果 | ✅ |
| 书源 | 表格 29 行、列（名称/分组/地址/启用/操作）；新建弹窗空保存校验 | ✅ |
| WebDAV | 空地址保存 → 「参数不合法: 服务地址不能为空」；连接配置/备份文件两个 tab | ✅ |
| 弹窗/交互 | Element Plus 对话框、下拉、滑块、tooltip 在 MCP 模拟输入下均正常响应 | ✅ |

---

## 3. 复现方式

```bash
cd desktop
task dev:mcp            # = WAILS_MCP=1 wails3 dev，端点 http://127.0.0.1:9099/mcp
# 若从 agent 沙箱启动会因低完整性导致 WebView2 起不来，需在交互式终端/提权启动
```

探测脚本（本次实测用的最小 MCP 客户端，留作复用）：

```bash
cd desktop
python tmp-mcptest/mcpcli.py --list                  # 列工具
python tmp-mcptest/mcpcli.py dom_query '{"selector":".sidebar .nav-item"}'
python tmp-mcptest/probe.py snapshot                 # 当前视图快照
python tmp-mcptest/probe.py nav                      # 逐页巡检
python tmp-mcptest/probe.py bound "github.com/legado/desktop/api.SourceAPI.List" '[""]'
```

注意：`call_bound_method` 的方法名必须是**完整包路径**（`github.com/legado/desktop/api.SourceAPI.List`），
文档里的 `main.GreetService.Greet` 只适用于 package main 的应用。

---

## 4. 修复记录（同次会话完成）

6 个问题全部改完，`legado-go` / `desktop` 的 `go build && go vet && go test ./...` 全绿，
前端 `vue-tsc --noEmit` 与 `vite build` 通过，`go build -tags mcp ./...` 也能编过。

| 编号 | 修法 | 关键文件 | 回归用例 |
|---|---|---|---|
| P1-1 引擎 | `AnalyzeRule.RuleData` 由 `*model.RuleData` 改成接口 `model.RuleDataInterface`；`getSearchItem` 每条结果先 `SetRuleData(sb)`（对齐 Kotlin `setRuleData(searchBook)`），并把变量回写到 `SearchBook.Variable` | `legado-go/pkg/model/book.go`、`pkg/rule/analyze_rule.go`、`pkg/webbook/webbook.go` | `pkg/webbook/search_variable_test.go`（两条结果各自的 `bid` 不互相覆盖、`ToBook` 后仍在、`tocUrl` 能拼出 `/book/101/volumes`） |
| P1-1 附带 | `@put:{book:id}` 这种「键值都不加引号」的写法以前**根本解析不出来**（`RelaxJSONKeys` 只补键的引号，值裸着仍不是合法 JSON，Kotlin 侧靠 GSON lenient 吃掉）。新增 `util.ParseLooseStringMap` 作为第三层兜底 | `pkg/util/json.go`、`pkg/rule/source_rule.go` | `pkg/util/json_test.go` |
| P1-1 应用 | `SearchResult`/`SearchResultView`/`Book` 增加 `variable`；`AddToShelf` 增加 `variable` 参数；`books` 表加 `variable` 列（迁移 `002_book_variable.sql`）；`toEngineBook` 用它 `LoadJSON` | `desktop/internal/{domain,app,dto,adapter}`、`migrations/002_book_variable.sql`、`frontend/src/{api/source.ts,views/SearchView.vue,views/ExploreView.vue}` | `internal/app/source_add_shelf_test.go`（`TestAddToShelfKeepsListVariable`） |
| P1-1 附带 | `cmd/sourcedl` 的 `target` 也带上 `variable`，否则命令行下载走的是同一条断链 | `desktop/cmd/sourcedl/main.go` | 见下方手工验证 |
| P2-2 | 没改路由模式，而是在 `assetHandler` 里加 `spaHandler`：无扩展名的 GET/HEAD 且 dist 里没有对应文件时回退 `index.html`；路由补 `/:pathMatch(.*)*` → `/` 兜底 | `desktop/main.go`、`frontend/src/router/index.ts` | `desktop/spa_fallback_test.go`（`/book/2`、`/reader/2`、`/nope` → 200 html；`/assets/missing.js` 仍 404） |
| P2-3 | `copyText` 先走 Wails 运行时 `Clipboard.SetText`（落到 OS 剪贴板，不受 WebView 权限限制），失败再退 `navigator.clipboard` / `execCommand` | `frontend/src/utils/clipboard.ts` | 手工验证 |
| P3-4 | 新增 `utils/readerPrefs.ts`（localStorage + 区间夹取 + 全链路容错），阅读器进出都读回 | `frontend/src/utils/readerPrefs.ts`、`views/ReaderView.vue` | 手工验证 |
| P3-5 | 空名不再静默 return，改为 `ElMessage.warning("请输入分组名称")`；同时补上 `createGroup` 的 try/catch | `frontend/src/views/ShelfView.vue` | 手工验证 |
| P3-6 | `WebDAVService.load` 把「配置键不存在 / 值为空 / 地址为空」统一收敛成 `errWebDAVUnset`（`功能未配置: WebDAV 服务地址还是空的…`），`GetConfig` 仍按空视图处理不报错 | `desktop/internal/app/webdav.go` | `internal/app/webdav_test.go` |
| 观察项 | 书源校验加二次确认，说明会校验全部 N 个源 | `frontend/src/views/SourceView.vue` | 手工验证 |

### 已跑通的真实链路（非 UI）

用 `sourcedl` + 真实数据目录副本，对 `17k小说`（书源 18）跑「搜索 → 入架 → 目录 → 正文」：

```
入架: [5] 混沌剑神（作者 心星逍遥）
目录: 4294 章
抓取正文: 2 章
books.variable = {"book":"83528"}
```

修复前这一步是 `获取目录失败: 章节列表为空 … http://api.17k.com/book//volumes`。

### 待人工核对（前端交互，本次未在窗口内实跑）

启动：`cd desktop && LEGADO_DESKTOP_HOME=<任意空目录> ./bin/legado-desktop.exe`（或 `task dev:mcp` 后接 9099）。

1. 详情页/阅读器按 F5（或 Ctrl+R）：应正常重载，不再白屏 404；地址栏风格不变（history 模式保留）。
2. 详情页点「复制书籍地址」：应提示「已复制书籍地址」，粘贴出来是详情页 URL。
3. 阅读器把字号调到 23px → 退出再进 → 仍是 23；重启应用后仍是 23。
4. 书架「新建分组」空名点创建：应提示「请输入分组名称」，弹窗不关。
5. WebDAV 未配置时点「测试连接」：应提示「…WebDAV 服务地址还是空的，请先在「连接配置」里填写并保存」，不再是「资源不存在」。
6. 书源页点「校验」：先弹确认框（提示将校验全部 N 个源）。
7. 选 `17k小说` 搜索并点开一本书：应能进详情并拉到 4000+ 章目录。
