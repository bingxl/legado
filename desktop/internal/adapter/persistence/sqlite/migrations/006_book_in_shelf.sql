-- 书籍是否在书架：区分「已加入书架」与「仅试读」。
--
-- 发现/搜索里点开一本书只是试读，不该自动出现在书架（原版也是显式
-- 「加入书架」才入架）。但阅读进度、目录、正文都依赖 books.id，
-- 所以试读仍要落库，只是标记为不在书架，书架列表查询时过滤掉。
--
-- 默认 1：历史数据与所有既有创建路径（本地导入、WebDAV、命令行工具）
-- 都是「在架」，升级后行为不变。
ALTER TABLE books ADD COLUMN in_shelf INTEGER NOT NULL DEFAULT 1;

CREATE INDEX IF NOT EXISTS idx_books_in_shelf ON books (in_shelf);
