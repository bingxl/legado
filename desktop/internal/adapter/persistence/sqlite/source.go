package sqlite

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// BookSourceRepo 实现 port.BookSourceRepository。
type BookSourceRepo struct {
	db *DB
}

// NewBookSourceRepo 创建书源仓储。
func NewBookSourceRepo(db *DB) *BookSourceRepo { return &BookSourceRepo{db: db} }

var _ port.BookSourceRepository = (*BookSourceRepo)(nil)

const sourceColumns = `id, name, group_name, url, enabled, sort_order, comment, raw, last_update_at, created_at`

// Create 新增书源并回填主键。
func (r *BookSourceRepo) Create(ctx context.Context, s *domain.BookSource) error {
	if s.URL == "" {
		return fmt.Errorf("%w: 书源 URL 不能为空", domain.ErrInvalidArgument)
	}
	if s.CreatedAt.IsZero() {
		s.CreatedAt = time.Now()
	}
	row := r.db.q(ctx).QueryRowContext(ctx,
		`INSERT INTO book_sources (id, name, group_name, url, enabled, sort_order, comment, raw, last_update_at, created_at)
		 VALUES (NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id`,
		s.Name, s.Group, s.URL, boolToInt(s.Enabled), s.Order, s.Comment, s.Raw,
		nullableTime(s.LastUpdateAt), s.CreatedAt)
	if err := row.Scan(&s.ID); err != nil {
		if isUniqueViolation(err) {
			return fmt.Errorf("%w: 已存在相同 URL 的书源", domain.ErrAlreadyExists)
		}
		return fmt.Errorf("新增书源失败: %w", err)
	}
	return nil
}

// Update 更新书源。
func (r *BookSourceRepo) Update(ctx context.Context, s *domain.BookSource) error {
	if s.ID == 0 {
		return fmt.Errorf("%w: 缺少书源 ID", domain.ErrInvalidArgument)
	}
	res, err := r.db.q(ctx).ExecContext(ctx,
		`UPDATE book_sources SET name=?, group_name=?, url=?, enabled=?, sort_order=?, comment=?, raw=?, last_update_at=?
		 WHERE id=?`,
		s.Name, s.Group, s.URL, boolToInt(s.Enabled), s.Order, s.Comment, s.Raw,
		nullableTime(s.LastUpdateAt), s.ID)
	if err != nil {
		if isUniqueViolation(err) {
			return fmt.Errorf("%w: 已存在相同 URL 的书源", domain.ErrAlreadyExists)
		}
		return fmt.Errorf("更新书源失败: %w", err)
	}
	return ensureAffected(res, domain.ErrNotFound, "书源不存在")
}

// Delete 删除书源。
func (r *BookSourceRepo) Delete(ctx context.Context, id int64) error {
	res, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM book_sources WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("删除书源失败: %w", err)
	}
	return ensureAffected(res, domain.ErrNotFound, "书源不存在")
}

// Get 按主键取书源。
func (r *BookSourceRepo) Get(ctx context.Context, id int64) (*domain.BookSource, error) {
	row := r.db.q(ctx).QueryRowContext(ctx, `SELECT `+sourceColumns+` FROM book_sources WHERE id = ?`, id)
	s, err := scanSource(row)
	if err != nil {
		return nil, normalizeError(err)
	}
	return s, nil
}

// FindByURL 按书源 URL 定位。
func (r *BookSourceRepo) FindByURL(ctx context.Context, url string) (*domain.BookSource, error) {
	row := r.db.q(ctx).QueryRowContext(ctx, `SELECT `+sourceColumns+` FROM book_sources WHERE url = ?`, url)
	s, err := scanSource(row)
	if err != nil {
		return nil, normalizeError(err)
	}
	return s, nil
}

// List 列出书源；group 为空表示全部。
func (r *BookSourceRepo) List(ctx context.Context, group string) ([]*domain.BookSource, error) {
	query := `SELECT ` + sourceColumns + ` FROM book_sources`
	args := []any{}
	if group != "" {
		query += ` WHERE group_name = ?`
		args = append(args, group)
	}
	query += ` ORDER BY sort_order ASC, name ASC`

	rows, err := r.db.q(ctx).QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("查询书源失败: %w", err)
	}
	defer rows.Close()

	var out []*domain.BookSource
	for rows.Next() {
		s, err := scanSource(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// ListEnabled 列出全部启用书源。
func (r *BookSourceRepo) ListEnabled(ctx context.Context) ([]*domain.BookSource, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx,
		`SELECT `+sourceColumns+` FROM book_sources WHERE enabled = 1 ORDER BY sort_order ASC, name ASC`)
	if err != nil {
		return nil, fmt.Errorf("查询启用书源失败: %w", err)
	}
	defer rows.Close()

	var out []*domain.BookSource
	for rows.Next() {
		s, err := scanSource(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func scanSource(s scanner) (*domain.BookSource, error) {
	var (
		src       domain.BookSource
		enabled   int
		lastUpd   sql.NullTime
		createdAt time.Time
	)
	if err := s.Scan(&src.ID, &src.Name, &src.Group, &src.URL, &enabled, &src.Order,
		&src.Comment, &src.Raw, &lastUpd, &createdAt); err != nil {
		return nil, err
	}
	src.Enabled = enabled != 0
	src.CreatedAt = createdAt
	if lastUpd.Valid {
		src.LastUpdateAt = lastUpd.Time
	}
	return &src, nil
}

// ReplaceRuleRepo 实现 port.ReplaceRuleRepository。
type ReplaceRuleRepo struct {
	db *DB
}

// NewReplaceRuleRepo 创建替换规则仓储。
func NewReplaceRuleRepo(db *DB) *ReplaceRuleRepo { return &ReplaceRuleRepo{db: db} }

var _ port.ReplaceRuleRepository = (*ReplaceRuleRepo)(nil)

const ruleColumns = `id, name, group_name, enabled, sort_order, raw`

// Create 新增替换规则。
func (r *ReplaceRuleRepo) Create(ctx context.Context, v *domain.ReplaceRule) error {
	row := r.db.q(ctx).QueryRowContext(ctx,
		`INSERT INTO replace_rules (id, name, group_name, enabled, sort_order, raw) VALUES (NULL, ?, ?, ?, ?, ?) RETURNING id`,
		v.Name, v.Group, boolToInt(v.Enabled), v.Order, v.Raw)
	if err := row.Scan(&v.ID); err != nil {
		return fmt.Errorf("新增替换规则失败: %w", err)
	}
	return nil
}

// Update 更新替换规则。
func (r *ReplaceRuleRepo) Update(ctx context.Context, v *domain.ReplaceRule) error {
	res, err := r.db.q(ctx).ExecContext(ctx,
		`UPDATE replace_rules SET name=?, group_name=?, enabled=?, sort_order=?, raw=? WHERE id=?`,
		v.Name, v.Group, boolToInt(v.Enabled), v.Order, v.Raw, v.ID)
	if err != nil {
		return fmt.Errorf("更新替换规则失败: %w", err)
	}
	return ensureAffected(res, domain.ErrNotFound, "替换规则不存在")
}

// Delete 删除替换规则。
func (r *ReplaceRuleRepo) Delete(ctx context.Context, id int64) error {
	res, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM replace_rules WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("删除替换规则失败: %w", err)
	}
	return ensureAffected(res, domain.ErrNotFound, "替换规则不存在")
}

// Get 按主键取替换规则。
func (r *ReplaceRuleRepo) Get(ctx context.Context, id int64) (*domain.ReplaceRule, error) {
	row := r.db.q(ctx).QueryRowContext(ctx, `SELECT `+ruleColumns+` FROM replace_rules WHERE id = ?`, id)
	v, err := scanRule(row)
	if err != nil {
		return nil, normalizeError(err)
	}
	return v, nil
}

// List 列出全部替换规则。
func (r *ReplaceRuleRepo) List(ctx context.Context) ([]*domain.ReplaceRule, error) {
	return r.queryRules(ctx, `SELECT `+ruleColumns+` FROM replace_rules ORDER BY sort_order ASC, id ASC`)
}

// ListEnabled 列出启用的替换规则。
func (r *ReplaceRuleRepo) ListEnabled(ctx context.Context) ([]*domain.ReplaceRule, error) {
	return r.queryRules(ctx, `SELECT `+ruleColumns+` FROM replace_rules WHERE enabled = 1 ORDER BY sort_order ASC, id ASC`)
}

func (r *ReplaceRuleRepo) queryRules(ctx context.Context, query string) ([]*domain.ReplaceRule, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("查询替换规则失败: %w", err)
	}
	defer rows.Close()

	var out []*domain.ReplaceRule
	for rows.Next() {
		v, err := scanRule(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func scanRule(s scanner) (*domain.ReplaceRule, error) {
	var (
		v       domain.ReplaceRule
		enabled int
	)
	if err := s.Scan(&v.ID, &v.Name, &v.Group, &enabled, &v.Order, &v.Raw); err != nil {
		return nil, err
	}
	v.Enabled = enabled != 0
	return &v, nil
}

// SubscriptionRepo 实现 port.SubscriptionRepository。
type SubscriptionRepo struct {
	db *DB
}

// NewSubscriptionRepo 创建订阅仓储。
func NewSubscriptionRepo(db *DB) *SubscriptionRepo { return &SubscriptionRepo{db: db} }

var _ port.SubscriptionRepository = (*SubscriptionRepo)(nil)

const subColumns = `id, name, url, enabled, sort_order, last_sync_at, created_at`

// Create 新增订阅。
func (r *SubscriptionRepo) Create(ctx context.Context, s *domain.SourceSubscription) error {
	if s.URL == "" {
		return fmt.Errorf("%w: 订阅 URL 不能为空", domain.ErrInvalidArgument)
	}
	if s.CreatedAt.IsZero() {
		s.CreatedAt = time.Now()
	}
	row := r.db.q(ctx).QueryRowContext(ctx,
		`INSERT INTO source_subscriptions (id, name, url, enabled, sort_order, last_sync_at, created_at)
		 VALUES (NULL, ?, ?, ?, ?, ?, ?) RETURNING id`,
		s.Name, s.URL, boolToInt(s.Enabled), s.Order, nullableTime(s.LastSyncAt), s.CreatedAt)
	if err := row.Scan(&s.ID); err != nil {
		return fmt.Errorf("新增订阅失败: %w", err)
	}
	return nil
}

// Update 更新订阅。
func (r *SubscriptionRepo) Update(ctx context.Context, s *domain.SourceSubscription) error {
	res, err := r.db.q(ctx).ExecContext(ctx,
		`UPDATE source_subscriptions SET name=?, url=?, enabled=?, sort_order=?, last_sync_at=? WHERE id=?`,
		s.Name, s.URL, boolToInt(s.Enabled), s.Order, nullableTime(s.LastSyncAt), s.ID)
	if err != nil {
		return fmt.Errorf("更新订阅失败: %w", err)
	}
	return ensureAffected(res, domain.ErrNotFound, "订阅不存在")
}

// Delete 删除订阅。
func (r *SubscriptionRepo) Delete(ctx context.Context, id int64) error {
	res, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM source_subscriptions WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("删除订阅失败: %w", err)
	}
	return ensureAffected(res, domain.ErrNotFound, "订阅不存在")
}

// Get 按主键取订阅。
func (r *SubscriptionRepo) Get(ctx context.Context, id int64) (*domain.SourceSubscription, error) {
	row := r.db.q(ctx).QueryRowContext(ctx, `SELECT `+subColumns+` FROM source_subscriptions WHERE id = ?`, id)
	s, err := scanSubscription(row)
	if err != nil {
		return nil, normalizeError(err)
	}
	return s, nil
}

// List 列出全部订阅。
func (r *SubscriptionRepo) List(ctx context.Context) ([]*domain.SourceSubscription, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx,
		`SELECT `+subColumns+` FROM source_subscriptions ORDER BY sort_order ASC, id ASC`)
	if err != nil {
		return nil, fmt.Errorf("查询订阅失败: %w", err)
	}
	defer rows.Close()

	var out []*domain.SourceSubscription
	for rows.Next() {
		s, err := scanSubscription(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func scanSubscription(s scanner) (*domain.SourceSubscription, error) {
	var (
		sub       domain.SourceSubscription
		enabled   int
		lastSync  sql.NullTime
		createdAt time.Time
	)
	if err := s.Scan(&sub.ID, &sub.Name, &sub.URL, &enabled, &sub.Order, &lastSync, &createdAt); err != nil {
		return nil, err
	}
	sub.Enabled = enabled != 0
	sub.CreatedAt = createdAt
	if lastSync.Valid {
		sub.LastSyncAt = lastSync.Time
	}
	return &sub, nil
}
