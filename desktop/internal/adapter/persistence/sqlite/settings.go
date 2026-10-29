package sqlite

import (
	"context"
	"fmt"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// SettingsStore 实现 port.SettingsStore，底层为 app_settings 表。
type SettingsStore struct {
	db *DB
}

// NewSettingsStore 创建配置存储。
func NewSettingsStore(db *DB) *SettingsStore { return &SettingsStore{db: db} }

var _ port.SettingsStore = (*SettingsStore)(nil)

// Get 读取配置值。
func (s *SettingsStore) Get(ctx context.Context, key string) (string, error) {
	if key == "" {
		return "", fmt.Errorf("%w: 配置键不能为空", domain.ErrInvalidArgument)
	}
	var value string
	err := s.db.q(ctx).QueryRowContext(ctx, `SELECT value FROM app_settings WHERE key = ?`, key).Scan(&value)
	if err != nil {
		return "", normalizeError(err)
	}
	return value, nil
}

// Set 写入配置值（不存在时插入，存在时更新）。
func (s *SettingsStore) Set(ctx context.Context, key, value string) error {
	if key == "" {
		return fmt.Errorf("%w: 配置键不能为空", domain.ErrInvalidArgument)
	}
	const query = `INSERT INTO app_settings (key, value, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=CURRENT_TIMESTAMP`
	if _, err := s.db.q(ctx).ExecContext(ctx, query, key, value); err != nil {
		return fmt.Errorf("写入配置失败: %w", err)
	}
	return nil
}

// Delete 删除配置项。
func (s *SettingsStore) Delete(ctx context.Context, key string) error {
	if _, err := s.db.q(ctx).ExecContext(ctx, `DELETE FROM app_settings WHERE key = ?`, key); err != nil {
		return fmt.Errorf("删除配置失败: %w", err)
	}
	return nil
}
