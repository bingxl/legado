# Legado Desktop — AI 总结与问答功能设计方案

> 状态：**设计稿，待评审**。本文只做设计，不含已实现代码。
> 目标平台：Windows 桌面端 + Android（同一套 Go 业务层与 Vue 前端，见「九、两端一致性」）。

---

## 〇、一句话概述

给一本书建立**语义索引**（切片 → 向量化 → 分层摘要链），之后既能一键生成「章节 / 全书」摘要，也能让 AI **基于原文片段回答细节问题并给出可跳转的引用**。

AI 通道由用户在设置页自配 **OpenAI 兼容 API**（覆盖 OpenAI / DeepSeek / 通义 / 智谱 / Moonshot / 本机 Ollama 等），密钥只落本机。

---

## 一、现状：哪些能复用，哪些要从零建

调研结论（`internal/` 全量扫描，无 AI/LLM 相关代码，无相关依赖）：

| 能力 | 现状 | 本方案的处置 |
| --- | --- | --- |
| 正文获取 | `ContentProvider.Chapter` / `ChapterFresh` / `BookAndChapters` / `FetchContent`（`internal/app/content.go:50,56,141,154`），统一屏蔽本地书与网络书源 | **复用**，新增批量取正文入口（见下） |
| 章节缓存 | `chapter_cache` 表存 HTML 正文，可离线读回 | **复用**；但 `ChapterCacheRepo.List` 故意不返回 `html`（`sqlite/cache.go:66`），需新增 `ListWithContent` |
| 已读边界 | `reading_progress.chapter_index` / `books.dur_chapter_index` | **复用**，作为「总结已读部分」的范围依据 |
| 书籍简介 | `books.intro`（本地 TXT 常为空，需兜底） | **复用**，作为全局上下文的廉价补充 |
| 长任务 + 进度事件 | `CacheService` 成熟范式：`Background ctx` + goroutine + `EventBus.Emit`；前端 `window.wails.Events.On` 订阅 | **完整复制**这套范式 |
| 配置存储 | `app_settings` 纯 KV；WebDAV 用单键 JSON + 视图层剥离密钥（`dto.WebDAVConfigView`） | **对齐**该先例 |
| HTTP 客户端 | 无统一封装；无重试、无 SSE | **新建** `adapter/aihttp` |
| 向量存储 | `modernc.org/sqlite` 纯 Go **无 cgo，无法加载 sqlite-vec 扩展** | **自实现**：BLOB 存 float32 + Go 侧暴力余弦 |
| 迁移机制 | `migrations/*.sql` 按文件名字典序自动执行 | 新增 `004_ai.sql` 即可，**无需改代码** |

### 需要正视的三个硬约束

1. **网络书正文必须先缓存。** 未缓存时只能现抓，几千章按小时计且会被源站限流。索引前若发现缓存率低，UI 必须提示先跑缓存。
2. **本地书永远现读源文件**（TXT 每章 `readTextFile` 整本重读）。索引本地书时要一次性把正文读全再切片，不能按章反复读文件。
3. **sqlite 无向量扩展。** 暴力扫描是唯一选择，但账算得过来：2 万片段 × 1024 维 ≈ 2000 万次乘加 ≈ 40ms，可接受。

---

## 二、总体架构

严格遵循现有分层（见 `ARCHITECTURE.md` R1/R2），**`internal/app` 不得 import Wails**：

```
internal/domain/ai.go                     ← 实体：AIConfig / AIChunk / AISummary / AIChat / AIMessage
internal/port/ai.go                       ← 接口：LLMClient、AIChunkRepository、AISummaryRepository、
                                             AIChatRepository、AIIndexStateRepository
internal/adapter/aihttp/client.go         ← OpenAI 兼容客户端：Chat（SSE 流式）/ Embeddings / 重试 / 超时
internal/adapter/aihttp/sse.go            ← SSE 解析（data: 行，含 [DONE]）
internal/adapter/persistence/sqlite/ai.go ← 仓储实现 + 向量 BLOB 编解码
internal/app/ai.go                        ← AIService：索引、总结、问答、会话
internal/app/ai_index.go                  ← 切片 + 向量化 + 摘要链（map-reduce）
internal/app/ai_retrieve.go               ← 混合召回（向量 + 关键词）+ 上下文预算装配
internal/app/dto/ai.go                    ← 视图（剥离 apiKey）
internal/bootstrap/app.go                 ← 装配（服务段）
api/ai.go                                 ← Wails 绑定层
```

新增依赖：**零**（`net/http` + `encoding/binary` 足够）。

---

## 三、数据模型（迁移 `004_ai.sql`）

```sql
-- ① 语义切片：向量检索与引用溯源的粒度
CREATE TABLE ai_chunks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id     INTEGER NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    chapter_idx INTEGER NOT NULL,
    ordinal     INTEGER NOT NULL,              -- 书内全局序号，保证顺序
    char_start  INTEGER NOT NULL DEFAULT 0,     -- 在章节纯文本内的偏移，用于高亮定位
    char_end    INTEGER NOT NULL DEFAULT 0,
    title       TEXT    NOT NULL DEFAULT '',    -- 所属章节标题，溯源展示用
    text        TEXT    NOT NULL,
    token_count INTEGER NOT NULL DEFAULT 0,
    src_hash    TEXT    NOT NULL DEFAULT '',    -- 源文本 hash；变了才重算
    embedding   BLOB,                           -- float32 小端序列；NULL = 未向量化
    emb_model   TEXT    NOT NULL DEFAULT '',
    emb_dim     INTEGER NOT NULL DEFAULT 0,
    created_at  INTEGER NOT NULL                -- Unix 秒，与 chapter_cache 保持一致
);
CREATE UNIQUE INDEX idx_ai_chunks_book_ord ON ai_chunks (book_id, ordinal);
CREATE INDEX idx_ai_chunks_book ON ai_chunks (book_id);

-- ② 分层摘要：level 1=段摘要 2=组摘要 … 最高层即全书摘要
CREATE TABLE ai_summaries (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id      INTEGER NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    level        INTEGER NOT NULL,
    ordinal      INTEGER NOT NULL,
    parent_level INTEGER NOT NULL DEFAULT 0,    -- 0 = 无父（顶层）
    parent_ord   INTEGER NOT NULL DEFAULT 0,
    chapter_from INTEGER NOT NULL DEFAULT -1,   -- 覆盖的章节区间，-1 = 不适用
    chapter_to   INTEGER NOT NULL DEFAULT -1,
    content      TEXT    NOT NULL DEFAULT '',
    token_count  INTEGER NOT NULL DEFAULT 0,
    model        TEXT    NOT NULL DEFAULT '',
    src_hash     TEXT    NOT NULL DEFAULT '',
    ok           INTEGER NOT NULL DEFAULT 1,
    error        TEXT    NOT NULL DEFAULT '',
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL
);
CREATE INDEX idx_ai_summaries_book ON ai_summaries (book_id, level, ordinal);

-- ③ 索引状态：断点续跑的依据
CREATE TABLE ai_index_state (
    book_id       INTEGER PRIMARY KEY REFERENCES books (id) ON DELETE CASCADE,
    scope         TEXT    NOT NULL DEFAULT 'all',   -- all | read | range
    chapter_from  INTEGER NOT NULL DEFAULT 0,
    chapter_to    INTEGER NOT NULL DEFAULT -1,
    status        TEXT    NOT NULL DEFAULT 'idle',  -- idle|running|done|failed|canceled
    chunk_count   INTEGER NOT NULL DEFAULT 0,
    emb_done      INTEGER NOT NULL DEFAULT 0,
    summary_done  INTEGER NOT NULL DEFAULT 0,
    summary_total INTEGER NOT NULL DEFAULT 0,
    error         TEXT    NOT NULL DEFAULT '',
    updated_at    INTEGER NOT NULL
);

-- ④ 会话与消息
CREATE TABLE ai_chats (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id    INTEGER NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    title      TEXT    NOT NULL DEFAULT '',
    scope      TEXT    NOT NULL DEFAULT 'book',
    model      TEXT    NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX idx_ai_chats_book ON ai_chats (book_id, updated_at DESC);

CREATE TABLE ai_messages (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id    INTEGER NOT NULL REFERENCES ai_chats (id) ON DELETE CASCADE,
    role       TEXT    NOT NULL,              -- user | assistant
    content    TEXT    NOT NULL,
    refs       TEXT    NOT NULL DEFAULT '',   -- JSON 数组：[{chunkId,chapterIdx,title,score}]
    created_at INTEGER NOT NULL
);
CREATE INDEX idx_ai_messages_chat ON ai_messages (chat_id, id);
```

**为什么切片与摘要分开存**：切片服务于「细节问答 + 引用」，摘要服务于「整体理解」。二者更新频率不同（正文变了切片要重算，摘要可按需重建），混在一张表里会让失效判断变复杂。

### 配置（`app_settings` 单键 `ai.config`，对齐 WebDAV 先例）

```go
type AIConfig struct {
    BaseURL       string  `json:"baseURL"`        // 如 https://api.deepseek.com/v1
    APIKey        string  `json:"apiKey"`
    Model         string  `json:"model"`
    Temperature   float64 `json:"temperature"`
    ContextWindow int     `json:"contextWindow"`  // 0 = 按预设档位推断

    // embedding 单列：大量 chat 服务商不提供 embedding（如 DeepSeek）。
    // 留空即降级为纯关键词召回，功能不残废。
    EmbeddingBaseURL string `json:"embeddingBaseURL"`
    EmbeddingModel   string `json:"embeddingModel"`
    EmbeddingDim     int    `json:"embeddingDim"`  // 0 = 首次调用自动推断

    MaxConcurrent int `json:"maxConcurrent"`       // 摘要并发，默认 3
}
```

密钥沿用现有实践：落库明文（全项目无加密先例，WebDAV 密码亦如此），但 **DTO 视图永不返回明文**，只给 `hasKey bool` + 末 4 位掩码。

---

## 四、索引流程（建立语义索引）

输入：`bookID` + 范围（`all` 全书 / `read` 已读部分 / `range` 指定区间）

```
① 取正文   ── 网络书：优先 chapter_cache.html（需新增 ListWithContent）；
           │          未缓存则 ChapterFresh 现抓，并提示「建议先缓存」
           └─ 本地书：整本一次性读入，再按章切分（避免逐章重读文件）
② 切片     ── strip HTML → 纯文本 → 按 token 预算切 chunk
              目标 ~700 token，相邻重叠 ~80 token（防止语义被切断）
③ 向量化   ── 批量调 POST /embeddings（一次多 input，减少往返）
              结果 float32 写 BLOB，同时记 emb_model / emb_dim
④ 摘要链   ── map-reduce，按 token 预算递归合并（见下）
⑤ 状态     ── 写 ai_index_state，全程 Emit 进度事件
```

### 摘要链（map-reduce）

关键点：**按 token 预算打包，而不是按章节数**——否则 1000 章的书会产生上千次调用。

```
L0  原文 chunk（~700 token）
      ↓ 打包到 ~6000 token 一段
L1  段摘要（~300 token）        ← 每个「段」一次 chat 调用
      ↓ L1 数量 > 1 则继续打包
L2  组摘要
      ↓ 递归直到 ≤ 1 条
Ln  全书摘要
```

**成本估算**（100 万字，保守按 1 字 ≈ 1 token）：

| 项 | 数量 | 说明 |
| --- | --- | --- |
| chunk | ≈ 1430 | 700 token/片 |
| embedding 调用 | ≈ 15–30 次 | 每批 50–100 条 input |
| L1 chat 调用 | ≈ 168 | 6000/700 ≈ 8.5 片一段 |
| L2 chat 调用 | ≈ 9 | 6000/300 ≈ 20 条一组 |
| L3 chat 调用 | 1 | 全书摘要 |
| **合计 chat** | **≈ 178 次** | |

这个量级对单本书可接受，但**必须在开始前展示预估并让用户确认**——否则点一下「生成全书摘要」就是几块钱。也因此默认提供 `read`（已读部分）这一更便宜的范围选项。

### 断点续跑与失效

- 每条 chunk / summary 记 `src_hash`。重新索引时 hash 未变则**跳过**（不重复花钱）。
- 任务中途取消或失败，`ai_index_state.status` 记为 `canceled` / `failed`，已算出的部分保留；再次发起只补缺口。
- embedding 模型或维度变了 → 检索时校验 `emb_model/emb_dim`，不匹配则提示重建索引（避免拿 768 维向量去比 1536 维）。

---

## 五、问答流程（RAG）

```
用户提问
  ├─ ① 问题向量化（无 embedding 配置 → 跳过，走纯关键词）
  ├─ ② 混合召回
  │     ├─ 向量：与全书 chunk 算余弦，top-K（K = 8~12）
  │     └─ 关键词：中文二元切分（bigram）TF-IDF，top-K  ← 无词典依赖，是降级通道也是补充
  │     合并去重后取分数最高的若干片段
  ├─ ③ 上下文装配（受预算约束，见下）
  │     系统提示（角色、引用格式要求）
  │     + 全书摘要（存在时）
  │     + 命中片段所属章节的摘要
  │     + top-K 原文片段，编号 [1]..[K]
  ├─ ④ 流式生成（SSE）→ 节流后逐段 Emit → 前端打字机效果
  └─ ⑤ 落库：问题 + 回答 + refs（含 chunkId / chapterIdx / score）
```

**引用是可点击的**：`refs` 里的 `chapterIdx` 让前端能直接跳到阅读器对应章节并高亮片段（`char_start/char_end` 已存）。这是「基于书籍问答」区别于通用聊天的核心价值。

### 上下文预算

按 `ContextWindow × 0.6` 分配给检索内容，其余留给系统提示与回答空间。优先级：

1. 系统提示（必留）
2. 全书摘要（压缩后很便宜，性价比最高）
3. top-K 原文片段（按分数降序塞，塞满为止）
4. 章节摘要（空间不够时最先舍弃）

`ContextWindow` 未填时按模型名关键词匹配预设档位（8k / 32k / 128k），兜底 8k。

### 中文分词的取舍

不引入分词库（会增加依赖与词典体积）。**二元切分（bigram）**是经典的无词典方案：对短查询效果接近分词，且零依赖。向量召回是主力，关键词只是补充与降级通道，够用。

---

## 六、流式输出与取消

- Go 侧 `net/http` 流式读 SSE，按 `data: ` 行解析，遇 `[DONE]` 结束。
- **节流**：每个 token 都 Emit 会造成 IPC 风暴。累积到 buffer，每 60ms 或满 200 字发一次。
- **取消**：复用 `CacheService` 范式——`context.WithCancel(context.Background())`（绑定方法返回后请求 ctx 已失效，这是项目既有教训）+ goroutine + `job` 登记 + 互斥（同书同时只允许一个索引任务）。
- 新增事件名：`ai:index:progress`、`ai:answer:chunk`、`ai:answer:done`；前端在 `events.ts` 加对应 `onXxx` 订阅函数。

---

## 七、API 契约（`api/ai.go`）

配置类：
- `GetConfig() AIConfigView` / `SaveConfig(cfg)` / `TestConnection(cfg) error`

索引类：
- `IndexStatus(bookID) AIIndexStatusView`
- `StartIndex(bookID, scope, from, to) AIIndexStatusView`（立即返回，进度走事件）
- `CancelIndex(bookID)` / `DeleteIndex(bookID)`

总结类：
- `SummarizeBook(bookID) string`（若索引已完成，直接返回最高层摘要；否则先提示索引）
- `SummarizeChapters(bookID, from, to) string`（不走完整索引链，直接对区间生成，用于「只想看这几章说了啥」的轻量场景）
- `GetSummary(bookID) AISummaryView`

问答类：
- `ListChats(bookID)` / `CreateChat(bookID, scope)` / `DeleteChat(chatID)`
- `GetMessages(chatID)`
- `Ask(chatID, question)`（流式，答案通过 `ai:answer:chunk` 事件推送，结束时 `ai:answer:done` 带 refs）
- `StopAnswer(chatID)`

`Ask` 为何用事件而非返回值：SSE 流式无法等到结束再返回，只能边生成边推。这与书源调试逐行打点（`sourcedebug.go:179`）是同一手法。

---

## 八、前端

| 位置 | 内容 |
| --- | --- |
| **设置页**新增「AI」分区 | BaseURL / Key（掩码显示）/ 模型 / 温度 / 上下文窗口 / embedding 三项（可留空）/ **测试连接**按钮 |
| **书籍详情页**新增「AI」Tab | 索引状态卡片（未索引 / 已索引 N 片 / 失败原因）、范围选择（全书 / 已读 / 区间）、「生成」按钮 + 进度条 + 取消、全书摘要展示、历史会话入口 |
| **阅读器**新增「问 AI」抽屉 | 针对当前章或全书提问，流式回答，**引用可点击跳转并高亮** |
| **会话页** `AIView.vue`（`/ai?book=<id>`） | 多轮问答、历史会话列表、引用来源折叠展示 |

入口设计延续上一轮定下的两端约定：桌面侧栏新增「AI」项；移动端底部 Tab 保持 5 个，AI 从书籍详情 / 阅读器进入，**不作为主 Tab**（9 个 Tab 会让每个不到 60px 宽）。功能集合两端一致，仅入口深度不同。

---

## 九、两端一致性

全部业务逻辑在 Go 层，**安卓端零额外工作量**自动获得。前端页面共用同一套组件，按 `stores/platform.ts` 的 `isMobile` 切换布局（该 store 判定只信后端 `SystemAPI.Platform()`，不用 UA/视口猜）。

`?ui=mobile` 覆盖开关让安卓 UI 能在 Windows 上直接验证（上一轮已建），本轮的前端改动同样用它来测，无需真机。

---

## 十、实施顺序（一次做到位，但按依赖分批验证）

| 批次 | 内容 | 验收方式 |
| --- | --- | --- |
| **M1 通道** | `domain/ai.go`、`port/ai.go`、`adapter/aihttp`（含 SSE + 重试）、配置存取、设置页 AI 区、测试连接 | Windows 上配真实 API 跑通「连接成功」；单测覆盖 SSE 解析与错误分类 |
| **M2 索引** | 迁移 `004_ai.sql`、批量取正文、切片、向量化、摘要链、进度事件、断点续跑 | 对一本已缓存的书建索引，核对 chunk 数/摘要层级/中断后可续跑 |
| **M3 问答** | 混合召回、上下文装配、流式输出、会话与引用、阅读器跳转高亮 | 提细节问题，验证引用准确且能跳转；`?ui=mobile` 下走一遍 |
| **M4 收尾** | MCP 用例（`s9_ai.py`）、架构文档、双端编译与全量回归 | 双端编译 + `go test ./internal/...` + MCP 用例全绿 |

---

## 十一、风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| **成本失控** | 索引长书花真金白银 | 开始前强制展示预估（调用次数 / 大致 token），需确认才发起；提供 `read` 范围 |
| **耗时过长** | 千章书索引可能几十分钟 | 后台任务 + 实时进度 + 可取消 + 断点续跑 |
| **正文未缓存** | 网络书现抓极慢、被限流 | 索引前检查缓存率，低于阈值提示先跑缓存 |
| **模型不听话** | 要求 JSON/引用编号，模型可能不遵守 | prompt 工程 + 容错解析（解析失败降级为纯文本，不报错中断） |
| **embedding 不可用** | DeepSeek 等无 embedding 接口 | 独立配置项；留空降级为 bigram 关键词召回，功能不残废 |
| **维度漂移** | 换模型后旧向量失效 | 存 `emb_model/emb_dim`，检索前校验，不匹配提示重建 |
| **密钥泄漏** | 明文落库 | 沿用 WebDAV 实践：视图层不回传明文；后续可引入 DPAPI 加密（`SettingsStore` 已是统一入口，改造点集中） |

---

## 十二、待确认

1. **默认范围**：索引默认「全书」还是「已读」？前者信息全但贵，后者便宜。—— 倾向默认「已读」，全书需显式选择。
2. **是否自动索引**：加入书架时后台自动建索引（花钱且耗电） vs 始终手动触发。—— 倾向**手动**，避免静默产生费用。
3. **摘要链层级上限**：是否需要限制最高层数（比如最多 3 层，避免超长书产生过多调用）。—— 倾向不硬限，但用 `summary_total` 在进度里暴露，让用户可中途取消。

### 实施结果（M1–M3 已完成，当前取值）

| 项 | 当前实现 | 改动位置 |
| --- | --- | --- |
| 默认范围 | 读过这本书（有阅读进度）默认「已读」，否则「全书」 | `AIPanel.vue` 的 `load()` |
| 自动索引 | **手动**：只在用户点「生成索引」时才调用模型，加书/缓存都不触发 | `AIIndexStore.start()` 是唯一入口 |
| 层级上限 | 不硬限，递归归并到只剩 1 条；进度分母随层累加，用户可随时取消 | `buildSummaryChain()` / `SummaryTotal` |

三项若要改都只动一处，不需要改数据结构。其余实现约束见 `desktop/ARCHITECTURE.md` §12。
