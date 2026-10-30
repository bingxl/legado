package sqlite

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// BookRepo 实现 port.BookRepository。
type BookRepo struct {
	db *DB
}

// NewBookRepo 创建书籍仓储。
func NewBookRepo(db *DB) *BookRepo { return &BookRepo{db: db} }

// 编译期断言。
var _ port.BookRepository = (*BookRepo)(nil)

const bookColumns = `id, name, author, intro, cover_url, kind, format, origin, book_url,
	group_id, sort_order, total_chapters, last_chapter, dur_chapter_index, dur_chapter_title,
	dur_chapter_pos, created_at, updated_at, last_read_at, variable`

// Create 插入一本书并回填主键。
func (r *BookRepo) Create(ctx context.Context, b *domain.Book) error {
	if b.Name == "" {
		return fmt.Errorf("%w: 书名不能为空", domain.ErrInvalidArgument)
	}
	now := time.Now()
	if b.CreatedAt.IsZero() {
		b.CreatedAt = now
	}
	if b.UpdatedAt.IsZero() {
		b.UpdatedAt = now
	}

	const query = `INSERT INTO books (` + bookColumns + `)
		VALUES (NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		RETURNING id`
	// bookColumns 含 id，故需 19 个占位符（不含 id）。
	args := []any{
		b.Name, b.Author, b.Intro, b.CoverURL, string(b.Kind), string(b.Format),
		b.Origin, b.BookURL, b.GroupID, b.Order, b.TotalChapters, b.LastChapter,
		b.DurChapterIndex, b.DurChapterTitle, b.DurChapterPos,
		b.CreatedAt, b.UpdatedAt, nullableTime(b.LastReadAt), b.Variable,
	}
	row := r.db.q(ctx).QueryRowContext(ctx, query, args...)
	if err := row.Scan(&b.ID); err != nil {
		if isUniqueViolation(err) {
			return fmt.Errorf("%w: 书架中已存在该书", domain.ErrAlreadyExists)
		}
		return fmt.Errorf("新增书籍失败: %w", err)
	}
	return nil
}

// Update 更新书籍的可变字段。ID 为 0 时返回参数错误。
func (r *BookRepo) Update(ctx context.Context, b *domain.Book) error {
	if b.ID == 0 {
		return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	b.UpdatedAt = time.Now()
	const query = `UPDATE books SET name=?, author=?, intro=?, cover_url=?, kind=?, format=?,
		group_id=?, sort_order=?, total_chapters=?, last_chapter=?, dur_chapter_index=?,
		dur_chapter_title=?, dur_chapter_pos=?, variable=?, updated_at=?, last_read_at=? WHERE id=?`
	res, err := r.db.q(ctx).ExecContext(ctx, query,
		b.Name, b.Author, b.Intro, b.CoverURL, string(b.Kind), string(b.Format),
		b.GroupID, b.Order, b.TotalChapters, b.LastChapter,
		b.DurChapterIndex, b.DurChapterTitle, b.DurChapterPos, b.Variable,
		b.UpdatedAt, nullableTime(b.LastReadAt), b.ID)
	if err != nil {
		return fmt.Errorf("更新书籍失败: %w", err)
	}
	return ensureAffected(res, domain.ErrNotFound, "书籍不存在")
}

// Delete 删除书籍（章节与进度由外键级联删除）。
func (r *BookRepo) Delete(ctx context.Context, id int64) error {
	res, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM books WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("删除书籍失败: %w", err)
	}
	return ensureAffected(res, domain.ErrNotFound, "书籍不存在")
}

// Get 按主键取书。
func (r *BookRepo) Get(ctx context.Context, id int64) (*domain.Book, error) {
	row := r.db.q(ctx).QueryRowContext(ctx, `SELECT `+bookColumns+` FROM books WHERE id = ?`, id)
	b, err := scanBook(row)
	if err != nil {
		return nil, normalizeError(err)
	}
	return b, nil
}

// FindByURL 按来源 + URL 定位书籍。
func (r *BookRepo) FindByURL(ctx context.Context, origin, bookURL string) (*domain.Book, error) {
	row := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT `+bookColumns+` FROM books WHERE origin = ? AND book_url = ?`, origin, bookURL)
	b, err := scanBook(row)
	if err != nil {
		return nil, normalizeError(err)
	}
	return b, nil
}

// List 列出指定分组的书籍；groupID 为 0 表示全部。
func (r *BookRepo) List(ctx context.Context, groupID int64) ([]*domain.Book, error) {
	query := `SELECT ` + bookColumns + ` FROM books`
	args := []any{}
	if groupID > 0 {
		query += ` WHERE group_id = ?`
		args = append(args, groupID)
	}
	query += ` ORDER BY sort_order ASC, updated_at DESC`

	rows, err := r.db.q(ctx).QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("查询书籍列表失败: %w", err)
	}
	defer rows.Close()

	var out []*domain.Book
	for rows.Next() {
		b, err := scanBook(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// UpdateProgress 只更新进度字段，避免整行覆盖造成的写冲突。
func (r *BookRepo) UpdateProgress(ctx context.Context, id int64, chapterIndex int, chapterTitle string, chapterPos int) error {
	res, err := r.db.q(ctx).ExecContext(ctx,
		`UPDATE books SET dur_chapter_index=?, dur_chapter_title=?, dur_chapter_pos=?, last_read_at=? WHERE id=?`,
		chapterIndex, chapterTitle, chapterPos, time.Now(), id)
	if err != nil {
		return fmt.Errorf("更新阅读进度失败: %w", err)
	}
	return ensureAffected(res, domain.ErrNotFound, "书籍不存在")
}

// scanner 是 *sql.Row 与 *sql.Rows 的公共 Scan 子集。
type scanner interface{ Scan(dest ...any) error }

// scanBook 从一行结果构造 Book。last_read_at 允许为 NULL。
func scanBook(s scanner) (*domain.Book, error) {
	var (
		b                    domain.Book
		kind, format         string
		lastReadAt           sql.NullTime
		createdAt, updatedAt time.Time
	)
	err := s.Scan(
		&b.ID, &b.Name, &b.Author, &b.Intro, &b.CoverURL, &kind, &format,
		&b.Origin, &b.BookURL, &b.GroupID, &b.Order, &b.TotalChapters, &b.LastChapter,
		&b.DurChapterIndex, &b.DurChapterTitle, &b.DurChapterPos,
		&createdAt, &updatedAt, &lastReadAt, &b.Variable,
	)
	if err != nil {
		return nil, err
	}
	b.Kind = domain.BookKind(kind)
	b.Format = domain.BookFormat(format)
	b.CreatedAt = createdAt
	b.UpdatedAt = updatedAt
	if lastReadAt.Valid {
		b.LastReadAt = lastReadAt.Time
	}
	return &b, nil
}

// nullableTime 把零值时间转为 NULL，避免写入 0001-01-01。
func nullableTime(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t
}

// ensureAffected 校验受影响行数，为 0 时返回指定错误。
func ensureAffected(res sql.Result, err error, msg string) error {
	n, e := res.RowsAffected()
	if e != nil {
		return e
	}
	if n == 0 {
		return fmt.Errorf("%w: %s", err, msg)
	}
	return nil
}

// isUniqueViolation 判断是否为唯一约束冲突。
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	// modernc.org/sqlite 的错误文本形如 "constraint failed: UNIQUE constraint failed: books.origin, ... (2067)"
	msg := err.Error()
	return strings.Contains(msg, "UNIQUE constraint failed") ||
		strings.Contains(msg, "constraint failed") && strings.Contains(msg, "UNIQUE")
}
