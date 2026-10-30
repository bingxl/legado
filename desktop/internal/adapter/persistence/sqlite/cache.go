package sqlite

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ChapterCacheRepo 实现 port.ChapterCacheRepository。
type ChapterCacheRepo struct {
	db *DB
}

// NewChapterCacheRepo 创建章节缓存仓储。
func NewChapterCacheRepo(db *DB) *ChapterCacheRepo { return &ChapterCacheRepo{db: db} }

var _ port.ChapterCacheRepository = (*ChapterCacheRepo)(nil)

// Put 写入或覆盖一条缓存。
func (r *ChapterCacheRepo) Put(ctx context.Context, c *domain.CachedChapter) error {
	if c.BookID == 0 {
		return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	if c.CreatedAt.IsZero() {
		c.CreatedAt = time.Now()
	}
	images := "[]"
	if len(c.Images) > 0 {
		b, err := json.Marshal(c.Images)
		if err != nil {
			return fmt.Errorf("序列化图片地址失败: %w", err)
		}
		images = string(b)
	}

	const query = `INSERT INTO chapter_cache (book_id, idx, title, url, html, images, size, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(book_id, idx) DO UPDATE SET title=excluded.title, url=excluded.url,
			html=excluded.html, images=excluded.images, size=excluded.size,
			created_at=excluded.created_at`
	if _, err := r.db.q(ctx).ExecContext(ctx, query,
		c.BookID, c.Index, c.Title, c.URL, c.HTML, images, c.Size, c.CreatedAt.Unix()); err != nil {
		return fmt.Errorf("写入章节缓存失败: %w", err)
	}
	return nil
}

// Get 取单章缓存（含正文）。
func (r *ChapterCacheRepo) Get(ctx context.Context, bookID int64, index int) (*domain.CachedChapter, error) {
	row := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT book_id, idx, title, url, html, images, size, created_at
		 FROM chapter_cache WHERE book_id = ? AND idx = ?`, bookID, index)
	c, err := scanCachedChapter(row)
	if err != nil {
		return nil, normalizeError(err)
	}
	return c, nil
}

// List 返回某本书的全部缓存章节（不含正文，避免一次读出整本内容）。
func (r *ChapterCacheRepo) List(ctx context.Context, bookID int64) ([]*domain.CachedChapter, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx,
		`SELECT book_id, idx, title, url, '', images, size, created_at
		 FROM chapter_cache WHERE book_id = ? ORDER BY idx ASC`, bookID)
	if err != nil {
		return nil, fmt.Errorf("查询章节缓存失败: %w", err)
	}
	defer rows.Close()

	out := make([]*domain.CachedChapter, 0)
	for rows.Next() {
		c, err := scanCachedChapter(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// Indexes 返回某本书已缓存的章节序号。
func (r *ChapterCacheRepo) Indexes(ctx context.Context, bookID int64) ([]int, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx,
		`SELECT idx FROM chapter_cache WHERE book_id = ? ORDER BY idx ASC`, bookID)
	if err != nil {
		return nil, fmt.Errorf("查询缓存章节失败: %w", err)
	}
	defer rows.Close()

	out := make([]int, 0)
	for rows.Next() {
		var idx int
		if err := rows.Scan(&idx); err != nil {
			return nil, err
		}
		out = append(out, idx)
	}
	return out, rows.Err()
}

// BookStats 按书聚合缓存统计。
func (r *ChapterCacheRepo) BookStats(ctx context.Context) ([]domain.CacheBookStat, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx,
		`SELECT book_id, COUNT(1), COALESCE(SUM(size), 0), MAX(created_at)
		 FROM chapter_cache GROUP BY book_id`)
	if err != nil {
		return nil, fmt.Errorf("统计章节缓存失败: %w", err)
	}
	defer rows.Close()

	out := make([]domain.CacheBookStat, 0)
	for rows.Next() {
		var (
			st  domain.CacheBookStat
			sec int64
		)
		if err := rows.Scan(&st.BookID, &st.Chapters, &st.Size, &sec); err != nil {
			return nil, err
		}
		if sec > 0 {
			st.UpdatedAt = time.Unix(sec, 0)
		}
		out = append(out, st)
	}
	return out, rows.Err()
}

// Delete 删除某本书的指定章节缓存。
func (r *ChapterCacheRepo) Delete(ctx context.Context, bookID int64, indexes []int) error {
	if len(indexes) == 0 {
		return nil
	}
	// SQLite 的变量个数有上限（默认 999），分批删除。
	const batch = 500
	for start := 0; start < len(indexes); start += batch {
		end := start + batch
		if end > len(indexes) {
			end = len(indexes)
		}
		chunk := indexes[start:end]
		args := make([]any, 0, len(chunk)+1)
		args = append(args, bookID)
		for _, idx := range chunk {
			args = append(args, idx)
		}
		query := `DELETE FROM chapter_cache WHERE book_id = ? AND idx IN (` +
			strings.TrimSuffix(strings.Repeat("?,", len(chunk)), ",") + `)`
		if _, err := r.db.q(ctx).ExecContext(ctx, query, args...); err != nil {
			return fmt.Errorf("删除章节缓存失败: %w", err)
		}
	}
	return nil
}

// DeleteByBook 删除某本书的全部缓存。
func (r *ChapterCacheRepo) DeleteByBook(ctx context.Context, bookID int64) error {
	if _, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM chapter_cache WHERE book_id = ?`, bookID); err != nil {
		return fmt.Errorf("删除书籍缓存失败: %w", err)
	}
	return nil
}

// DeleteAll 清空全部缓存。
func (r *ChapterCacheRepo) DeleteAll(ctx context.Context) error {
	if _, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM chapter_cache`); err != nil {
		return fmt.Errorf("清空缓存失败: %w", err)
	}
	return nil
}

// scanCachedChapter 从行/行集读取一条缓存记录。
func scanCachedChapter(s scanner) (*domain.CachedChapter, error) {
	var (
		c      domain.CachedChapter
		images string
		sec    int64
	)
	if err := s.Scan(&c.BookID, &c.Index, &c.Title, &c.URL, &c.HTML, &images, &c.Size, &sec); err != nil {
		return nil, err
	}
	if sec > 0 {
		c.CreatedAt = time.Unix(sec, 0)
	}
	if strings.TrimSpace(images) != "" && images != "[]" {
		// 解析失败时退化为「无图片」，而不是让整条缓存不可用。
		_ = json.Unmarshal([]byte(images), &c.Images)
	}
	return &c, nil
}
