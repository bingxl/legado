package sqlite

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// SourceLoginRepo 实现 port.SourceLoginRepository。
type SourceLoginRepo struct {
	db *DB
}

// NewSourceLoginRepo 创建书源登录信息仓储。
func NewSourceLoginRepo(db *DB) *SourceLoginRepo { return &SourceLoginRepo{db: db} }

var _ port.SourceLoginRepository = (*SourceLoginRepo)(nil)

// Get 读取登录信息。
func (r *SourceLoginRepo) Get(ctx context.Context, sourceURL string) (domain.SourceLogin, error) {
	url := strings.TrimSpace(sourceURL)
	if url == "" {
		return domain.SourceLogin{}, fmt.Errorf("%w: 缺少书源地址", domain.ErrInvalidArgument)
	}
	var (
		formJSON  string
		header    string
		updatedAt int64
	)
	err := r.db.q(ctx).QueryRowContext(ctx,
		`SELECT form_json, header, updated_at FROM source_login WHERE source_url = ?`, url).
		Scan(&formJSON, &header, &updatedAt)
	if err != nil {
		if err == sql.ErrNoRows {
			return domain.SourceLogin{}, fmt.Errorf("%w: 该书源没有登录信息", domain.ErrNotFound)
		}
		return domain.SourceLogin{}, fmt.Errorf("查询登录信息失败: %w", err)
	}

	out := domain.SourceLogin{SourceURL: url, Header: header}
	if strings.TrimSpace(formJSON) != "" {
		// 表单 JSON 坏掉不该让整个登录界面打不开：能读到 header 也够用，
		// 顶多是账号密码不回填（用户可以重新填）。
		if err := json.Unmarshal([]byte(formJSON), &out.Form); err != nil {
			out.Form = nil
		}
	}
	if updatedAt > 0 {
		out.UpdatedAt = time.Unix(updatedAt, 0)
	}
	return out, nil
}

// Save 写入或覆盖登录信息。
func (r *SourceLoginRepo) Save(ctx context.Context, login domain.SourceLogin) error {
	url := strings.TrimSpace(login.SourceURL)
	if url == "" {
		return fmt.Errorf("%w: 缺少书源地址", domain.ErrInvalidArgument)
	}
	formJSON := ""
	if len(login.Form) > 0 {
		b, err := json.Marshal(login.Form)
		if err != nil {
			return fmt.Errorf("登录信息序列化失败: %w", err)
		}
		formJSON = string(b)
	}
	updated := login.UpdatedAt
	if updated.IsZero() {
		updated = time.Now()
	}
	_, err := r.db.q(ctx).ExecContext(ctx,
		`INSERT INTO source_login (source_url, form_json, header, updated_at)
		 VALUES (?, ?, ?, ?)
		 ON CONFLICT(source_url) DO UPDATE SET
		     form_json=excluded.form_json,
		     header=excluded.header,
		     updated_at=excluded.updated_at`,
		url, formJSON, login.Header, updated.Unix())
	if err != nil {
		return fmt.Errorf("保存登录信息失败: %w", err)
	}
	// db.q(ctx) 在事务上下文里返回的是 *sql.Tx，没有 sql.Tx.Exec 的自动提交；
	// 这里的语句很短，直接执行即可（与其它仓储一致）。
	return nil
}

// Delete 删除登录信息，不存在也返回 nil。
func (r *SourceLoginRepo) Delete(ctx context.Context, sourceURL string) error {
	url := strings.TrimSpace(sourceURL)
	if url == "" {
		return nil
	}
	if _, err := r.db.q(ctx).ExecContext(ctx, `DELETE FROM source_login WHERE source_url = ?`, url); err != nil {
		return fmt.Errorf("删除登录信息失败: %w", err)
	}
	return nil
}

// ListSourceURLs 列出已有登录信息的书源地址。
func (r *SourceLoginRepo) ListSourceURLs(ctx context.Context) ([]string, error) {
	rows, err := r.db.q(ctx).QueryContext(ctx, `SELECT source_url FROM source_login`)
	if err != nil {
		return nil, fmt.Errorf("查询登录信息失败: %w", err)
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var u string
		if err := rows.Scan(&u); err != nil {
			return nil, fmt.Errorf("读取登录信息失败: %w", err)
		}
		out = append(out, u)
	}
	return out, rows.Err()
}
