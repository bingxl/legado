package rule

import (
	"encoding/json"
	"strings"

	"github.com/ohler55/ojg/jp"
)

// 本文件对齐 legado 的 AnalyzeByJSonPath.kt（jayway JsonPath）

// JsonGetString 取单个字符串
func JsonGetString(data any, pathRule string) string {
	if strings.TrimSpace(pathRule) == "" {
		return ""
	}
	typ, parts := SplitCombinator(pathRule, "&&", "||")
	if len(parts) > 1 && typ != "" {
		results := []string{}
		for _, p := range parts {
			t := JsonGetString(data, p)
			if t != "" {
				results = append(results, t)
				if typ == "||" {
					break
				}
			}
		}
		return strings.Join(results, "\n")
	}
	// 内嵌 {$.xxx}
	if replaced, ok := InnerBraceReplace(pathRule, "{$.", 1, 1, func(inner string) string {
		return JsonGetString(data, inner)
	}); ok {
		return replaced
	}
	vals := jsonRead(data, pathRule)
	if len(vals) == 0 {
		return ""
	}
	if len(vals) == 1 {
		return JsToString(vals[0])
	}
	strs := make([]string, 0, len(vals))
	for _, v := range vals {
		strs = append(strs, JsToString(v))
	}
	return strings.Join(strs, "\n")
}

// JsonGetStringList 取字符串列表
func JsonGetStringList(data any, pathRule string) []string {
	out := []string{}
	if strings.TrimSpace(pathRule) == "" {
		return out
	}
	typ, parts := SplitCombinator(pathRule, "&&", "||", "%%")
	if len(parts) > 1 && typ != "" {
		results := make([][]string, 0, len(parts))
		for _, p := range parts {
			t := JsonGetStringList(data, p)
			if len(t) > 0 {
				results = append(results, t)
				if typ == "||" {
					break
				}
			}
		}
		return mergeStringLists(typ, results)
	}
	if replaced, ok := InnerBraceReplace(pathRule, "{$.", 1, 1, func(inner string) string {
		return JsonGetString(data, inner)
	}); ok && replaced != "" {
		return []string{replaced}
	}
	vals := jsonRead(data, pathRule)
	for _, v := range vals {
		out = append(out, JsToString(v))
	}
	return out
}

// JsonGetList 取对象列表
func JsonGetList(data any, pathRule string) []any {
	out := []any{}
	if strings.TrimSpace(pathRule) == "" {
		return out
	}
	typ, parts := SplitCombinator(pathRule, "&&", "||", "%%")
	if len(parts) > 1 && typ != "" {
		lists := make([][]any, 0, len(parts))
		for _, p := range parts {
			t := JsonGetList(data, p)
			if len(t) > 0 {
				lists = append(lists, t)
				if typ == "||" {
					break
				}
			}
		}
		return mergeAnyLists(typ, lists)
	}
	vals := jsonRead(data, pathRule)
	if len(vals) == 1 {
		if arr, ok := vals[0].([]any); ok {
			return arr
		}
	}
	return vals
}

// JsonGetObject 取单个对象
func JsonGetObject(data any, pathRule string) any {
	vals := jsonRead(data, pathRule)
	if len(vals) == 0 {
		return nil
	}
	return vals[0]
}

func jsonRead(data any, path string) []any {
	if data == nil {
		return nil
	}
	expr, err := jp.ParseString(path)
	if err != nil {
		return nil
	}
	root := data
	if s, ok := data.(string); ok {
		var parsed any
		if err := json.Unmarshal([]byte(s), &parsed); err != nil {
			return nil
		}
		root = parsed
	}
	return expr.Get(root)
}

func mergeAnyLists(typ string, lists [][]any) []any {
	out := []any{}
	if len(lists) == 0 {
		return out
	}
	if typ == "%%" {
		maxLen := 0
		for _, l := range lists {
			if len(l) > maxLen {
				maxLen = len(l)
			}
		}
		for i := 0; i < maxLen; i++ {
			for _, l := range lists {
				if i < len(l) {
					out = append(out, l[i])
				}
			}
		}
		return out
	}
	for _, l := range lists {
		out = append(out, l...)
	}
	return out
}
