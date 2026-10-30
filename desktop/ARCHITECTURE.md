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
`replace_rules` · `txt_toc_rules` · `reading_progress`

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
- ❌ 用 Playwright / 外部截图工具 / 临时脚本验证 UI —— 桌面端 UI 测试统一走 Wails MCP 模式（`task dev:mcp`，见 README）

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
