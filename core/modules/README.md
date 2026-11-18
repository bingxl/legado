# core/modules —— 模块开发契约

> 配套：`docs/ARCHITECTURE-V2.md` §4（模块自描述）、`docs/MODULE-PLAN.md` §6（并行规则）。

## 一个模块长什么样

```go
package rss

import (
    "context"
    "encoding/json"

    "github.com/legado/core/kernel"
)

type Module struct{ svc *Service }

func New(svc *Service) *Module { return &Module{svc: svc} }

func (m *Module) Name() string        { return "rss" }
func (m *Module) DependsOn() []string { return nil }

// 可选：需要建表时实现，rt.Open 会在 Boot 之前调用。
func (m *Module) Migrate(ctx context.Context) error { return m.svc.Migrate(ctx) }

func (m *Module) Register(r *kernel.Registry) {
    r.Method("Rss.Source.List", func(ctx context.Context, args []json.RawMessage) (any, error) {
        return m.svc.ListSources(ctx)
    }, kernel.Doc("列出 RSS 源"))

    // CLI 子命令：`legado rss list`
    r.Command("rss list", func(ctx context.Context, args []string) error {
        _, err := m.svc.ListSources(ctx)
        return err
    }, "列出 RSS 源")
}
```

## 硬规则

| 规则 | 说明 |
|---|---|
| **只改自己的目录** | 模块之间不 import；共享的只有 `kernel`、`domain`、`port` |
| **参数按位置** | `args` 是位置参数数组（Go 反射拿不到参数名）；Dart 侧由 `legado schema` 导出校验 |
| **不写 SQL 以外的存储** | 数据落 SQLite；新表写进本模块的 `migration.go`，用 `CREATE TABLE IF NOT EXISTS` |
| **不依赖宿主** | 禁止 import `wails`、`net/http` 的 Server、`hosts/*` |
| **大对象不进控制面** | 正文/图片/音频走 HTTP 数据面，方法只返回元数据或短字符串 |
| **必须可 headless 验证** | 每个模块至少一个 `_test.go`，并能用 `legado call <Domain>.<Verb>` 跑通 |
| **错误带码** | 用 `kernel.Ef(kernel.CodeNotFound, ...)`，不要裸 `errors.New` |

## 错误码

`NOT_FOUND` / `INVALID_ARGUMENT` / `SOURCE_EMPTY` / `NET_TIMEOUT` / `AUTH_REQUIRED` / `UNSUPPORTED` / `INTERNAL`

## 命名

- 方法：`<Domain>.<Verb>`，Domain 首字母大写（`Rss`、`Tts`、`Bookmark`）
- CLI：小写域 + 动词（`rss list`、`rss refresh`）
- 文件：`module.go`（注册）/ `service.go`（业务）/ `migration.go`（建表）/ `dto.go`（本模块结构）/ `*_test.go`

## 与旧代码的关系

`core/app/*.go` 是 Wails 时代留下的「胖服务」，目前通过 `core/modules/legacy` 用反射整体暴露
（130 个方法）。新功能一律写在 `core/modules/<域>/` 里，**不要再往 `core/app` 加东西**；
等某个域完全稳定，再把对应服务从 legacy 里摘掉。
