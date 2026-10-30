# Legado Desktop 数据流与 UI 跳转图

> 基于 `desktop/` 当前代码绘制，覆盖 Wails v3 桌面端的真实调用链与路由跳转。
> 约定：**实线**表示同步调用或用户点击，**虚线**表示事件推送、返回或异步回调。

---

## 1. 分层数据流总览

前端只经 `src/api/*.ts` 访问后端；`internal/app` 只面向 `internal/port` 接口；
所有具体实现（SQLite、文件系统、书源引擎、WebDAV）都在 `internal/adapter` 落地。

```mermaid
flowchart TB
  subgraph FE["前端 frontend/src"]
    V["views：Shelf / Explore / Search / BookDetail / Reader / Cache / Source / SourceEdit / WebDAV"]
    CP["components：TtsBar / source 子组件"]
    ST["Pinia stores：bookshelf / cache / sourceEdit / sourceDebug / tts"]
    FA["api/*.ts：唯一允许引用 bindings 的防腐层"]
    V --> FA
    V --> ST
    CP --> ST
    ST --> FA
  end

  BIND["Wails bindings<br/>wails3 generate bindings -ts 生成，禁止手改"]
  FA -->|"调用生成的方法"| BIND

  subgraph API["api/ Wails 绑定层（薄壳：校验 → 调 app → 转 DTO）"]
    A1["BookshelfAPI / LibraryAPI / ReaderAPI"]
    A2["SourceAPI / SourceDebugAPI"]
    A3["CacheAPI / WebDAVAPI / SystemAPI"]
  end
  BIND --> A1
  BIND --> A2
  BIND --> A3

  subgraph APP["internal/app 应用服务（禁止 import Wails）"]
    S1["BookshelfService"]
    S2["ReaderService"]
    S3["LibraryService"]
    S4["SourceService"]
    S5["CacheService"]
    S6["WebDAVService"]
    S7["SourceDebugService"]
    CPV["ContentProvider<br/>正文分派 + 缓存优先"]
    S2 --> CPV
    S3 --> CPV
    S5 --> CPV
  end
  A1 --> S1
  A1 --> S2
  A1 --> S3
  A2 --> S4
  A2 --> S7
  A3 --> S5
  A3 --> S6

  subgraph PORT["internal/port 端口接口（零实现）"]
    P1["BookRepository / ChapterRepository / ProgressRepository"]
    P2["BookSourceRepository / ChapterCacheRepository / SettingsStore"]
    P3["SourceFetcher / LocalBookParserRegistry / BookExporter"]
    P4["BlobStore / WebDAVClientFactory / EventBus"]
  end
  APP --> PORT

  subgraph ADP["internal/adapter 适配器"]
    D1["persistence/sqlite"]
    D2["bookparser：TXT / EPUB / Comic / PDF"]
    D3["legado：抓取器 + 调试器（规则 / JS）"]
    D4["exporter / filesystem / imagefetch / webdav"]
    D5["eventwails：EventBus 实现"]
  end
  PORT --> ADP

  DB[("SQLite<br/>legado.db")]
  FS["本地文件<br/>covers / cache / 原始书籍"]
  NET["外部网络<br/>书源站点 / WebDAV"]
  D1 --> DB
  D2 --> FS
  D4 --> FS
  D3 --> NET
  D4 --> NET

  EV["Wails 事件运行时"]
  D5 --> EV
  EV -. "window.wails.Events.On" .-> ST
```

---

## 2. 启动与依赖装配

`main.go` 是 Wails 宿主组合根；`internal/bootstrap` 是与宿主无关的业务组合根，
CLI 与桌面端共用同一套装配，保证行为一致。

```mermaid
sequenceDiagram
  autonumber
  participant M as main.go
  participant Bus as eventwails.Bus
  participant B as bootstrap.New
  participant DB as sqlite
  participant S as app 服务
  participant API as api 绑定层
  participant W as Wails App

  M->>M: dataDir()<br/>LEGADO_DESKTOP_HOME 或 XDG DataHome/legado-desktop
  M->>Bus: New()
  M->>B: New(root, bus)
  B->>DB: Open(root/legado.db)
  B->>B: 装配仓储 / BlobStore / 解析器 / 导出器 / Fetcher
  B->>S: 构造 Bookshelf、Reader、Source、Library、Cache、WebDAV、SourceDebug
  B->>S: 构造共享 ContentProvider
  B-->>M: *bootstrap.App
  M->>API: NewXxxAPI(biz.Xxx)
  M->>W: application.New(Services...)
  M->>Bus: Attach(app)
  M->>API: SystemAPI.Attach(app)
  M->>W: Window.NewWithOptions(URL="/")
  M->>W: Run()
  Note over Bus,W: Attach 前的进度事件先缓存，就绪后补发，避免启动阶段丢事件
```

---

## 3. 本地书导入数据流

支持 TXT / EPUB / PDF / 漫画目录或压缩包。重复导入同一路径会更新元数据与目录，
不会产生重复书籍。

```mermaid
flowchart TB
  U["书架页：导入书籍 / 导入目录"] --> D["SystemAPI.OpenFiles / OpenDirectory<br/>Wails 原生文件对话框"]
  D --> L["LibraryAPI.ImportFiles(paths, groupID)"]
  L --> S["LibraryService.ImportLocalFiles"]
  S -. "每本书" .-> E["EventBus：import:progress"]
  S --> P["按扩展名判定 BookFormat"]
  P --> R{"Registry.Resolve(format)"}
  R --> T["TXT / EPUB / PDF / Comic 解析器"]
  T --> M["解析结果：元数据 + 章节 + 封面"]
  M --> CV["BlobStore.Save → covers/"]
  M --> UP{"books.FindByURL(local, 绝对路径)"}
  UP -->|"已存在"| UPD["Update 元数据<br/>保留分组 / 进度 / 创建时间"]
  UP -->|"不存在"| NEW["Create 新书籍"]
  UPD --> CH["UnitOfWork 事务<br/>chapters.ReplaceAll"]
  NEW --> CH
  CH --> OUT["ImportResult{imported, failed}"]
  OUT --> UI["导入结果弹窗 + 书架刷新"]
  E -.-> UI
```

漫画导入时，解析器会把压缩包解压到 `cache/comic/`，章节地址直接指向
`/local/cache/comic/...`；本地书始终读取原文件，不进入章节缓存。

---

## 4. 网络书：发现 / 搜索 / 入架

搜索与发现共用 `SourceService` 与 `legado` 抓取器。**点击结果行会先自动入架，
拿到本地 book id 后再跳详情页**；「加入书架」按钮则留在原页。

```mermaid
flowchart TB
  subgraph EXPLORE["发现页"]
    EX1["ListExploreSources<br/>启用 + 开启发现 + 配置 exploreUrl"] --> EX2["展开书源 → ExploreKinds<br/>按 raw 内容 + TTL 进程内缓存"]
    EX2 --> EX3["点分类 → Explore(sourceId, url, page)"]
    EX3 --> EX4["滚动到底 → page+1 继续拉取"]
  end

  subgraph SEARCH["搜索页"]
    SE1["选择全部书源 / 指定书源"] --> SE2{"SearchAll 还是 Search"}
    SE2 -->|"全部"| SE3["ListEnabled → 逐源串行搜索<br/>单源失败跳过"]
    SE2 -->|"指定"| SE4["Fetcher.Search"]
  end

  EX3 --> ENG["legado Fetcher<br/>HTTP + CSS/XPath/JSONPath/JS 规则引擎"]
  SE3 --> ENG
  SE4 --> ENG
  ENG --> RES["[]SearchResultView<br/>name / author / cover / bookUrl / origin / variable"]

  RES --> ACT{"用户操作"}
  ACT -->|"点击结果行"| ADD["SourceService.AddToShelf"]
  ACT -->|"加入书架按钮"| ADD
  ADD --> DUP{"origin + bookUrl 已存在？"}
  DUP -->|"是"| BRIEF["直接返回已有 BookBrief"]
  DUP -->|"否"| INFO["Fetcher.GetBookInfo<br/>抓详情 + 目录"]
  INFO --> TX["books.Create + chapters.ReplaceAll"]
  TX --> BRIEF
  BRIEF -->|"点击结果行"| NAV["router.push /book/:id"]
  BRIEF -->|"加入书架按钮"| TOAST["提示已加入，停留在原页"]
```

> 发现页的「书源列表 → 分类 → 书单」是页内状态切换，不产生路由；
> `ExploreView` 被 `keep-alive` 缓存，进详情再返回时展开状态与滚动位置仍在。

---

## 5. 阅读正文获取数据流

`ContentProvider` 屏蔽「本地文件」与「网络书源」的差异。网络书优先读缓存，
缓存按章节地址校验，地址变化即视为失效，避免读到旧版正文。

```mermaid
flowchart TB
  R["ReaderView.loadChapter(i)"] --> API["ReaderAPI.GetContent(bookID, i)"]
  API --> RS["ReaderService.GetContent"]
  RS --> BG["books.Get + chapters.Get"]
  BG --> CPD["ContentProvider.Chapter"]
  CPD --> CACHE{"chapter_cache 命中<br/>且缓存 URL == 当前章节 URL？"}
  CACHE -->|"是"| HIT["返回缓存正文 / 图片"]
  CACHE -->|"否"| KIND{"book.kind"}
  KIND -->|"local"| LP["parsers.Resolve(format).Content<br/>读原始文件"]
  KIND -->|"web"| SRC["sources.FindByURL(book.origin)"]
  SRC --> FETCH["Fetcher.GetContent<br/>规则 / JS 执行<br/>nextChapterURL 防止正文串章"]
  LP --> DTO
  HIT --> DTO
  FETCH --> DTO["DTO：title / html / images / prevIndex / nextIndex / total"]
  DTO --> RENDER{"book.format / images"}
  RENDER -->|"pdf"| PDF["iframe src=/raw/?p=绝对路径"]
  RENDER -->|"comic 或 images 非空"| IMG["图片流<br/>本地 /local/…，网络走 /img/ 代理"]
  RENDER -->|"其它"| HTML["v-html 正文"]
  RENDER --> PROG["滚动 / 换章"]
  PROG --> SAVE["ReaderAPI.SaveProgress"]
  SAVE --> SHELF["BookshelfService.SaveProgress<br/>reading_progress + books 冗余字段（同一事务）"]
```

---

## 6. 章节缓存任务

缓存是**手动触发**的后台任务，每本书同一时刻最多一个任务；文本入
`chapter_cache`，漫画图片落盘到 `cache/chapter/<bookId>/<index>/`。

```mermaid
flowchart TB
  TRIG["触发点：详情页「缓存」/ 阅读器缓存菜单 / 缓存页补充缓存"] --> API["CacheAPI.Start(bookID, scope, indexes)"]
  API --> S["CacheService.Start"]
  S --> V{"校验"}
  V -->|"本地书 / 无目录 / 已有运行任务"| ERR["返回错误"]
  V -->|"通过"| PICK["pickTargets 按 scope 选章节"]
  PICK --> ALL["all：全部可读章节"]
  PICK --> REM["remaining：从 durChapterIndex 到结尾"]
  PICK --> MIS["missing：跳过 chapter_cache 已有章节"]
  PICK --> CHS["chapters：指定序号"]
  ALL --> JOB
  REM --> JOB
  MIS --> JOB
  CHS --> JOB
  JOB["startJob<br/>登记任务 + Background ctx + cancel"] --> EMIT["EventBus：cache:progress running"]
  EMIT --> RUN["run：固定数量 worker 消费章节队列"]
  RUN --> ONE["cacheOne<br/>chapters.Get → ContentProvider.ChapterFresh"]
  ONE --> PERSIST{"content.images 非空？"}
  PERSIST -->|"否"| TXT["CachedChapter{html, size}"]
  PERSIST -->|"是"| IMG["下载图片 → cache/chapter/…<br/>URL 改写为 /local/…"]
  TXT --> PUT["chapter_cache.Put"]
  IMG --> PUT
  PUT --> ADV["advance：计数 + 推送进度"]
  ADV --> RUN
  RUN --> FIN["finish：done / canceled<br/>推送终态"]
  FIN --> UI["缓存页 / 全局缓存条 / 详情页刷新"]
```

缓存管理页的删除动作：按章删除 → `deleteChapters`；清空某书 → `purgeBook`
（同时停任务、删 DB 记录与图片目录）；全清 → `clear`。删除书籍时
`BookshelfService.DeleteBook` 会先 `PurgeBook` 再删书。

---

## 7. 书源管理与调试

书源以「原始 JSON」持久化，管理字段（名称 / 分组 / 启用 / 排序）冗余成列。
调试支持「未保存的 JSON 直接跑」，因此编辑页改完不必先保存。

```mermaid
flowchart LR
  SV["书源页 /sources"] --> LIST["SourceAPI.List"]
  LIST --> DB[("book_sources")]
  SV -->|"新建"| NEW["/sources/new"]
  SV -->|"编辑 / 调试"| EDIT["/sources/:id/edit<br/>可选 ?tab=debug"]
  EDIT --> SAVE["SourceAPI.Save → SourceService.Save<br/>raw 原文 + 冗余列"]
  SAVE --> DB
  SV -->|"导入"| IMP["系统文件对话框 → /raw/ 读取文本<br/>SourceAPI.Import"]
  IMP --> UPSERT["解析 JSON 数组<br/>按书源 URL upsert"]
  UPSERT --> DB
  SV -->|"导出"| EXP["SourceAPI.Export → 系统保存对话框"]
  SV -->|"启用开关"| EN["SourceAPI.SetEnabled"]
  SV -->|"删除"| DEL["SourceAPI.Delete"]
  SV -->|"校验"| VAL["SourceService.Validate<br/>逐源 Fetcher.Validate"]
  VAL --> VDB["更新 last_update_at"]
  VAL -. "source:check:progress" .-> SV
```

### 7.1 书源调试时序

调试是**全局单会话**，输出通过事件总线逐条推给前端；`App.vue` 在挂载时订阅，
所以切页面不会丢日志（前端日志缓冲上限 3000 行）。

```mermaid
sequenceDiagram
  autonumber
  actor U as 用户
  participant E as SourceEditView
  participant A as SourceDebugAPI
  participant S as SourceDebugService
  participant D as legado Debugger
  participant B as port.EventBus
  participant W as Wails 事件
  participant P as sourceDebug store

  U->>E: 打开「调试」页签，填入口与阶段
  E->>A: Start(sourceID, rawJSON, key, stage)
  A->>S: Start
  S->>S: resolveSource：rawJSON 优先，否则读库
  S->>S: stopRunning（同一时刻只允许一个会话）
  S-->>E: DebugSessionView{session, running}
  S->>D: go Debug(ctx, src, key, stage, sink)
  loop 每个阶段 / 每条日志
    D-->>S: DebugSink.Emit(entry)
    S->>B: Emit("source:debug", entry)
    B->>W: app.Event.Emit
    W-->>P: onSourceDebug
    P-->>E: 追加输出（超过 2000 条后截断并提示）
  end
  D-->>S: 返回 result / error
  S->>B: Emit("source:debug:done", done)
  B->>W: app.Event.Emit
  W-->>P: onSourceDebugDone
  P-->>E: 标记结束与耗时
```

---

## 8. WebDAV 备份数据流

配置存 `app_settings`（键 `webdav.config`）。上传的是数据库文件快照，
下载只保存到本地目录，**不会替换运行中的数据库**。

```mermaid
flowchart LR
  W["WebDAV 页 /webdav"] --> CFG["GetConfig / SaveConfig"]
  CFG --> ST[("app_settings<br/>webdav.config JSON")]
  W --> TEST["Test<br/>客户端 List 根目录"]
  W --> LIST["List(relPath)"]
  W --> UP["UploadBackup"]
  UP --> SNAP["打开 legado.db"]
  SNAP --> PUT["WebDAV PUT<br/><root>/backups/backup-时间戳.db"]
  W --> DL["DownloadBackup(remotePath, localDir)"]
  DL --> SAVE["保存到本地目录<br/>需重启后手动替换才生效"]
  W --> DEL["Delete(relPath)"]
  UP -. "webdav:sync:progress" .-> W
  DL -. "webdav:sync:progress" .-> W
```

> `List` 返回的 `Path` 一律**相对工作根目录**（如 `novels/a.txt`）。前端会把它原样回传给
> `List` / `DownloadBackup` / `Delete`，而这三处内部都会再拼一次 `remoteRoot`——
> 若这里给完整路径就会拼成 `/legado-desktop/legado-desktop/...` 而 404。

---

## 8.1 从 WebDAV 选书导入

与备份下载刻意分开：备份是「存一份」，导入是「成为书架上一本书」。
下载落点固定为 `<数据根>/webdav/<远端相对路径>`——因为书架记录的是**本地绝对路径**，
放系统临时目录里重启后书就打不开了。

```mermaid
flowchart TB
  P["WebDAV 页 · 导入书籍页签"] -->|"逐层浏览"| LIST["List(relPath)<br/>目录可进入、可勾选"]
  P -->|"选中后先统计"| SCAN["ScanBooks(relPath)<br/>递归 ≤8 层、≤2000 个"]
  P -->|"确认导入"| START["StartBookImport(relPaths, groupId)"]

  START --> MUTEX{"已有任务在跑？"}
  MUTEX -->|"是"| ERR["拒绝：请先等它结束或取消"]
  MUTEX -->|"否"| JOB["登记任务<br/>Background ctx + cancel"]

  JOB --> COLLECT["collectBooks<br/>目录递归展开 + 按路径去重"]
  COLLECT --> EACH["逐个文件"]
  EACH --> SKIP{"本地已存在<br/>且不比远端旧？"}
  SKIP -->|"是"| NEXT["跳过传输，直接入库"]
  SKIP -->|"否"| DL["Download → 写 .part → 改名<br/>带 30min 超时与字节进度"]
  DL --> NEXT
  NEXT --> IMP["LibraryService.ImportLocalFiles<br/>解析 → book + chapter 入库"]
  IMP --> AGG["累加成功 / 失败"]
  AGG --> EACH
  AGG --> FIN["done / canceled / failed"]

  DL -. "webdav:import:progress" .-> P
  IMP -. "webdav:import:progress" .-> P
  FIN -. "webdav:import:progress" .-> P
```

要点：

- **单任务互斥**：下载是带宽密集的，并行只会互相拖慢；第二个请求直接报错并返回当前任务。
- **取消**：半成品用 `.part` 后缀，取消时删除；已下载完成的书保留（它们已经入库）。
- **路径安全**：远端路径逐段 `sanitizeFileName` 并拒绝 `..`，防止写到数据目录之外。
- **幂等**：本地路径由远端路径推导，重复导入同一文件会走 `LibraryService` 的「按 URL 更新」，
  不会产生重复书籍。
- **前端进度是双通道**：事件 + 1s 轮询 `BookImportStatus`。打包后的 `@wailsio/runtime`
  事件注册表与运行时注入的那份互不相通，只靠事件会出现"进度不动"。

---

## 9. 事件总线

`internal/app` 只依赖 `port.EventBus`；`eventwails` 把事件桥接到 Wails，
App 就绪前收到的事件会先缓存再补发。

```mermaid
flowchart LR
  subgraph P["生产者 internal/app"]
    I["LibraryService<br/>import:progress"]
    V["SourceService<br/>source:check:progress"]
    D["SourceDebugService<br/>source:debug / source:debug:done"]
    C["CacheService<br/>cache:progress"]
    WD["WebDAVService<br/>webdav:sync:progress"]
  end

  EB["port.EventBus"]
  EW["eventwails.Bus<br/>未 Attach 先入 pending"]
  WA["Wails app.Event.Emit"]
  RT["window.wails.Events.On"]
  EVT["frontend/src/api/events.ts"]

  subgraph C2["消费者"]
    SH["App.vue 导入进度条<br/>完成后 shelf.loadBooks"]
    SC["SourceView 校验结果弹窗"]
    SD["sourceDebug store<br/>App.vue attach，跨页保活"]
    CS["cache store<br/>App 缓存条 / 详情 / 阅读器 / 缓存页"]
    WV["WebDAVView 同步状态"]
  end

  I --> EB
  V --> EB
  D --> EB
  C --> EB
  WD --> EB
  EB --> EW --> WA --> RT --> EVT
  EVT --> SH
  EVT --> SC
  EVT --> SD
  EVT --> CS
  EVT --> WV
```

> `download:progress` 在 `port/event.go` 与前端事件表中有定义，但当前桌面端
> 没有生产者与订阅者，属于预留事件。

---

## 10. 持久化与资源布局

### 10.1 数据库表关系

```mermaid
erDiagram
  book_groups ||--o{ books : "group_id"
  books ||--o{ book_chapters : "book_id"
  books ||--|| reading_progress : "book_id"
  books ||--o{ chapter_cache : "book_id"

  books {
    INTEGER id PK
    TEXT name
    TEXT author
    TEXT kind "web | local"
    TEXT format "epub | txt | pdf | comic"
    TEXT origin "书源 URL 或 local"
    TEXT book_url
    INTEGER group_id
    INTEGER total_chapters
    INTEGER dur_chapter_index
    DATETIME last_read_at
  }
  book_groups {
    INTEGER id PK
    TEXT name
    INTEGER sort_order
    INTEGER show
  }
  book_chapters {
    INTEGER id PK
    INTEGER book_id
    INTEGER idx
    TEXT title
    TEXT url
    INTEGER is_volume
  }
  reading_progress {
    INTEGER book_id PK
    INTEGER chapter_index
    TEXT chapter_title
    REAL scroll_percent
    DATETIME updated_at
  }
  chapter_cache {
    INTEGER book_id PK
    INTEGER idx PK
    TEXT title
    TEXT url
    TEXT html
    TEXT images "JSON 数组"
    INTEGER size
    INTEGER created_at
  }
  book_sources {
    INTEGER id PK
    TEXT name
    TEXT group_name
    TEXT url
    INTEGER enabled
    TEXT raw "Legado 原始 JSON"
  }
  source_subscriptions {
    INTEGER id PK
    TEXT name
    TEXT url
    INTEGER enabled
  }
  replace_rules {
    INTEGER id PK
    TEXT name
    TEXT raw
  }
  txt_toc_rules {
    INTEGER id PK
    TEXT name
    TEXT rule
  }
  app_settings {
    TEXT key PK
    TEXT value
  }
```

> `source_subscriptions`、`replace_rules`、`txt_toc_rules` 为表结构预留/管理能力，
> 与当前书籍数据没有外键关系。

### 10.2 文件系统与本地资源路由

```mermaid
flowchart TB
  ROOT["数据根目录<br/>LEGADO_DESKTOP_HOME<br/>或 XDG DataHome/legado-desktop"]
  ROOT --> DB["legado.db（含 -wal / -shm）"]
  ROOT --> COV["covers/<封面文件>"]
  ROOT --> CC["cache/comic/<解压后的漫画页>"]
  ROOT --> CH["cache/chapter/<bookId>/<index>/001.jpg…"]
  ROOT --> BOOK["原始书籍文件<br/>只记录绝对路径，不复制"]

  COV --> R2["/local/covers/…"]
  CC --> R1["/local/cache/comic/…"]
  CH --> R3["/local/cache/chapter/…"]
  BOOK --> R4["/raw/?p=绝对路径"]
  NET["网络图片"] --> R5["/img/?u=…&src=…<br/>带书源 Referer 的代理"]

  R1 --> WEB["WebView <img> / <iframe>"]
  R2 --> WEB
  R3 --> WEB
  R4 --> WEB
  R5 --> WEB
```

---

## 11. UI 路由级跳转总图

路由表定义在 `frontend/src/router/index.ts`。左侧导航常驻，内容区由
`<router-view>` 渲染；只有 `ExploreView` 被 `keep-alive` 缓存。

```mermaid
flowchart TB
  SHELL["App.vue 外壳<br/>左侧导航 + 内容区 + 常驻 TtsBar / 全局进度条"]

  SHELL -->|"📚 书架 /"| SHELF["书架<br/>/"]
  SHELL -->|"🧭 发现 /explore"| EXPLORE["发现<br/>/explore"]
  SHELL -->|"🔍 搜索 /search"| SEARCH["搜索<br/>/search"]
  SHELL -->|"🗂️ 缓存 /cache"| CACHE["缓存管理<br/>/cache"]
  SHELL -->|"🧩 书源 /sources"| SOURCES["书源列表<br/>/sources"]
  SHELL -->|"☁️ WebDAV /webdav"| WEBDAV["WebDAV<br/>/webdav"]

  UNKNOWN["未知路径"] -->|"redirect"| SHELF

  SHELF -->|"点击书卡"| READER["阅读器<br/>/reader/:id"]
  EXPLORE -->|"点击结果行<br/>自动入架后 push"| BOOK["书籍详情<br/>/book/:id"]
  SEARCH -->|"点击结果行<br/>自动入架后 push"| BOOK
  SEARCH -->|"管理书源"| SOURCES

  BOOK -->|"继续阅读 / 开始阅读<br/>点击目录章节 ?index=N"| READER
  BOOK -.->|"返回：有历史则 back，否则 /"| SHELF

  READER -->|"缓存菜单 → 管理缓存…"| CACHE
  READER -.->|"返回：有历史则 back，否则 /"| BOOK

  SOURCES -->|"新建"| NEW["新建书源<br/>/sources/new"]
  SOURCES -->|"编辑 / 调试"| EDIT["编辑书源<br/>/sources/:id/edit"]
  NEW -->|"保存 / 返回"| SOURCES
  EDIT -->|"保存 / 返回"| SOURCES

  TTS["TtsBar<br/>全局常驻"] -->|"点击书名<br/>回到正在朗读的书"| READER
  CBAR["全局缓存进度条"] -->|"查看"| CACHE
  IBAR["全局导入进度条"] -.->|"完成后刷新"| SHELF

  SHELL --- TTS
  SHELL --- CBAR
  SHELL --- IBAR
```

> 注意：**书架卡片直接进阅读器**，不经过详情页；`/book/:id` 的入口只有
> 发现页与搜索页（以及手工输入地址）。

---

## 12. 页面内功能与跳转细节

### 12.1 书架页

```mermaid
flowchart LR
  S["书架 /"] --> IMP["导入书籍<br/>多选文件 → ImportFiles"]
  S --> DIR["导入目录<br/>漫画目录 → ImportFiles"]
  S --> GRP["新建分组 → CreateGroup"]
  S --> FIL["关键词 + 分组筛选<br/>纯前端过滤"]
  S --> CARD["点击书卡 → /reader/:id"]
  S --> EXP["导出 EPUB<br/>SaveFile → ExportBook"]
  S --> RM["移除<br/>DeleteBook（先清缓存）"]
  IMP --> DIALOG["导入结果弹窗"]
  DIR --> DIALOG
```

### 12.2 发现页 / 搜索页 → 详情

```mermaid
flowchart TB
  subgraph EXPLORE["发现 /explore（keep-alive）"]
    E1["书源手风琴列表"] -->|"展开"| E2["加载分类"]
    E2 -->|"点分类胶囊"| E3["分类书单"]
    E3 -->|"滚动到底"| E4["自动加载下一页"]
    E3 -->|"点结果行"| E5["自动入架 → /book/:id"]
    E3 -->|"加入书架"| E6["留在当前书单"]
    E3 -->|"返回发现"| E1
  end

  subgraph SEARCH["搜索 /search"]
    S1["关键词 + 书源选择"] --> S2["搜索全部 / 单源搜索"]
    S2 --> S3["结果列表"]
    S3 -->|"点结果行"| S4["自动入架 → /book/:id"]
    S3 -->|"加入书架"| S5["留在结果列表"]
    S1 -->|"管理书源"| S6["/sources"]
  end
```

### 12.3 书籍详情页

```mermaid
flowchart LR
  B["书籍详情 /book/:id"] --> LOAD["GetBook + GetChapters + Cache.Status"]
  B --> READ["继续阅读 / 开始阅读<br/>按 durChapterIndex 定位"]
  B --> TOC["目录（默认渲染 300 条，可继续加载）"]
  TOC -->|"点击章节"| READ2["/reader/:id?index=N"]
  B --> CACHE["缓存对话框"]
  CACHE --> CR["从阅读位置缓存到结尾"]
  CACHE --> CA["缓存整本"]
  CACHE --> CM["只补缺失章节"]
  CACHE --> CAN["取消缓存"]
  B --> COPY["复制书籍地址"]
  B --> BACK["返回上一页 / 书架"]
  READ --> R["阅读器"]
  READ2 --> R
```

### 12.4 阅读器

```mermaid
flowchart TB
  R["阅读器 /reader/:id"] --> META["加载书籍 / 目录 / 进度 / 已缓存章节"]
  META --> CH{"按 ?index 还是上次进度"}
  CH -->|"有 ?index"| IDX["从指定章开始"]
  CH -->|"无"| LAST["从 GetProgress 恢复"]
  IDX --> CONTENT["GetContent → 渲染"]
  LAST --> CONTENT

  CONTENT --> TOC["目录抽屉<br/>点击章节切换 + 缓存标记"]
  CONTENT --> PREV["上一章"]
  CONTENT --> NEXT["下一章"]
  CONTENT --> SCROLL["滚动 → 节流保存进度"]
  CONTENT --> CACHE["缓存菜单<br/>本章 / 剩余 / 整本 / 管理缓存"]
  CONTENT --> TTS["朗读<br/>纯文本类才可用"]
  CONTENT --> PREF["字号 / 行距<br/>localStorage 记忆"]
  CONTENT --> COPY["复制书籍地址"]
  CONTENT --> BACK["返回上一页 / 书架"]

  CACHE -->|"管理缓存…"| CACHEPAGE["/cache"]
  TTS --> TTSBAR["TtsBar 常驻<br/>离开阅读器仍继续"]
  TTSBAR -->|"点击书名"| R
```

### 12.5 书源页与编辑页

```mermaid
flowchart LR
  SV["书源 /sources"] --> NEW["新建 /sources/new"]
  SV --> EDIT["编辑 /sources/:id/edit"]
  SV --> DEBUG["调试 /sources/:id/edit?tab=debug"]
  SV --> TOGGLE["启用 / 停用"]
  SV --> DEL["删除"]
  SV --> IMP["导入 JSON"]
  SV --> EXP["导出 JSON"]
  SV --> VAL["校验全部启用书源"]

  NEW --> FORM["三栏布局：左表单 / 中操作按钮 / 右工具页签"]
  EDIT --> FORM
  FORM --> UNDO["撤销 / 重做 / 清空"]
  FORM --> JSONP["JSON 页签：格式化 / 重新载入 / 双向同步"]
  FORM --> SAVE["保存 → 返回列表"]
  FORM --> DBG["调试页签：直接用未保存 JSON 跑 search→info→toc→content"]
  FORM --> HELP["帮助页签：规则语法速查"]
```

### 12.6 缓存页与 WebDAV 页

```mermaid
flowchart LR
  subgraph CACHE["缓存 /cache"]
    C1["统计：书数 / 章数 / 占用 / 运行中任务"]
    C2["按书展开章节明细"]
    C3["补充缓存<br/>有缓存补缺失，无缓存整本"]
    C4["继续缓存剩余"]
    C5["取消运行中任务"]
    C6["删除所选章节 / 删除单章"]
    C7["清空某书缓存"]
    C8["清空全部缓存"]
  end

  subgraph WD["WebDAV /webdav"]
    W1["连接配置：地址 / 用户名 / 密码 / 根目录 / 自动同步"]
    W2["测试连接"]
    W3["保存配置"]
    W4["上传数据库备份"]
    W5["列出备份文件"]
    W6["下载备份到本地"]
    W7["删除远端备份"]
    W8["导入书籍页签<br/>目录浏览 / 勾选 / 进度 / 取消（详见 §8.1）"]
  end
```

### 12.7 常驻外壳

```mermaid
flowchart TB
  SHELL["App.vue"]
  SHELL --> NAV["左侧导航<br/>书架 / 发现 / 搜索 / 缓存 / 书源 / WebDAV"]
  SHELL --> IBAR["导入进度条<br/>import:progress"]
  SHELL --> CBAR["缓存任务条<br/>cache:progress<br/>查看 → /cache，取消 → CacheAPI.Cancel"]
  SHELL --> TTS["TtsBar<br/>朗读中才显示"]
  SHELL --> KA["router-view + keep-alive<br/>仅缓存 ExploreView"]
  TTS --> T1["书名 → /reader/:bookId"]
  TTS --> T2["上一段 / 播放暂停 / 下一段"]
  TTS --> T3["语速 / 音色 / 停止"]
```

---

## 13. 关键行为速查

| 行为 | 真实路径 |
| --- | --- |
| 书架点书 | 直接进 `/reader/:id`，不进详情 |
| 搜索/发现点结果 | 先 `AddToShelf` 入架，再 `/book/:id` |
| 详情页继续阅读 | `/reader/:id?index=<durChapterIndex>` |
| 阅读正文 | `ReaderAPI.GetContent` → `ContentProvider` → 缓存优先 |
| 本地书 | 读原文件，不缓存、不联网 |
| 网络书正文 | 缓存命中直接用，否则按 `book.origin` 找书源抓取 |
| 缓存任务 | 后台协程 + 固定 worker，每书同时只允许一个 |
| 缓存图片 | 落盘 `cache/chapter/<bookId>/<index>/`，DB 只存地址 |
| 删除书籍 | 先清缓存任务与文件，再删 DB 记录 |
| 书源调试 | 全局单会话，事件逐条推送，日志最多保留 3000 行 |
| WebDAV 备份 | 上传 `legado.db` 快照；下载不自动替换运行库 |
| WebDAV 导入 | 选目录/文件 → 下载到 `<根>/webdav/...` → 逐本 `ImportLocalFiles`；单任务可取消 |
| 事件订阅 | 统一走 `src/api/events.ts`，且必须用注入的 `window.wails` |
| 发现页状态 | 唯一被 `keep-alive` 缓存的页面 |
