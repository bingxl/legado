package rule

import (
	"strings"
)

// 本文件对齐 legado 的 RuleAnalyzer.kt：
// 不用正则，按"括号/引号深度"切分规则，解决 && || %% @ 与 JSONPath/jsoup 选择器冲突的问题。

// SplitCombinator 按组合符（&& || %% 等）切分规则。
// 返回第一个命中的组合符与切分后的片段（与 legado 一致：只按首个命中的分隔符切分）。
func SplitCombinator(data string, splits ...string) (string, []string) {
	if data == "" || len(splits) == 0 {
		return "", []string{data}
	}
	// 找第一个命中位置
	firstPos := -1
	firstTok := ""
	for _, s := range splits {
		p := findTopLevel(data, s)
		if p >= 0 && (firstPos < 0 || p < firstPos) {
			firstPos = p
			firstTok = s
		}
	}
	if firstPos < 0 || firstTok == "" {
		return "", []string{data}
	}
	parts := splitAllTopLevel(data, firstTok)
	return firstTok, parts
}

// SplitTopLevel 按分隔符在"顶层"（括号/引号之外）切分
func SplitTopLevel(data, sep string) []string {
	if data == "" {
		return []string{""}
	}
	return splitAllTopLevel(data, sep)
}

// findTopLevel 返回 sep 首次出现的顶层位置，-1 表示未找到
func findTopLevel(data, sep string) int {
	depth := 0
	inSingle, inDouble := false, false
	runes := []rune(data)
	sepRunes := []rune(sep)
	for i := 0; i < len(runes); i++ {
		c := runes[i]
		switch {
		case c == '\\' && i+1 < len(runes):
			i++
			continue
		case c == '\'' && !inDouble:
			inSingle = !inSingle
		case c == '"' && !inSingle:
			inDouble = !inDouble
		case inSingle || inDouble:
		default:
			switch c {
			case '[', '(':
				depth++
			case ']', ')':
				if depth > 0 {
					depth--
				}
			}
			if depth == 0 && hasAt(runes, sepRunes, i) {
				return i
			}
		}
	}
	return -1
}

func hasAt(runes, sep []rune, i int) bool {
	if i+len(sep) > len(runes) {
		return false
	}
	for j := range sep {
		if runes[i+j] != sep[j] {
			return false
		}
	}
	return true
}

func splitAllTopLevel(data, sep string) []string {
	runes := []rune(data)
	sepRunes := []rune(sep)
	depth := 0
	inSingle, inDouble := false, false
	var parts []string
	last := 0
	for i := 0; i < len(runes); i++ {
		c := runes[i]
		switch {
		case c == '\\' && i+1 < len(runes):
			i++
			continue
		case c == '\'' && !inDouble:
			inSingle = !inSingle
		case c == '"' && !inSingle:
			inDouble = !inDouble
		case inSingle || inDouble:
		default:
			switch c {
			case '[', '(':
				depth++
			case ']', ')':
				if depth > 0 {
					depth--
				}
			}
			if depth == 0 && hasAt(runes, sepRunes, i) {
				parts = append(parts, string(runes[last:i]))
				i += len(sepRunes) - 1
				last = i + 1
			}
		}
	}
	parts = append(parts, string(runes[last:]))
	return parts
}

// Trim 修剪规则前的 '@' 或空白符（对齐 RuleAnalyzer.trim）
func Trim(data string) string {
	runes := []rune(data)
	i := 0
	for i < len(runes) && (runes[i] == '@' || runes[i] <= '!') {
		i++
	}
	return string(runes[i:])
}

// InnerBraceReplace 替换内嵌规则 {{...}}（对齐 RuleAnalyzer.innerRule / EVAL_PATTERN）
//
// open 形如 "{{"，fn 返回替换值。第二返回值表示是否命中过至少一段内嵌规则：
// 只要命中过就返回替换后的完整串——**替换值为空串时同样生效**（与 legado 的
// Kt 实现一致，如首页要把 `{{page === 1 ? ” : '_2_' + page}}` 整段去掉）。
// 未命中任何内嵌规则时返回 ("", false)，调用方据此判断是否沿用原串。
func InnerBraceReplace(data, open string, startStep, endStep int, fn func(string) string) (string, bool) {
	if !strings.Contains(data, open) {
		return "", false
	}
	var sb strings.Builder
	start := 0
	replaced := false
	for {
		p := strings.Index(data[start:], open)
		if p < 0 {
			break
		}
		abs := start + p
		innerStart := abs + startStep
		endIdx, ok := matchBrace(data, abs)
		if !ok {
			start = abs + len(open)
			continue
		}
		innerEnd := max(endIdx-endStep+1, innerStart)
		inner := data[innerStart:innerEnd]
		val := fn(inner)
		sb.WriteString(data[start:abs])
		sb.WriteString(val)
		replaced = true
		start = endIdx + 1
	}
	if !replaced {
		return "", false
	}
	sb.WriteString(data[start:])
	return sb.String(), true
}

// matchBrace 给定 open 的最后一个字符位置，返回配对闭括号位置
func matchBrace(data string, openIdx int) (int, bool) {
	depth := 0
	for i := openIdx; i < len(data); i++ {
		c := data[i]
		if c == '\\' {
			i++
			continue
		}
		if c == '{' {
			depth++
		} else if c == '}' {
			depth--
			if depth == 0 {
				return i, true
			}
		}
	}
	return -1, false
}
