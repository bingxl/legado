-- 书源自定义变量（对应 Legado 的 sourceVariable 缓存条目）。
--
-- 原生把源变量存在 CacheManager 的 `sourceVariable_<bookSourceUrl>` 键下，
-- 桌面端没有那套缓存层，用一张小表表达同样的语义：按书源地址存一份任意文本，
-- 供书源 JS 里的 source.getVariable() 读取。主键跟登录信息一样用书源地址——
-- 换 id 或重新导入同一份书源都不该丢变量。
CREATE TABLE IF NOT EXISTS source_variables (
    book_source_url TEXT PRIMARY KEY,
    variable        TEXT     NOT NULL DEFAULT '',
    updated_at      DATETIME NOT NULL
);
