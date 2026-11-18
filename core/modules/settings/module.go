// Package settings 是应用配置域：Schema 声明、校验、读写。
//
// 为什么不放在各功能模块里：配置是跨模块的（阅读器要字号、听书要语速、
// AI 要密钥），散落各处就会出现"同一份偏好三处默认值"。这里把
// 「有哪些配置项、各自合法区间、默认值」收成一张声明表，
// 前端按表渲染，三个宿主读写同一份数据。
package settings

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/legado/core/kernel"
	"github.com/legado/core/port"
)

// Module 实现 kernel.Module。
type Module struct {
	svc *Service
}

// New 构造模块。
func New(store port.SettingsStore) *Module { return &Module{svc: NewService(store)} }

// Name 返回模块名。
func (m *Module) Name() string { return "settings" }

// DependsOn 声明依赖模块。
func (m *Module) DependsOn() []string { return nil }

// Service 暴露内部服务，便于其它模块直接读配置而不走 JSON 往返。
func (m *Module) Service() *Service { return m.svc }

// Register 把配置能力交给内核。
//
// app_settings 表由 sqlite 的 001_init.sql 建好，本模块不再建表，
// 因此不实现 kernel.Migrator。
func (m *Module) Register(r *kernel.Registry) {
	r.Method("Settings.Schema", func(ctx context.Context, args []json.RawMessage) (any, error) {
		return m.svc.Schema(), nil
	}, kernel.Sig(), kernel.Doc("导出设置页声明：分组、控件类型、默认值、合法区间"))

	r.Method("Settings.Values", func(ctx context.Context, args []json.RawMessage) (any, error) {
		return m.svc.Values(ctx)
	}, kernel.Sig(), kernel.Doc("读取全部配置的有效值（默认值 + 已落库），值为字符串"))

	r.Method("Settings.Update", func(ctx context.Context, args []json.RawMessage) (any, error) {
		var patch map[string]string
		if err := decodeArg(args, 0, &patch); err != nil {
			return nil, err
		}
		if patch == nil {
			return nil, kernel.Ef(kernel.CodeInvalid, "缺少要修改的配置")
		}
		return m.svc.Update(ctx, patch)
	}, kernel.Sig("patch map[string]string"),
		kernel.Doc("批量保存配置（增量）；返回保存后的全量有效值"))

	r.Method("Settings.Reset", func(ctx context.Context, args []json.RawMessage) (any, error) {
		var keys []string
		if err := decodeArg(args, 0, &keys); err != nil {
			return nil, err
		}
		return m.svc.Reset(ctx, keys)
	}, kernel.Sig("keys []string"),
		kernel.Doc("恢复默认值；keys 为空表示全部重置"))

	r.Method("Settings.Reader", func(ctx context.Context, args []json.RawMessage) (any, error) {
		return m.svc.Reader(ctx)
	}, kernel.Sig(),
		kernel.Doc("阅读器强类型配置（解析失败时静默退回默认值）"))

	// ---- CLI ----
	r.Command("settings schema", func(ctx context.Context, args []string) error {
		return printJSON(m.svc.Schema())
	}, "打印设置页声明：settings schema")

	r.Command("settings list", func(ctx context.Context, args []string) error {
		values, err := m.svc.Values(ctx)
		if err != nil {
			return err
		}
		// 按键名排序，diff 两次输出时不会因为 map 顺序乱跳。
		keys := make([]string, 0, len(values))
		for k := range values {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		type row struct {
			Key   string `json:"key"`
			Value string `json:"value"`
		}
		rows := make([]row, 0, len(keys))
		for _, k := range keys {
			rows = append(rows, row{Key: k, Value: values[k]})
		}
		return printJSON(rows)
	}, "列出全部配置的有效值：settings list")

	r.Command("settings set", func(ctx context.Context, args []string) error {
		if len(args) != 2 {
			return kernel.Ef(kernel.CodeInvalid, "用法: settings set <key> <value>")
		}
		values, err := m.svc.Update(ctx, map[string]string{args[0]: args[1]})
		if err != nil {
			return err
		}
		return printJSON(map[string]string{args[0]: values[args[0]]})
	}, "写入一项配置：settings set <key> <value>")

	r.Command("settings reset", func(ctx context.Context, args []string) error {
		values, err := m.svc.Reset(ctx, args)
		if err != nil {
			return err
		}
		return printJSON(values)
	}, "恢复默认值：settings reset [key...]")
}

// decodeArg 把第 i 个位置参数解到 dst。越界或 null 视为「未传」，保持零值。
func decodeArg(args []json.RawMessage, i int, dst any) error {
	if i >= len(args) || len(args[i]) == 0 || string(args[i]) == "null" {
		return nil
	}
	if err := json.Unmarshal(args[i], dst); err != nil {
		return kernel.Ef(kernel.CodeInvalid, "第 %d 个参数解析失败: %v", i+1, err)
	}
	return nil
}

// printJSON 把 CLI 输出统一成缩进 JSON。
func printJSON(v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return fmt.Errorf("序列化输出失败: %w", err)
	}
	fmt.Println(string(b))
	return nil
}
