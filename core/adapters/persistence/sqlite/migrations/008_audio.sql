-- 音频书（bookSourceType=1）必须保留 Legado 的 Book.type 位域：
-- 前端靠它把「开始阅读」切成「开始听书」，书源 JS 也会直接读 book.type。
--
-- 默认值 8 = Kotlin 原版 BookType.text，老库里的文本书无需回填即可对齐；
-- 音频书入库时显式写 32（BookType.audio），漫画/下载站同理按位或。
-- 注意 1/2/4/16 是原版保留位，不要用 1 表示文本、2 表示音频。
ALTER TABLE books ADD COLUMN type INTEGER NOT NULL DEFAULT 8;
