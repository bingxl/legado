-- 书籍变量：保存书源在列表页 @put 出来的变量（JSON 对象串）。
--
-- 有些书源的目录/正文地址要靠这些变量拼（例如 "…/book/@get:{book}/volumes"），
-- 之前桌面端没有存，导致这类书源加进书架后目录永远是空的。

ALTER TABLE books ADD COLUMN variable TEXT NOT NULL DEFAULT '';
