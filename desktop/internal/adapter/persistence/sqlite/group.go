package sqlite

import (
	"context"
	"fmt"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// BookGroupRepo 实现 port.BookGroupRepository。
type BookGroupRepo struct {
	db *DB
}

// NewBookGroupRepo 创建分组仓储。
func NewBookGroupRepo(db *DB) *BookGroupRepo { return &BookGroupRepo{db: db} }

var _ port.BookGroupRepository = (*BookGroupRepo)(nil)

const groupColumns = `id, name, sort_order, show, built_in`

// Create 新增分组并回填主键。
func (r *BookGroupRepo) Create(ctx context.Context, g *domain.BookGroup) error {
	if g.Name == "" {
		return fmt.Errorf("%w: 分组名不能为空", domain.ErrInvalidArgument)
	}
	row := r.db.q(ctx).QueryRowContext(ctx,
		`INSERT INTO book_groups (id, name, sort_order, show, built_in) VALUES (NULL, ?, ?, ?, ?) RETURNING id`,
		g.Name, g.Order, boolToInt(g.Show), boolToInt(g.BuiltIn))
	if err := row.Scan(&g.ID); err != nil {
		return fmt.Errorf("新增分组失败: %w", err)
	}
	return nil
}

// Update 更新分组。
func (r *BookGroupRepo) Update(ctx context.Context, g *domain.BookGroup) error {
	if g.ID == 0 {
		return fmt.Errorf("%w: 缺少分组 ID", domain.ErrInvalidArgument)
	}
	res, err := r.db.q(ctx).ExecContext(ctx,
		`UPDATE book_groups SET name=?, sort_order=?, show=? WHERE id=?`,
		g.Name, g.Order, boolToInt(g.Show), g.ID)
	if err != nil {
		return fmt.Errorf("更新分组失败: %w", err)
	}
	return ensureAffected(res, domain.ErrNotFound, "分组不存在")
}

// Delete 删除分组；内置分组禁止删除。
func (r *BookGroupRepo) Delete(ctx context.Context, id int64) error {
	var builtIn int
	err := r.db.q(ctx).QueryRowContext(ctx, `SELECT built_in FROM book_groups WHERE id = ?`, id).Scan(&builtIn)
	if err != nil {
		return normalizeError(err)
	}
	if builtIn != 0 {
		return fmt.Errorf("%w: 内置分组不可删除", domain.ErrInvalidArgument)
	}
	res, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM book_groups WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("删除分组失败: %w", err)
	}
	return ensureAffected(res, domain.ErrNotFound, "分组不存在")
}

// Get 按主键取分组。
func (r *BookGroupRepo) Get(ctx context.Context, id int64) (*domain.BookGroup, error) {
	row := r.db.q(ctx).QueryRowContext(ctx, `SELECT `+groupColumns+` FROM book_groups WHERE id = ?`, id)
	g, err := scanGroup(row)
	if err != nil {
		return nil, normalizeError(err)
	}
	return g, nil
}

// List 列出全部分组，按排序号升序。
func (r *BookGroupRepo) List(ctx context.Context) ([]*domain.BookGroup, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx,
		`SELECT `+groupColumns+` FROM book_groups ORDER BY sort_order ASC, id ASC`)
	if err != nil {
		return nil, fmt.Errorf("查询分组失败: %w", err)
	}
	defer rows.Close()

	var out []*domain.BookGroup
	for rows.Next() {
		g, err := scanGroup(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

func scanGroup(s scanner) (*domain.BookGroup, error) {
	var (
		g             domain.BookGroup
		show, builtIn int
	)
	if err := s.Scan(&g.ID, &g.Name, &g.Order, &show, &builtIn); err != nil {
		return nil, err
	}
	g.Show = show != 0
	g.BuiltIn = builtIn != 0
	return &g, nil
}
