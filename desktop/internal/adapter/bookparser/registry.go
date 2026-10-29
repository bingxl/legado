// Package bookparser 实现本地书籍（EPUB / TXT / PDF / 漫画）的解析。
//
// 每种格式一个解析器，统一实现 port.LocalBookParser，由 Registry 按格式分发。
//
// 阅读器通过 Resource 字段定位章节内容，各格式的语义不同：
//   - EPUB：spine 条目的 href
//   - TXT：  "起始偏移:结束偏移"（字节偏移，UTF-8 解码后）
//   - PDF：  页码
//   - 漫画： 压缩包内路径或相对文件路径
package bookparser

import (
	"context"
	"fmt"
	"sync"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// Registry 按格式保存解析器，实现 port.LocalBookParserRegistry。
type Registry struct {
	mu       sync.RWMutex
	parsers  map[domain.BookFormat]port.LocalBookParser
	fallback port.LocalBookParser
}

// NewRegistry 创建空的解析器注册表。
func NewRegistry() *Registry {
	return &Registry{parsers: make(map[domain.BookFormat]port.LocalBookParser)}
}

var _ port.LocalBookParserRegistry = (*Registry)(nil)

// Register 注册一个解析器，同名格式后者覆盖前者。
func (r *Registry) Register(p port.LocalBookParser) {
	if p == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.parsers[p.Format()] = p
}

// Resolve 按格式返回解析器；无匹配时回退到 fallback，仍无则返回错误。
func (r *Registry) Resolve(f domain.BookFormat) (port.LocalBookParser, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if p, ok := r.parsers[f]; ok {
		return p, nil
	}
	if r.fallback != nil {
		return r.fallback, nil
	}
	return nil, fmt.Errorf("%w: %s", domain.ErrUnsupportedFormat, f.String())
}

// SetFallback 设置兜底解析器，用于处理未注册的格式。
func (r *Registry) SetFallback(p port.LocalBookParser) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.fallback = p
}

// Formats 返回已注册的全部格式，便于前端展示"支持哪些格式"。
func (r *Registry) Formats() []domain.BookFormat {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]domain.BookFormat, 0, len(r.parsers))
	for f := range r.parsers {
		out = append(out, f)
	}
	return out
}

// Parse 按格式解析文件，是 Registry 的便捷方法。
func (r *Registry) Parse(ctx context.Context, f domain.BookFormat, path string) (*port.ParsedBook, error) {
	p, err := r.Resolve(f)
	if err != nil {
		return nil, err
	}
	return p.Parse(ctx, path)
}
