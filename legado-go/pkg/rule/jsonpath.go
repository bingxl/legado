package rule

import (
	"encoding/json"
	"regexp"
	"slices"
	"strconv"
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

// jsonFuncRe 匹配 jayway JsonPath 的尾部聚合函数
// （ojg 不支持，legado 的真实书源里 `$.data.list.length()` 很常见）
var jsonFuncRe = regexp.MustCompile(`\.(length|min|max|avg|sum)\(\)$`)

func jsonRead(data any, path string) []any {
	if data == nil {
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
	// 聚合函数：先算基础路径，再在结果集上应用
	if m := jsonFuncRe.FindStringSubmatch(path); m != nil {
		base := path[:len(path)-len(m[0])]
		vals := jsonRead(root, base)
		return applyJSONFunc(m[1], vals)
	}
	expr, err := jp.ParseString(path)
	if err != nil {
		return nil
	}
	return expr.Get(root)
}

// applyJSONFunc 在路径结果集上执行 length/min/max/avg/sum。
// 与 jayway 一致：结果集只有 1 个容器值时作用于容器本身，
// 否则作用于整个结果集。
func applyJSONFunc(name string, vals []any) []any {
	if len(vals) == 0 {
		return nil
	}
	if name == "length" {
		if len(vals) == 1 {
			if n, ok := jsonLength(vals[0]); ok {
				return []any{n}
			}
		}
		return []any{len(vals)}
	}
	nums := make([]float64, 0, len(vals))
	if len(vals) == 1 {
		if arr, ok := vals[0].([]any); ok {
			for _, x := range arr {
				if f, ok := jsonNumber(x); ok {
					nums = append(nums, f)
				}
			}
		}
	}
	if len(nums) == 0 {
		for _, x := range vals {
			if f, ok := jsonNumber(x); ok {
				nums = append(nums, f)
			}
		}
	}
	if len(nums) == 0 {
		return nil
	}
	switch name {
	case "min":
		return []any{slices.Min(nums)}
	case "max":
		return []any{slices.Max(nums)}
	case "sum":
		s := 0.0
		for _, f := range nums {
			s += f
		}
		return []any{s}
	case "avg":
		s := 0.0
		for _, f := range nums {
			s += f
		}
		return []any{s / float64(len(nums))}
	}
	return nil
}

// jsonLength 对齐 jayway 的 length()：数组/对象取元素数，字符串取字符数
func jsonLength(v any) (int, bool) {
	switch t := v.(type) {
	case []any:
		return len(t), true
	case map[string]any:
		return len(t), true
	case string:
		return len([]rune(t)), true
	}
	return 0, false
}

func jsonNumber(v any) (float64, bool) {
	switch t := v.(type) {
	case float64:
		return t, true
	case int:
		return float64(t), true
	case int64:
		return float64(t), true
	case json.Number:
		f, err := t.Float64()
		return f, err == nil
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(t), 64)
		return f, err == nil
	}
	return 0, false
}

// mergeAnyLists 同 mergeStringLists：`%%` 以第 1 段长度为界。
func mergeAnyLists(typ string, lists [][]any) []any {
	out := []any{}
	if len(lists) == 0 {
		return out
	}
	if typ == "%%" {
		for i := range lists[0] {
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
