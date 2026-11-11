package sqlite

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/legado/desktop/internal/port"
)

// SourceVariableRepo 实现 port.SourceVariableRepository。
type SourceVariableRepo struct {
	db *DB
}

// NewSourceVariableRepo 创建书源变量仓储。
func NewSourceVariableRepo(db *DB) *SourceVariableRepo { return &SourceVariableRepo{db: db} }

var _ port.SourceVariableRepository = (*SourceVariableRepo)(nil)

// Get 读取书源变量；没设过时返回空串。
//
// 「没有变量」是常态而不是异常：调用方拿空串直接渲染成空输入框即可，
// 不必在每个调用点判 ErrNotFound。
func (r *SourceVariableRepo) Get(ctx context.Context, sourceURL string) (string, error) {
	var v string
	err := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT variable FROM source_variables WHERE book_source_url = ?`, sourceURL).Scan(&v)
	if err == sql.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("读取书源变量失败: %w", err)
	}
	return v, nil
}

// Put 写入（覆盖）书源变量。
func (r *SourceVariableRepo) Put(ctx context.Context, sourceURL, variable string) error {
	_, err := r.db.q(ctx).ExecContext(ctx,
		`INSERT INTO source_variables (book_source_url, variable, updated_at) VALUES (?, ?, ?)
		 ON CONFLICT(book_source_url) DO UPDATE SET variable = excluded.variable, updated_at = excluded.updated_at`,
		sourceURL, variable, time.Now())
	if err != nil {
		return fmt.Errorf("保存书源变量失败: %w", err)
	}
	return nil
}

// Delete 删除书源变量；不存在不算错误（清除要幂等）。
func (r *SourceVariableRepo) Delete(ctx context.Context, sourceURL string) error {
	if _, err := r.db.q(ctx).ExecContext(ctx,
		`DELETE FROM source_variables WHERE book_source_url = ?`, sourceURL); err != nil {
		return fmt.Errorf("删除书源变量失败: %w", err)
	}
	return nil
}
