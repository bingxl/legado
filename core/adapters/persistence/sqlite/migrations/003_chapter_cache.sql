-- 章节内容缓存：支持按章节 / 整本手动缓存后离线阅读。
--
-- 只缓存「抓取过一次」的结果，不做自动过期；目录更新导致章节地址变化时，
-- 应用层用 url 列判断缓存是否仍然有效（不匹配即视为未缓存）。
-- 漫画的图片本体落在磁盘（cache/chapter/<bookId>/<idx>/），这里只存地址列表。
CREATE TABLE chapter_cache (
    book_id    INTEGER NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    idx        INTEGER NOT NULL,
    title      TEXT    NOT NULL DEFAULT '',
    url        TEXT    NOT NULL DEFAULT '',
    html       TEXT    NOT NULL DEFAULT '',
    images     TEXT    NOT NULL DEFAULT '',   -- JSON 数组，本地可访问地址
    size       INTEGER NOT NULL DEFAULT 0,    -- 正文长度或图片字节数之和
    -- 存 Unix 秒而不是 DATETIME：这一列主要用于 MAX() 聚合（缓存管理按最近缓存排序），
    -- 而 SQLite 的聚合会丢掉列类型，驱动把 DATETIME 以 Go 的时间字符串返回，
    -- 扫描/比较都得再做一次解析。整数没有这个问题。
    created_at INTEGER NOT NULL,
    -- 主键自带 (book_id, idx) 索引，按书查询/聚合走它即可，不再额外建索引。
    PRIMARY KEY (book_id, idx)
);
