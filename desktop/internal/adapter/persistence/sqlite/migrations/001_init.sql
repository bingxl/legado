-- 初始 schema

CREATE TABLE books (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    name               TEXT    NOT NULL,
    author             TEXT    NOT NULL DEFAULT '',
    intro              TEXT    NOT NULL DEFAULT '',
    cover_url          TEXT    NOT NULL DEFAULT '',
    kind               TEXT    NOT NULL,             -- web | local
    format             TEXT    NOT NULL,             -- epub | txt | pdf | comic | unknown
    origin             TEXT    NOT NULL,             -- 书源 URL 或 local
    book_url           TEXT    NOT NULL,             -- 详情页 URL 或本地文件绝对路径
    group_id           INTEGER NOT NULL DEFAULT 0,
    sort_order         INTEGER NOT NULL DEFAULT 0,
    total_chapters     INTEGER NOT NULL DEFAULT 0,
    last_chapter       TEXT    NOT NULL DEFAULT '',
    dur_chapter_index  INTEGER NOT NULL DEFAULT 0,
    dur_chapter_title  TEXT    NOT NULL DEFAULT '',
    dur_chapter_pos    INTEGER NOT NULL DEFAULT 0,
    created_at         DATETIME NOT NULL,
    updated_at         DATETIME NOT NULL,
    last_read_at       DATETIME
);

-- 同一来源下的同一本书唯一，用于导入去重。
CREATE UNIQUE INDEX IF NOT EXISTS idx_books_origin_url ON books (origin, book_url);
CREATE INDEX IF NOT EXISTS idx_books_group ON books (group_id, sort_order);

CREATE TABLE book_groups (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    show       INTEGER NOT NULL DEFAULT 1,
    built_in   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE book_chapters (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id   INTEGER NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    idx       INTEGER NOT NULL,
    title     TEXT    NOT NULL DEFAULT '',
    url       TEXT    NOT NULL DEFAULT '',
    resource  TEXT    NOT NULL DEFAULT '',
    is_volume INTEGER NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_chapters_book_idx ON book_chapters (book_id, idx);
CREATE INDEX IF NOT EXISTS idx_chapters_book ON book_chapters (book_id);

CREATE TABLE reading_progress (
    book_id        INTEGER PRIMARY KEY REFERENCES books (id) ON DELETE CASCADE,
    chapter_index  INTEGER NOT NULL DEFAULT 0,
    chapter_title  TEXT    NOT NULL DEFAULT '',
    chapter_pos    INTEGER NOT NULL DEFAULT 0,
    scroll_percent REAL    NOT NULL DEFAULT 0,
    updated_at     DATETIME NOT NULL
);

-- 书源：raw 存 Legado 原始 JSON，管理字段冗余成列以支持查询与排序。
CREATE TABLE book_sources (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    name           TEXT    NOT NULL DEFAULT '',
    group_name     TEXT    NOT NULL DEFAULT '',
    url            TEXT    NOT NULL,
    enabled        INTEGER NOT NULL DEFAULT 1,
    sort_order     INTEGER NOT NULL DEFAULT 0,
    comment        TEXT    NOT NULL DEFAULT '',
    raw            TEXT    NOT NULL DEFAULT '',
    last_update_at DATETIME,
    created_at     DATETIME NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_sources_url ON book_sources (url);
CREATE INDEX IF NOT EXISTS idx_sources_group ON book_sources (group_name, sort_order);

CREATE TABLE source_subscriptions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT    NOT NULL,
    url          TEXT    NOT NULL,
    enabled      INTEGER NOT NULL DEFAULT 1,
    sort_order   INTEGER NOT NULL DEFAULT 0,
    last_sync_at DATETIME,
    created_at   DATETIME NOT NULL
);

CREATE TABLE replace_rules (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL DEFAULT '',
    group_name TEXT    NOT NULL DEFAULT '',
    enabled    INTEGER NOT NULL DEFAULT 1,
    sort_order INTEGER NOT NULL DEFAULT 0,
    raw        TEXT    NOT NULL DEFAULT ''
);

CREATE TABLE txt_toc_rules (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL DEFAULT '',
    rule       TEXT    NOT NULL DEFAULT '',
    enabled    INTEGER NOT NULL DEFAULT 1,
    sort_order INTEGER NOT NULL DEFAULT 0
);

-- 应用级键值配置（WebDAV 配置等），避免为少量配置单独建表。
CREATE TABLE app_settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL DEFAULT '',
    updated_at DATETIME NOT NULL
);

-- 内置分组：未分组与默认书架。
INSERT OR IGNORE INTO book_groups (id, name, sort_order, show, built_in)
VALUES (1, '全部', 0, 1, 1);
