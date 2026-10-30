package rule

import (
	"encoding/json"
	"fmt"
	"maps"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/legado/legado-go/pkg/util"
)

// Mode 规则解析模式（对齐 legado AnalyzeRule.Mode）
type Mode int

const (
	ModeXPath Mode = iota
	ModeJson
	ModeDefault
	ModeJs
	ModeRegex
)

var (
	jsPattern    = regexp.MustCompile(`(?is)<js>([\s\S]*?)</js>|@js:([\s\S]*)`)
	putPattern   = regexp.MustCompile(`(?i)@put:(\{[^}]+?\})`)
	evalPattern  = regexp.MustCompile(`(?i)@get:\{[^}]+?\}|\{\{[\s\S]*?\}\}`)
	groupPattern = regexp.MustCompile(`\$\d{1,2}`)
)

const (
	getRuleType     = -2
	jsRuleType      = -1
	defaultRuleType = 0
)

// SourceRule 单条规则（对齐 legado AnalyzeRule.SourceRule）
type SourceRule struct {
	ar *AnalyzeRule

	Rule         string
	Mode         Mode
	ReplaceRegex string
	Replacement  string
	ReplaceFirst bool
	PutMap       map[string]string

	ruleParam []string
	ruleType  []int
}

func newSourceRule(ar *AnalyzeRule, ruleStr string, mode Mode) *SourceRule {
	sr := &SourceRule{ar: ar, Mode: mode, PutMap: map[string]string{}}
	rule := sr.detectMode(ruleStr)
	rule = sr.splitPutRule(rule)

	start := 0
	loc := evalPattern.FindStringIndex(rule)
	if loc != nil {
		tmp := rule[start:loc[0]]
		if sr.Mode != ModeJs && sr.Mode != ModeRegex && (loc[0] == 0 || !strings.Contains(tmp, "##")) {
			sr.Mode = ModeRegex
		}
		for loc != nil {
			if loc[0] > start {
				sr.splitRegex(rule[start:loc[0]])
			}
			t := rule[loc[0]:loc[1]]
			switch {
			case strings.HasPrefix(strings.ToLower(t), "@get:"):
				sr.ruleType = append(sr.ruleType, getRuleType)
				sr.ruleParam = append(sr.ruleParam, t[6:len(t)-1])
			default:
				sr.ruleType = append(sr.ruleType, jsRuleType)
				sr.ruleParam = append(sr.ruleParam, t[2:len(t)-2])
			}
			start = loc[1]
			rest := rule[start:]
			loc2 := evalPattern.FindStringIndex(rest)
			if loc2 == nil {
				loc = nil
			} else {
				loc = []int{start + loc2[0], start + loc2[1]}
			}
		}
	}
	if len(rule) > start {
		sr.splitRegex(rule[start:])
	}
	sr.Rule = rule
	return sr
}

func (sr *SourceRule) detectMode(ruleStr string) string {
	if sr.Mode == ModeJs || sr.Mode == ModeRegex {
		return ruleStr
	}
	lower := strings.ToLower(ruleStr)
	switch {
	case strings.HasPrefix(lower, "@css:"):
		sr.Mode = ModeDefault
		return ruleStr
	case strings.HasPrefix(ruleStr, "@@"):
		sr.Mode = ModeDefault
		return ruleStr[2:]
	case strings.HasPrefix(lower, "@xpath:"):
		sr.Mode = ModeXPath
		return ruleStr[7:]
	case strings.HasPrefix(lower, "@json:"):
		sr.Mode = ModeJson
		return ruleStr[6:]
	case (sr.ar != nil && sr.ar.isJSON) || strings.HasPrefix(ruleStr, "$.") || strings.HasPrefix(ruleStr, "$["):
		sr.Mode = ModeJson
		return ruleStr
	case strings.HasPrefix(ruleStr, "/"):
		sr.Mode = ModeXPath
		return ruleStr
	}
	return ruleStr
}

// splitPutRule 分离并移除 @put:{...}
func (sr *SourceRule) splitPutRule(ruleStr string) string {
	out := ruleStr
	for _, m := range putPattern.FindAllStringSubmatch(ruleStr, -1) {
		out = strings.Replace(out, m[0], "", 1)
		var obj map[string]string
		if err := json.Unmarshal([]byte(m[1]), &obj); err == nil {
			maps.Copy(sr.PutMap, obj)
			continue
		}
		// 非规范 JSON（键无引号）容错
		if err := json.Unmarshal([]byte(util.RelaxJSONKeys(m[1])), &obj); err == nil {
			maps.Copy(sr.PutMap, obj)
			continue
		}
		// 书源里最常见的形式：键和值都不加引号（{book:id}、{bid:@css:a@text}）。
		// Kotlin 侧靠 GSON 宽松模式解析，这里只能自己按最宽松的规则切分。
		if obj, ok := util.ParseLooseStringMap(m[1]); ok {
			maps.Copy(sr.PutMap, obj)
		}
	}
	return out
}

// splitRegex 拆分 $1 $2 等分组引用
func (sr *SourceRule) splitRegex(ruleStr string) {
	start := 0
	arr := strings.Split(ruleStr, "##")
	target := arr[0]
	loc := groupPattern.FindStringIndex(target)
	if loc != nil {
		if sr.Mode != ModeJs && sr.Mode != ModeRegex {
			sr.Mode = ModeRegex
		}
		for loc != nil {
			if loc[0] > start {
				sr.ruleType = append(sr.ruleType, defaultRuleType)
				sr.ruleParam = append(sr.ruleParam, target[start:loc[0]])
			}
			tok := target[loc[0]:loc[1]]
			n, _ := strconv.Atoi(tok[1:])
			sr.ruleType = append(sr.ruleType, n)
			sr.ruleParam = append(sr.ruleParam, tok)
			start = loc[1]
			rest := target[start:]
			l2 := groupPattern.FindStringIndex(rest)
			if l2 == nil {
				loc = nil
			} else {
				loc = []int{start + l2[0], start + l2[1]}
			}
		}
	}
	if len(ruleStr) > start {
		sr.ruleType = append(sr.ruleType, defaultRuleType)
		sr.ruleParam = append(sr.ruleParam, ruleStr[start:])
	}
}

func (sr *SourceRule) getParamSize() int { return len(sr.ruleParam) }

// isRule 判断 {{}} 中内容是规则而非 JS
func isRule(s string) bool {
	return strings.HasPrefix(s, "@") || strings.HasPrefix(s, "$.") ||
		strings.HasPrefix(s, "$[") || strings.HasPrefix(s, "//")
}

// MakeUpRule 用 result 还原最终规则串，并拆出 ## 替换部分
func (sr *SourceRule) MakeUpRule(result any) {
	if len(sr.ruleParam) > 0 {
		parts := make([]string, 0, len(sr.ruleParam))
		for i := range slices.Backward(sr.ruleParam) {
			typ := sr.ruleType[i]
			var v string
			switch {
			case typ > defaultRuleType:
				if list, ok := toStrList(result); ok && len(list) > typ && list[typ] != nil {
					v = fmt.Sprint(list[typ])
				} else {
					v = sr.ruleParam[i]
				}
			case typ == jsRuleType:
				p := sr.ruleParam[i]
				if isRule(p) {
					if sr.ar != nil {
						v = sr.ar.getString(sr.ar.SplitSourceRule(p), nil, false)
					}
				} else {
					v = JsToString(sr.ar.evalJS(p, result))
				}
			case typ == getRuleType:
				v = sr.ar.get(sr.ruleParam[i])
			default:
				v = sr.ruleParam[i]
			}
			parts = append(parts, v)
		}
		// parts 是逆序收集的，反转后拼接
		var sb strings.Builder
		for _, p := range slices.Backward(parts) {
			sb.WriteString(p)
		}
		sr.Rule = sb.String()
	}
	arr := strings.Split(sr.Rule, "##")
	sr.Rule = strings.TrimSpace(arr[0])
	sr.ReplaceRegex, sr.Replacement, sr.ReplaceFirst = "", "", false
	if len(arr) > 1 {
		sr.ReplaceRegex = arr[1]
	}
	if len(arr) > 2 {
		sr.Replacement = arr[2]
	}
	if len(arr) > 3 {
		sr.ReplaceFirst = true
	}
}

// ApplyReplace 执行 ## 替换
func (sr *SourceRule) ApplyReplace(result string) string {
	if sr.ReplaceRegex == "" {
		return result
	}
	re, err := regexp.Compile(sr.ReplaceRegex)
	if err != nil {
		return result
	}
	if sr.ReplaceFirst {
		loc := re.FindStringIndex(result)
		if loc == nil {
			return ""
		}
		return result[:loc[0]] + re.ReplaceAllString(result[loc[0]:loc[1]], sr.Replacement) + result[loc[1]:]
	}
	return re.ReplaceAllString(result, sr.Replacement)
}

func toStrList(v any) ([]any, bool) {
	switch t := v.(type) {
	case []any:
		return t, true
	case []string:
		out := make([]any, 0, len(t))
		for _, s := range t {
			out = append(out, s)
		}
		return out, true
	}
	return nil, false
}

// JsToString 对齐 legado 对 JS 返回值的字符串化（整数 double 去小数位）。
// 导出供 urlx 等上层包复用，避免各写一份。
func JsToString(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return t
	case float64:
		if t == float64(int64(t)) {
			return strconv.FormatInt(int64(t), 10)
		}
		return strconv.FormatFloat(t, 'f', -1, 64)
	case float32:
		return strconv.FormatFloat(float64(t), 'f', -1, 32)
	case int:
		return strconv.Itoa(t)
	case int64:
		return strconv.FormatInt(t, 10)
	case bool:
		return strconv.FormatBool(t)
	case []any:
		parts := make([]string, 0, len(t))
		for _, x := range t {
			parts = append(parts, JsToString(x))
		}
		return strings.Join(parts, "\n")
	case map[string]any:
		b, _ := json.Marshal(t)
		return string(b)
	case *NativeObject:
		return t.String()
	case []string:
		return strings.Join(t, "\n")
	}
	return fmt.Sprint(v)
}
