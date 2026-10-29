// Package sqlite 基于 modernc.org/sqlite 实现 internal/port 中定义的仓储接口。
//
// 选用 modernc.org/sqlite 的原因：它是 SQLite C 源码转译得到的纯 Go 实现，
// 不需要 cgo，从而保住 CGO_ENABLED=0 与全平台交叉编译能力
// （见 ARCHITECTURE.md 第 8 节）。
package sqlite

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"io/fs"

	// 注册 "sqlite" database/sql 驱动（纯 Go）。
	_ "modernc.org/sqlite"

	"github.com/legado/desktop/internal/domain"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// DB 封装 *sql.DB，并提供全部仓储实现。
type DB struct {
	db *sql.DB
}

// Open 打开（必要时创建）数据库文件，并完成迁移。
// dsn 传文件路径；测试可传 ":memory:"。
func Open(dsn string) (*DB, error) {
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("打开数据库失败: %w", err)
	}

	// SQLite 是本地文件库，写入竞争靠忙等而非连接池解决：
	// 限制单写连接，避免 "database is locked"。
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	d := &DB{db: db}
	if err := d.migrate(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	return d, nil
}

// Close 关闭底层连接。
func (d *DB) Close() error { return d.db.Close() }

// migrate 按序执行 migrations/ 下的 SQL 文件，并记录已执行版本。
// 使用 user_version pragma 记录当前 schema 版本，保证幂等。
func (d *DB) migrate(ctx context.Context) error {
	if _, err := d.db.ExecContext(ctx, `PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;`); err != nil {
		return fmt.Errorf("设置 pragma 失败: %w", err)
	}
	if _, err := d.db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY, applied_at DATETIME NOT NULL)`); err != nil {
		return fmt.Errorf("创建版本表失败: %w", err)
	}

	entries, err := fs.ReadDir(migrationsFS, "migrations")
	if err != nil {
		return fmt.Errorf("读取迁移目录失败: %w", err)
	}
	for i, e := range entries {
		version := i + 1
		var applied int
		err := d.db.QueryRowContext(ctx, `SELECT COUNT(1) FROM schema_version WHERE version = ?`, version).Scan(&applied)
		if err != nil {
			return fmt.Errorf("查询迁移版本失败: %w", err)
		}
		if applied > 0 {
			continue
		}

		body, err := fs.ReadFile(migrationsFS, "migrations/"+e.Name())
		if err != nil {
			return fmt.Errorf("读取迁移文件 %s 失败: %w", e.Name(), err)
		}
		if err := d.execScript(ctx, string(body)); err != nil {
			return fmt.Errorf("执行迁移 %s 失败: %w", e.Name(), err)
		}
		if _, err := d.db.ExecContext(ctx, `INSERT INTO schema_version (version, applied_at) VALUES (?, CURRENT_TIMESTAMP)`, version); err != nil {
			return fmt.Errorf("记录迁移版本失败: %w", err)
		}
	}
	return nil
}

// execScript 在一个事务内执行多语句脚本。
func (d *DB) execScript(ctx context.Context, script string) error {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // 已提交时 Rollback 返回错误可忽略

	if _, err := tx.ExecContext(ctx, script); err != nil {
		return err
	}
	return tx.Commit()
}

// Do 在单个事务内执行 fn，实现 port.UnitOfWork。
func (d *DB) Do(ctx context.Context, fn func(ctx context.Context) error) error {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("开启事务失败: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck

	if err := fn(withTx(ctx, tx)); err != nil {
		return err
	}
	return tx.Commit()
}

// txKey 是事务在 context 中的键类型。
type txKey struct{}

// withTx 把事务写入 context。
func withTx(ctx context.Context, tx *sql.Tx) context.Context {
	return context.WithValue(ctx, txKey{}, tx)
}

// runner 是 *sql.DB 与 *sql.Tx 的公共子集，便于仓储方法同时支持
// 「普通调用」与「事务内调用」两种场景。
type runner interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// q 从 context 取事务；不存在则返回 *sql.DB。
// 这样同一个仓储方法既能独立使用，也能自动参与 UnitOfWork 事务。
func (d *DB) q(ctx context.Context) runner {
	if tx, ok := ctx.Value(txKey{}).(*sql.Tx); ok {
		return tx
	}
	return d.db
}

// 编译期断言：确保实现满足端口接口。
var (
	_ interface{ Close() error } = (*DB)(nil)
)

// normalizeError 把底层错误映射为领域错误。
func normalizeError(err error) error {
	if err == nil {
		return nil
	}
	if err == sql.ErrNoRows {
		return domain.ErrNotFound
	}
	return err
}
