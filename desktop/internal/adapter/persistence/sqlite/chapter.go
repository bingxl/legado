package sqlite

import (
	"context"
	"fmt"
	"time"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ChapterRepo 实现 port.ChapterRepository。
type ChapterRepo struct {
	db *DB
}

// NewChapterRepo 创建章节仓储。
func NewChapterRepo(db *DB) *ChapterRepo { return &ChapterRepo{db: db} }

var _ port.ChapterRepository = (*ChapterRepo)(nil)

// ReplaceAll 以原子方式替换某本书的全部章节。
// 先删除旧章节再批量插入，调用方应包裹在事务中。
func (r *ChapterRepo) ReplaceAll(ctx context.Context, bookID int64, chapters []*domain.BookChapter) error {
	if bookID == 0 {
		return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	if _, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM book_chapters WHERE book_id = ?`, bookID); err != nil {
		return fmt.Errorf("清理旧章节失败: %w", err)
	}
	if len(chapters) == 0 {
		return nil
	}

	const query = `INSERT INTO book_chapters (book_id, idx, title, url, resource, is_volume)
		VALUES (?, ?, ?, ?, ?, ?)`
	for i, c := range chapters {
		idx := c.Index
		if c.Index != i {
			// 调用方未规范序号时，以切片顺序为准，保证目录连续。
			idx = i
		}
		res, err := r.db.q(ctx).ExecContext(ctx, query,
			bookID, idx, c.Title, c.URL, c.Resource, boolToInt(c.IsVolume))
		if err != nil {
			return fmt.Errorf("写入章节失败: %w", err)
		}
		id, err := res.LastInsertId()
		if err != nil {
			return fmt.Errorf("获取章节 ID 失败: %w", err)
		}
		c.ID = id
		c.BookID = bookID
		c.Index = idx
	}
	return nil
}

// List 返回某本书的全部章节，按序号升序。
func (r *ChapterRepo) List(ctx context.Context, bookID int64) ([]*domain.BookChapter, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx,
		`SELECT id, book_id, idx, title, url, resource, is_volume FROM book_chapters
		 WHERE book_id = ? ORDER BY idx ASC`, bookID)
	if err != nil {
		return nil, fmt.Errorf("查询章节失败: %w", err)
	}
	defer rows.Close()

	out := make([]*domain.BookChapter, 0)
	for rows.Next() {
		c, err := scanChapter(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// Get 按书 + 序号取章节。
func (r *ChapterRepo) Get(ctx context.Context, bookID int64, index int) (*domain.BookChapter, error) {
	row := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT id, book_id, idx, title, url, resource, is_volume FROM book_chapters
		 WHERE book_id = ? AND idx = ?`, bookID, index)
	c, err := scanChapter(row)
	if err != nil {
		return nil, normalizeError(err)
	}
	return c, nil
}

// DeleteByBook 删除某本书的全部章节。
func (r *ChapterRepo) DeleteByBook(ctx context.Context, bookID int64) error {
	if _, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM book_chapters WHERE book_id = ?`, bookID); err != nil {
		return fmt.Errorf("删除章节失败: %w", err)
	}
	return nil
}

func scanChapter(s scanner) (*domain.BookChapter, error) {
	var (
		c        domain.BookChapter
		isVolume int
	)
	if err := s.Scan(&c.ID, &c.BookID, &c.Index, &c.Title, &c.URL, &c.Resource, &isVolume); err != nil {
		return nil, err
	}
	c.IsVolume = isVolume != 0
	return &c, nil
}

// boolToInt 将布尔转换为 SQLite 的 0/1。
func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// ProgressRepo 实现 port.ProgressRepository。
type ProgressRepo struct {
	db *DB
}

// NewProgressRepo 创建阅读进度仓储。
func NewProgressRepo(db *DB) *ProgressRepo { return &ProgressRepo{db: db} }

var _ port.ProgressRepository = (*ProgressRepo)(nil)

// Save 写入（upsert）阅读进度。
func (r *ProgressRepo) Save(ctx context.Context, p *domain.ReadingProgress) error {
	if p.BookID == 0 {
		return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	p.UpdatedAt = time.Now()
	const query = `INSERT INTO reading_progress (book_id, chapter_index, chapter_title, chapter_pos, scroll_percent, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(book_id) DO UPDATE SET chapter_index=excluded.chapter_index,
			chapter_title=excluded.chapter_title, chapter_pos=excluded.chapter_pos,
			scroll_percent=excluded.scroll_percent, updated_at=excluded.updated_at`
	if _, err := r.db.q(ctx).ExecContext(ctx, query,
		p.BookID, p.ChapterIndex, p.ChapterTitle, p.ChapterPos, p.ScrollPercent, p.UpdatedAt); err != nil {
		return fmt.Errorf("保存阅读进度失败: %w", err)
	}
	return nil
}

// Get 读取某本书的阅读进度。
func (r *ProgressRepo) Get(ctx context.Context, bookID int64) (*domain.ReadingProgress, error) {
	var p domain.ReadingProgress
	err := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT book_id, chapter_index, chapter_title, chapter_pos, scroll_percent, updated_at
		 FROM reading_progress WHERE book_id = ?`, bookID).
		Scan(&p.BookID, &p.ChapterIndex, &p.ChapterTitle, &p.ChapterPos, &p.ScrollPercent, &p.UpdatedAt)
	if err != nil {
		return nil, normalizeError(err)
	}
	return &p, nil
}

// Delete 删除某本书的阅读进度。
func (r *ProgressRepo) Delete(ctx context.Context, bookID int64) error {
	if _, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM reading_progress WHERE book_id = ?`, bookID); err != nil {
		return fmt.Errorf("删除阅读进度失败: %w", err)
	}
	return nil
}
