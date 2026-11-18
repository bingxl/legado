// Package rt 是三个宿主共用的运行时装配：打开数据库、构建注册表、
// 提供统一的调用入口。宿主自身不写业务，只做 I/O。
package rt

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/legado/core/boot"
	"github.com/legado/core/kernel"
	"github.com/legado/core/modules/registry"
)

// Version 由构建时注入（-ldflags "-X .../rt.Version=..."）。
var Version = "dev"

// Runtime 是「业务服务 + 注册表」的组合。
type Runtime struct {
	Biz *boot.App
	// Reg 是模块注册后的内核应用。
	Reg *kernel.App
}

// Home 返回数据根目录：LEGADO_HOME 优先，否则用用户配置目录。
func Home() string {
	if v := os.Getenv("LEGADO_HOME"); v != "" {
		return v
	}
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		dir = "."
	}
	return filepath.Join(dir, "legado")
}

// Open 装配运行时。version 为空时用包级 Version。
func Open(root string, opt boot.Options, version string) (*Runtime, error) {
	if root == "" {
		root = Home()
	}
	if version == "" {
		version = Version
	}
	biz, err := boot.New(root, opt)
	if err != nil {
		return nil, fmt.Errorf("装配失败: %w", err)
	}
	mods := registry.Modules(biz, version)
	// 先迁移再注册：模块自带 migration（不要运行时 CREATE TABLE），
	// 由内核按 DependsOn 顺序调用，避免并行开发各建各的表。
	for _, m := range mods {
		if mg, ok := m.(kernel.Migrator); ok {
			if err := mg.Migrate(context.Background()); err != nil {
				_ = biz.Close()
				return nil, fmt.Errorf("模块 %s 迁移失败: %w", m.Name(), err)
			}
		}
	}
	kapp, err := kernel.Boot(kernel.Env{
		Root:      root,
		UserAgent: opt.UserAgent,
		Version:   version,
	}, mods...)
	if err != nil {
		_ = biz.Close()
		return nil, err
	}
	kapp.OnClose(func() { _ = biz.Close() })
	return &Runtime{Biz: biz, Reg: kapp}, nil
}

// Close 释放资源。
func (r *Runtime) Close() error {
	if r == nil || r.Reg == nil {
		return nil
	}
	return r.Reg.Close()
}

// Call 按方法名调用，args 为位置参数（可为 nil）。
func (r *Runtime) Call(ctx context.Context, method string, args ...any) (any, error) {
	raw := make([]json.RawMessage, 0, len(args))
	for i, a := range args {
		// 允许直接传 json.RawMessage 以避免二次序列化。
		if rm, ok := a.(json.RawMessage); ok {
			raw = append(raw, rm)
			continue
		}
		b, err := json.Marshal(a)
		if err != nil {
			return nil, kernel.Ef(kernel.CodeInvalid, "第 %d 个参数无法序列化: %v", i+1, err)
		}
		raw = append(raw, b)
	}
	return r.Reg.Call(ctx, method, raw)
}

// Schema 导出方法表，供 Dart 侧生成常量与参数校验。
func (r *Runtime) Schema() any {
	return map[string]any{
		"version":  r.Reg.Env.Version,
		"platform": r.Reg.Env,
		"methods":  r.Reg.Methods(),
		"domains":  r.Reg.Domains(),
	}
}
