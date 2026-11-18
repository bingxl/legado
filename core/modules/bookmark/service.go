package bookmark

import (
	"context"
	"database/sql"

	"github.com/legado/core/adapters/persistence/sqlite"
	"github.com/legado/core/kernel"
)

// ProgressReader 读取「这本书现在读到哪一章」。
//
// 为什么要在这里定义接口，而不是 import core/app：
//  1. core/app 是 Wails 时代的胖服务层，模块依赖它会形成 app → modules → app 的环；
//  2. 书签和流水只需要一个章节号，把整个书架服务拖进来是过度耦合；
//  3. 装配层（boot/hosts）可以写一行适配器，把 Shelf.GetProgress 转成这个形状。
//
// 未注入（nil）时一律降级，见 resolveChapter。
type ProgressReader interface {
	Get(ctx context.Context, bookID int64) (chapterIndex int, err error)
}

const (
	// defaultListLimit 是调用方不传 limit 时的上限。
	// 书签与流水都不是「读全表」的场景，一次给 200 条足够铺满任意屏幕，
	// 又不会因为某本书攒了几千条书签而把控制面报文撑爆。
	defaultListLimit = 200
	// maxListLimit 防止前端传一个巨大的 limit 绕过上面的考虑。
	maxListLimit = 1000
)

// normalizeLimit 把外部传入的 limit 收敛到合理区间。
func normalizeLimit(limit int) int {
	if limit <= 0 {
		return defaultListLimit
	}
	if limit > maxListLimit {
		return maxListLimit
	}
	return limit
}

// BookmarkService 负责书签的增删改查。
type BookmarkService struct {
	db       *sqlite.DB
	progress ProgressReader
}

// NewBookmarkService 构造书签服务。progress 可为 nil。
func NewBookmarkService(db *sqlite.DB, progress ProgressReader) *BookmarkService {
	return &BookmarkService{db: db, progress: progress}
}

// Add 新增书签。参数顺序即控制面位置参数顺序。
//
// chapterIndex 传负数表示「当前位置」：阅读器在当前位置加书签时
// 不必先查一次进度再回传，少一次往返也就少一个竞态窗口。
func (s *BookmarkService) Add(ctx context.Context, bookID int64, chapterIndex int, chapterTitle string, chapterPos int, content, note string) (BookmarkItem, error) {
	if bookID <= 0 {
		return BookmarkItem{}, kernel.Ef(kernel.CodeInvalid, "缺少书籍 ID")
	}
	chapterIndex = resolveChapter(ctx, s.progress, bookID, chapterIndex)

	res, err := s.db.Execute(ctx, `INSERT INTO bookmark
		(book_id, chapter_index, chapter_title, chapter_pos, content, note)
		VALUES (?, ?, ?, ?, ?, ?)`,
		bookID, chapterIndex, chapterTitle, chapterPos, content, note)
	if err != nil {
		return BookmarkItem{}, kernel.Ef(kernel.CodeInternal, "新增书签失败: %v", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return BookmarkItem{}, kernel.Ef(kernel.CodeInternal, "新增书签后取 ID 失败: %v", err)
	}
	// 回读 created_at 而不是用 time.Now()：值由库里的 unixepoch() 生成，
	// 回读才能保证返回值与后续 List 排序用的是同一个时间基准。
	return s.get(ctx, id)
}

// List 列出书签。bookID 为 0 表示全部书，按创建时间倒序。
func (s *BookmarkService) List(ctx context.Context, bookID int64, limit int) ([]BookmarkItem, error) {
	if bookID < 0 {
		return nil, kernel.Ef(kernel.CodeInvalid, "书籍 ID 不能为负")
	}
	limit = normalizeLimit(limit)

	query := `SELECT id, book_id, chapter_index, chapter_title, chapter_pos, content, note, created_at
		FROM bookmark`
	args := make([]any, 0, 2)
	if bookID > 0 {
		query += ` WHERE book_id = ?`
		args = append(args, bookID)
	}
	// id 兜底排序：同一秒内加的多条书签，仅按 created_at 顺序不稳定。
	query += ` ORDER BY created_at DESC, id DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.db.Query(ctx, query, args...)
	if err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "查询书签失败: %v", err)
	}
	defer rows.Close()

	// 用非 nil 空切片：JSON 序列化成 [] 而不是 null，前端不必判空。
	out := make([]BookmarkItem, 0, limit)
	for rows.Next() {
		it, err := scanBookmark(rows)
		if err != nil {
			return nil, kernel.Ef(kernel.CodeInternal, "读取书签行失败: %v", err)
		}
		out = append(out, it)
	}
	if err := rows.Err(); err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "遍历书签失败: %v", err)
	}
	return out, nil
}

// Remove 删除书签。删不存在的行返回 NOT_FOUND 而不是静默成功：
// 前端据此提示「书签已被其他窗口删除」。
func (s *BookmarkService) Remove(ctx context.Context, id int64) error {
	if id <= 0 {
		return kernel.Ef(kernel.CodeInvalid, "缺少书签 ID")
	}
	res, err := s.db.Execute(ctx, `DELETE FROM bookmark WHERE id = ?`, id)
	if err != nil {
		return kernel.Ef(kernel.CodeInternal, "删除书签失败: %v", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return kernel.Ef(kernel.CodeInternal, "删除书签后取影响行数失败: %v", err)
	}
	if n == 0 {
		return kernel.Ef(kernel.CodeNotFound, "书签不存在: %d", id)
	}
	return nil
}

// UpdateNote 修改书签备注（只改备注，避免误改正文与位置）。
func (s *BookmarkService) UpdateNote(ctx context.Context, id int64, note string) error {
	if id <= 0 {
		return kernel.Ef(kernel.CodeInvalid, "缺少书签 ID")
	}
	res, err := s.db.Execute(ctx, `UPDATE bookmark SET note = ? WHERE id = ?`, note, id)
	if err != nil {
		return kernel.Ef(kernel.CodeInternal, "修改书签备注失败: %v", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return kernel.Ef(kernel.CodeInternal, "修改备注后取影响行数失败: %v", err)
	}
	if n == 0 {
		return kernel.Ef(kernel.CodeNotFound, "书签不存在: %d", id)
	}
	return nil
}

// CountByBook 统计某本书的书签数，供目录页角标使用。
func (s *BookmarkService) CountByBook(ctx context.Context, bookID int64) (int, error) {
	if bookID <= 0 {
		return 0, kernel.Ef(kernel.CodeInvalid, "缺少书籍 ID")
	}
	var n int
	if err := s.db.QueryRow(ctx, `SELECT COUNT(1) FROM bookmark WHERE book_id = ?`, bookID).Scan(&n); err != nil {
		return 0, kernel.Ef(kernel.CodeInternal, "统计书签数失败: %v", err)
	}
	return n, nil
}

// get 按 ID 读取一条书签。
func (s *BookmarkService) get(ctx context.Context, id int64) (BookmarkItem, error) {
	it, err := scanBookmark(s.db.QueryRow(ctx, `SELECT id, book_id, chapter_index, chapter_title,
		chapter_pos, content, note, created_at FROM bookmark WHERE id = ?`, id))
	if err == sql.ErrNoRows {
		return BookmarkItem{}, kernel.Ef(kernel.CodeNotFound, "书签不存在: %d", id)
	}
	if err != nil {
		return BookmarkItem{}, kernel.Ef(kernel.CodeInternal, "读取书签失败: %v", err)
	}
	return it, nil
}

// scanner 抽象 *sql.Row 与 *sql.Rows 的公共能力，让单行与多行读取共用一份扫描代码。
type scanner interface {
	Scan(dest ...any) error
}

// scanBookmark 按固定列序扫描一行书签。
func scanBookmark(sc scanner) (BookmarkItem, error) {
	var (
		it        BookmarkItem
		createdAt int64
	)
	if err := sc.Scan(&it.ID, &it.BookID, &it.ChapterIndex, &it.ChapterTitle,
		&it.ChapterPos, &it.Content, &it.Note, &createdAt); err != nil {
		return BookmarkItem{}, err
	}
	it.CreatedAt = unixTime(createdAt)
	return it, nil
}

// RecordService 负责阅读记录流水。
//
// 与 Shelf.SaveProgress 的分工：Shelf 维护「当前值」（books 表上的 durChapterIndex），
// 本服务维护「流水」（每次换章留一条痕迹），供阅读统计与历史页使用。
type RecordService struct {
	db       *sqlite.DB
	progress ProgressReader
}

// NewRecordService 构造阅读记录服务。progress 可为 nil。
func NewRecordService(db *sqlite.DB, progress ProgressReader) *RecordService {
	return &RecordService{db: db, progress: progress}
}

// Append 追加一条阅读记录。
//
// 去重规则：同一本书、同一天、同一章只留一条。重复打开同一章不会把流水刷屏，
// 但会刷新 read_at —— 历史页展示的「最近阅读」应当是最新一次的时间。
// 「同一天」按本地时区切日，与 Stats 的口径保持一致。
//
// 实现用 INSERT ... WHERE NOT EXISTS 一条语句完成判断，
// 而不是「先 SELECT 再 INSERT」：后者在并发写入下会插出两条重复记录。
func (s *RecordService) Append(ctx context.Context, bookID int64, bookName string, chapterIndex int, chapterTitle string) (RecordItem, error) {
	if bookID <= 0 {
		return RecordItem{}, kernel.Ef(kernel.CodeInvalid, "缺少书籍 ID")
	}
	chapterIndex = resolveChapter(ctx, s.progress, bookID, chapterIndex)

	res, err := s.db.Execute(ctx, `INSERT INTO read_record
		(book_id, book_name, chapter_index, chapter_title)
		SELECT ?, ?, ?, ?
		WHERE NOT EXISTS (
			SELECT 1 FROM read_record
			WHERE book_id = ? AND chapter_index = ?
			  AND date(read_at, 'unixepoch', 'localtime') = date('now', 'localtime')
		)`,
		bookID, bookName, chapterIndex, chapterTitle, bookID, chapterIndex)
	if err != nil {
		return RecordItem{}, kernel.Ef(kernel.CodeInternal, "写入阅读记录失败: %v", err)
	}

	n, err := res.RowsAffected()
	if err != nil {
		return RecordItem{}, kernel.Ef(kernel.CodeInternal, "写入阅读记录后取影响行数失败: %v", err)
	}

	var id int64
	if n > 0 {
		id, err = res.LastInsertId()
		if err != nil {
			return RecordItem{}, kernel.Ef(kernel.CodeInternal, "写入阅读记录后取 ID 失败: %v", err)
		}
	} else {
		// 今天已经记过这一章：把已有行的书名/标题与时间刷新到最新。
		// 先查 id 再按主键 UPDATE，而不是把日期条件塞进 UPDATE 的 WHERE ——
		// read_at 会在这条语句里被改写，条件与赋值同处一条语句时很难推理结果。
		err = s.db.QueryRow(ctx, `SELECT id FROM read_record
			WHERE book_id = ? AND chapter_index = ?
			  AND date(read_at, 'unixepoch', 'localtime') = date('now', 'localtime')
			ORDER BY read_at DESC, id DESC LIMIT 1`, bookID, chapterIndex).Scan(&id)
		if err == sql.ErrNoRows {
			// 极端情况：查重与回查之间记录被 Clear 掉了。
			// 此时按新记录插入，语义上仍等于「刚刚读了这一章」。
			return s.insertOnly(ctx, bookID, bookName, chapterIndex, chapterTitle)
		}
		if err != nil {
			return RecordItem{}, kernel.Ef(kernel.CodeInternal, "查询已有阅读记录失败: %v", err)
		}
		if _, err := s.db.Execute(ctx, `UPDATE read_record
			SET book_name = ?, chapter_title = ?, read_at = unixepoch() WHERE id = ?`,
			bookName, chapterTitle, id); err != nil {
			return RecordItem{}, kernel.Ef(kernel.CodeInternal, "刷新阅读记录时间失败: %v", err)
		}
	}

	it, err := scanRecord(s.db.QueryRow(ctx, `SELECT id, book_id, book_name, chapter_index,
		chapter_title, read_at FROM read_record WHERE id = ?`, id))
	if err != nil {
		return RecordItem{}, kernel.Ef(kernel.CodeInternal, "回读阅读记录失败: %v", err)
	}
	return it, nil
}

// insertOnly 是无去重保护的兜底插入，仅在查重与更新之间记录被删除时使用。
func (s *RecordService) insertOnly(ctx context.Context, bookID int64, bookName string, chapterIndex int, chapterTitle string) (RecordItem, error) {
	res, err := s.db.Execute(ctx, `INSERT INTO read_record (book_id, book_name, chapter_index, chapter_title)
		VALUES (?, ?, ?, ?)`, bookID, bookName, chapterIndex, chapterTitle)
	if err != nil {
		return RecordItem{}, kernel.Ef(kernel.CodeInternal, "写入阅读记录失败: %v", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return RecordItem{}, kernel.Ef(kernel.CodeInternal, "写入阅读记录后取 ID 失败: %v", err)
	}
	it, err := scanRecord(s.db.QueryRow(ctx, `SELECT id, book_id, book_name, chapter_index,
		chapter_title, read_at FROM read_record WHERE id = ?`, id))
	if err != nil {
		return RecordItem{}, kernel.Ef(kernel.CodeInternal, "回读阅读记录失败: %v", err)
	}
	return it, nil
}

// List 按时间倒序分页列出阅读记录。
func (s *RecordService) List(ctx context.Context, offset, limit int) ([]RecordItem, error) {
	if offset < 0 {
		offset = 0
	}
	limit = normalizeLimit(limit)

	rows, err := s.db.Query(ctx, `SELECT id, book_id, book_name, chapter_index, chapter_title, read_at
		FROM read_record ORDER BY read_at DESC, id DESC LIMIT ? OFFSET ?`, limit, offset)
	if err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "查询阅读记录失败: %v", err)
	}
	defer rows.Close()

	out := make([]RecordItem, 0, limit)
	for rows.Next() {
		it, err := scanRecord(rows)
		if err != nil {
			return nil, kernel.Ef(kernel.CodeInternal, "读取阅读记录行失败: %v", err)
		}
		out = append(out, it)
	}
	if err := rows.Err(); err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "遍历阅读记录失败: %v", err)
	}
	return out, nil
}

// Clear 清理阅读记录，返回删除条数。
//
// beforeDays <= 0 表示全部清空（0 就是「清除所有阅读记录」，不做特殊编码）；
// 大于 0 时按「N 天前的 24 小时」切分，与原生版「清除 N 天前的记录」一致。
func (s *RecordService) Clear(ctx context.Context, beforeDays int) (int64, error) {
	var (
		res sql.Result
		err error
	)
	if beforeDays <= 0 {
		res, err = s.db.Execute(ctx, `DELETE FROM read_record`)
	} else {
		res, err = s.db.Execute(ctx, `DELETE FROM read_record WHERE read_at < unixepoch() - ?`,
			int64(beforeDays)*86400)
	}
	if err != nil {
		return 0, kernel.Ef(kernel.CodeInternal, "清理阅读记录失败: %v", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, kernel.Ef(kernel.CodeInternal, "清理阅读记录后取影响行数失败: %v", err)
	}
	return n, nil
}

// Stats 聚合阅读统计。
func (s *RecordService) Stats(ctx context.Context) (RecordStats, error) {
	var st RecordStats
	// 天数按本地时区切：用户说的「今天读了」就是本地日历日，
	// 用 UTC 切会让东八区凌晨 0~8 点的阅读被算到前一天。
	err := s.db.QueryRow(ctx, `SELECT
		COUNT(DISTINCT date(read_at, 'unixepoch', 'localtime')),
		COUNT(DISTINCT book_id),
		COUNT(1)
		FROM read_record`).Scan(&st.Days, &st.Books, &st.Records)
	if err != nil {
		return RecordStats{}, kernel.Ef(kernel.CodeInternal, "统计阅读记录失败: %v", err)
	}
	return st, nil
}

// scanRecord 按固定列序扫描一行阅读记录。
func scanRecord(sc scanner) (RecordItem, error) {
	var (
		it     RecordItem
		readAt int64
	)
	if err := sc.Scan(&it.ID, &it.BookID, &it.BookName, &it.ChapterIndex,
		&it.ChapterTitle, &readAt); err != nil {
		return RecordItem{}, err
	}
	it.ReadAt = unixTime(readAt)
	return it, nil
}

// resolveChapter 把「负数表示当前位置」翻译成真实章节号。
//
// 降级策略：没有注入进度读取器、读取失败、或读回的仍是负数时，
// 一律退回 0。书签与阅读记录是标记/流水类数据，为了一个精确章节号
// 让写入失败会把「打开书就记一条流水」这种后台行为变成可见错误，代价更高。
func resolveChapter(ctx context.Context, p ProgressReader, bookID int64, chapterIndex int) int {
	if chapterIndex >= 0 {
		return chapterIndex
	}
	if p == nil {
		return 0
	}
	idx, err := p.Get(ctx, bookID)
	if err != nil || idx < 0 {
		return 0
	}
	return idx
}
