// Package legacy 把已有的 app 层服务批量暴露为控制面方法。
//
// 迁移期的作用（Architecture §9 M3 之前的过渡形态）：
// 业务实现已经在 core/app，但还没拆进各自模块目录。这里用反射一次性注册，
// 让 CLI / FFI / HTTP 立刻拿到 100+ 个方法，避免为了新宿主重写一层包装。
//
// 后续拆分方式：新功能写在 core/modules/<域>/ 里手写 Register；
// 老服务在某个模块稳定后，连带从本文件移除对应 Binding。
package legacy

import (
	"context"
	"encoding/json"
	"runtime"

	"github.com/legado/core/boot"
	"github.com/legado/core/kernel"
)

// Modules 返回由装配产物派生出的全部模块。
func Modules(a *boot.App, version string) []kernel.Module {
	mods := []kernel.Module{
		kernel.NewServiceModule("source", nil,
			kernel.Binding{Domain: "Source", Service: a.Source},
			kernel.Binding{Domain: "SourceDebug", Service: a.SourceDebug},
			kernel.Binding{Domain: "SourceLogin", Service: a.SourceLogin},
		),
		kernel.NewServiceModule("book", nil,
			kernel.Binding{Domain: "Shelf", Service: a.Bookshelf},
			kernel.Binding{Domain: "Library", Service: a.Library},
			kernel.Binding{Domain: "Reader", Service: a.Reader},
		),
		kernel.NewServiceModule("cache", nil,
			kernel.Binding{Domain: "Cache", Service: a.Cache},
		),
		kernel.NewServiceModule("audio", nil,
			kernel.Binding{Domain: "Audio", Service: a.Audio},
		),
		kernel.NewServiceModule("ai", nil,
			kernel.Binding{Domain: "Ai", Service: a.AI},
		),
		kernel.NewServiceModule("dict", nil,
			kernel.Binding{Domain: "Dict", Service: a.Dict},
		),
		kernel.NewServiceModule("webdav", nil,
			kernel.Binding{Domain: "WebDAV", Service: a.WebDAV},
		),
		kernel.NewServiceModule("rule", nil,
			kernel.Binding{Domain: "ReplaceRule", Service: a.ReplaceRule},
		),
		newSystem(version),
	}
	return mods
}

// system 暴露运行时信息，等价于旧 api/system.go，但不依赖任何 UI 框架。
type system struct {
	version string
}

func newSystem(version string) kernel.Module { return &system{version: version} }

func (s *system) Name() string        { return "system" }
func (s *system) DependsOn() []string { return nil }

func (s *system) Register(r *kernel.Registry) {
	r.Method("System.Info", func(ctx context.Context, args []json.RawMessage) (any, error) {
		return map[string]any{
			"version":  s.version,
			"platform": runtime.GOOS,
			"arch":     runtime.GOARCH,
			"go":       runtime.Version(),
		}, nil
	}, kernel.Doc("运行时版本与平台信息"))
}
