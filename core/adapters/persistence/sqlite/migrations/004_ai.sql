-- AI 总结与问答：语义切片、分层摘要、索引进度、会话消息。
--
-- 时间列统一用 INTEGER（Unix 秒），与 chapter_cache.created_at 保持一致：
-- 用 DATETIME 时 sqlite 的 MAX() 会返回字符串，扫进 time.Time 容易出问题。

-- ① 语义切片：向量检索与引用溯源的粒度。
--
-- 为什么按固定 token 预算切片而不是按章存：章节长度差异极大（几百字到几万字），
-- 按章检索会召回大量无关内容；切片才能让召回粒度稳定。
CREATE TABLE ai_chunks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id     INTEGER NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    chapter_idx INTEGER NOT NULL,
    ordinal     INTEGER NOT NULL,               -- 书内全局序号，保证顺序可还原
    char_start  INTEGER NOT NULL DEFAULT 0,      -- 在章节纯文本内的偏移，供阅读器高亮
    char_end    INTEGER NOT NULL DEFAULT 0,
    title       TEXT    NOT NULL DEFAULT '',
    text        TEXT    NOT NULL,
    token_count INTEGER NOT NULL DEFAULT 0,
    src_hash    TEXT    NOT NULL DEFAULT '',     -- 源文本哈希；未变则跳过重算
    embedding   BLOB,                            -- float32 小端序列；NULL = 未向量化
    emb_model   TEXT    NOT NULL DEFAULT '',
    emb_dim     INTEGER NOT NULL DEFAULT 0,
    created_at  INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_chunks_book_ord ON ai_chunks (book_id, ordinal);
CREATE INDEX IF NOT EXISTS idx_ai_chunks_book_chapter ON ai_chunks (book_id, chapter_idx);

-- ② 分层摘要：level 1 = 由原文切片合并出的段摘要，向上递归直到全书摘要。
CREATE TABLE ai_summaries (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id      INTEGER NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    level        INTEGER NOT NULL,
    ordinal      INTEGER NOT NULL,
    parent_level INTEGER NOT NULL DEFAULT 0,     -- 0 表示无父（顶层）
    parent_ord   INTEGER NOT NULL DEFAULT 0,
    chapter_from INTEGER NOT NULL DEFAULT -1,    -- -1 表示不适用
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

CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_summaries_book_lv_ord
    ON ai_summaries (book_id, level, ordinal);

-- ③ 索引状态：断点续跑的依据。
--
-- 索引一本长书可能耗时几十分钟且要花钱，进程重启后必须知道「算到哪了」，
-- 所以目标范围与各项计数都要落库，不能只留在内存里。
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

-- ④ 会话与消息。
CREATE TABLE ai_chats (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id    INTEGER NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    title      TEXT    NOT NULL DEFAULT '',
    scope      TEXT    NOT NULL DEFAULT 'book',
    model      TEXT    NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ai_chats_book ON ai_chats (book_id, updated_at DESC);

CREATE TABLE ai_messages (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id    INTEGER NOT NULL REFERENCES ai_chats (id) ON DELETE CASCADE,
    role       TEXT    NOT NULL,
    content    TEXT    NOT NULL,
    refs       TEXT    NOT NULL DEFAULT '',   -- JSON 数组：[{chunkId,chapterIdx,title,score}]
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ai_messages_chat ON ai_messages (chat_id, id);
