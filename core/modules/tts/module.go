// Package tts 是朗读域模块：文本分段、TTS 规则、HTTP TTS 合成、会话续读。
//
// 现状：迁移期占位。分段算法必须写在 Go 侧（前端 1.2k 行必须下沉），
// 因为「跨书续读」「朗读进度落盘」需要跨页面一致。
package tts

import (
	"context"
	"encoding/json"

	"github.com/legado/core/adapters/persistence/sqlite"
	"github.com/legado/core/kernel"
)

// Module 实现 kernel.Module。
type Module struct {
	db *sqlite.DB
}

// New 构造模块。
func New(db *sqlite.DB) *Module { return &Module{db: db} }

// Name 返回模块名。
func (m *Module) Name() string { return "tts" }

// DependsOn 声明依赖模块。
func (m *Module) DependsOn() []string { return nil }

// Migrate 建表（幂等）。
func (m *Module) Migrate(ctx context.Context) error {
	return m.db.EnsureSchema(ctx, `CREATE TABLE IF NOT EXISTS tts_session (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		book_id INTEGER NOT NULL DEFAULT 0,
		chapter_index INTEGER NOT NULL DEFAULT 0,
		paragraph INTEGER NOT NULL DEFAULT 0,
		offset INTEGER NOT NULL DEFAULT 0,
		engine TEXT NOT NULL DEFAULT '',
		updated_at INTEGER NOT NULL DEFAULT (unixepoch())
	);`)
}

// Register 把本域能力交给内核。
func (m *Module) Register(r *kernel.Registry) {
	// 分段是最小可用能力：不依赖 DB，先给出确定性实现，
	// UI 与测试可直接调用；后续再补 TTS 规则与合成。
	r.Method("Tts.Segment", func(ctx context.Context, args []json.RawMessage) (any, error) {
		type req struct {
			Text      string `json:"text"`
			MaxRunes  int    `json:"maxRunes"`
			Paragraph int    `json:"paragraph"`
		}
		var in req
		if len(args) > 0 {
			if err := json.Unmarshal(args[0], &in); err != nil {
				return nil, kernel.Ef(kernel.CodeInvalid, "参数解析失败: %v", err)
			}
		}
		return Split(in.Text, in.MaxRunes), nil
	}, kernel.Doc("把正文切成朗读片段"))
}
