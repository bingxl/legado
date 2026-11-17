package util

import (
	"strings"
)

// ParseLooseStringMap 解析书源里手写的键值对象，对齐 GSON lenient 语义。
//
// 书源的 @put:{...} 几乎都写成 `{book:id}`、`{bid:@css:span.id@text}` 这种
// 「键和值都不加引号」的形式（Kotlin 侧靠 GSON 的宽松模式吃掉），标准 JSON 解析
// 会直接失败——失败后变量就静默丢掉，表现为 @get 取到空串。
//
// 规则：去掉最外层大括号，按顶层逗号切分，每段按第一个冒号切成键/值，两侧引号去掉。
// 空值、空段忽略；解析不出任何键值时返回 false。
//
// 优先用 UnmarshalLooseJSON：它能处理嵌套与转义，本函数只作为
// 「值里含裸冒号、整体不是合法结构」时的最后兜底。
func ParseLooseStringMap(s string) (map[string]string, bool) {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && s[0] == '{' && s[len(s)-1] == '}' {
		s = s[1 : len(s)-1]
	}
	out := map[string]string{}
	if strings.TrimSpace(s) == "" {
		return out, false
	}
	for _, seg := range splitTopLevel(s) {
		k, v, ok := strings.Cut(seg, ":")
		if !ok {
			continue
		}
		k = trimQuotes(strings.TrimSpace(k))
		if k == "" {
			continue
		}
		out[k] = trimQuotes(strings.TrimSpace(v))
	}
	return out, len(out) > 0
}

// splitTopLevel 按不在引号内的逗号切分
func splitTopLevel(s string) []string {
	var (
		out   []string
		start int
		quote rune
	)
	for i, r := range s {
		switch {
		case quote != 0:
			if r == quote {
				quote = 0
			}
		case r == '"' || r == '\'':
			quote = r
		case r == ',':
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	out = append(out, s[start:])
	return out
}

func trimQuotes(s string) string {
	if len(s) >= 2 {
		if (s[0] == '"' && s[len(s)-1] == '"') || (s[0] == '\'' && s[len(s)-1] == '\'') {
			return s[1 : len(s)-1]
		}
	}
	return s
}
