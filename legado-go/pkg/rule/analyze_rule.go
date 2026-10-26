package rule

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"github.com/legado/legado-go/pkg/js"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/util"
	"golang.org/x/net/html"
)

// AnalyzeRule 规则引擎总入口（对齐 legado model/analyzeRule/AnalyzeRule.kt）
type AnalyzeRule struct {
	Source   *model.BookSource
	Book     *model.Book
	Chapter  *model.BookChapter
	RuleData *model.RuleData

	content        any
	baseUrl        string
	redirectUrl    string
	nextChapterUrl string
	isJSON         bool
	isRegex        bool

	nodes       []*html.Node
	nodesParsed bool
	jsonData    any
	jsonParsed  bool

	mu        sync.RWMutex
	ruleCache map[string][]*SourceRule
	// 无 chapter/book/ruleData/source 上下文时的兜底变量存储
	vars   map[string]string
	varsMu sync.RWMutex
}

// New 创建规则引擎
func New(source *model.BookSource) *AnalyzeRule {
	return &AnalyzeRule{
		Source:    source,
		ruleCache: map[string][]*SourceRule{},
	}
}

// —— 上下文设置 ——

// SetContent 设置待解析内容（HTML/JSON 字符串、节点或 JSON 对象）
func (ar *AnalyzeRule) SetContent(content any, baseUrl ...string) *AnalyzeRule {
	if content == nil {
		content = ""
	}
	ar.mu.Lock()
	ar.content = content
	ar.nodesParsed = false
	ar.jsonParsed = false
	ar.nodes = nil
	ar.jsonData = nil
	switch c := content.(type) {
	case *html.Node:
		ar.isJSON = false
		ar.nodes = []*html.Node{c}
		ar.nodesParsed = true
	case []*html.Node:
		ar.isJSON = false
		ar.nodes = c
		ar.nodesParsed = true
	case string:
		ar.isJSON = isJSONString(c)
	case *NativeObject:
		// JS 返回的对象：legado 中 toString() 后不是 JSON，故 isJSON=false
		ar.isJSON = false
		ar.jsonData = c.M
		ar.jsonParsed = true
	case map[string]any:
		ar.isJSON = true
		ar.jsonData = c
		ar.jsonParsed = true
	case []any:
		ar.isJSON = true
		ar.jsonData = c
		ar.jsonParsed = true
	default:
		ar.isJSON = isJSONString(fmt.Sprint(c))
	}
	ar.mu.Unlock()
	if len(baseUrl) > 0 && baseUrl[0] != "" {
		ar.SetBaseUrl(baseUrl[0])
	}
	return ar
}

func (ar *AnalyzeRule) SetBaseUrl(u string) *AnalyzeRule {
	if u != "" {
		ar.mu.Lock()
		ar.baseUrl = u
		ar.mu.Unlock()
	}
	return ar
}

func (ar *AnalyzeRule) SetRedirectUrl(u string) *AnalyzeRule {
	if u == "" || util.IsDataUrl(u) {
		return ar
	}
	ar.mu.Lock()
	ar.redirectUrl = u
	ar.mu.Unlock()
	return ar
}

func (ar *AnalyzeRule) SetBook(b *model.Book) *AnalyzeRule {
	ar.Book = b
	return ar
}

func (ar *AnalyzeRule) SetChapter(c *model.BookChapter) *AnalyzeRule {
	ar.Chapter = c
	return ar
}

func (ar *AnalyzeRule) SetNextChapterUrl(u string) *AnalyzeRule {
	ar.nextChapterUrl = u
	return ar
}

func (ar *AnalyzeRule) SetRuleData(d *model.RuleData) *AnalyzeRule {
	ar.RuleData = d
	return ar
}

func (ar *AnalyzeRule) GetBaseUrl() string { return ar.baseUrl }

func (ar *AnalyzeRule) GetContent() any { return ar.content }

// —— 规则切分 ——

// SplitSourceRule 拆分规则串为规则列表（带缓存）
func (ar *AnalyzeRule) SplitSourceRule(ruleStr string, allInOne ...bool) []*SourceRule {
	if ruleStr == "" {
		return nil
	}
	ai := false
	if len(allInOne) > 0 {
		ai = allInOne[0]
	}
	ar.mu.RLock()
	key := fmt.Sprintf("%v|%s|%v|%v", ai, ruleStr, ar.isJSON, ar.isRegex)
	if cached, ok := ar.ruleCache[key]; ok {
		ar.mu.RUnlock()
		return cached
	}
	ar.mu.RUnlock()

	list := ar.splitSourceRule(ruleStr, ai)
	ar.mu.Lock()
	if ar.ruleCache == nil {
		ar.ruleCache = map[string][]*SourceRule{}
	}
	ar.ruleCache[key] = list
	ar.mu.Unlock()
	return list
}

func (ar *AnalyzeRule) splitSourceRule(ruleStr string, allInOne bool) []*SourceRule {
	if ruleStr == "" {
		return nil
	}
	list := make([]*SourceRule, 0, 2)
	mode := ModeDefault
	start := 0
	if allInOne && strings.HasPrefix(ruleStr, ":") {
		mode = ModeRegex
		ar.isRegex = true
		start = 1
	} else if ar.isRegex {
		mode = ModeRegex
	}
	for _, m := range jsPattern.FindAllStringSubmatchIndex(ruleStr, -1) {
		if m[0] > start {
			tmp := strings.TrimSpace(ruleStr[start:m[0]])
			if tmp != "" {
				list = append(list, newSourceRule(ar, tmp, mode))
			}
		}
		code := ""
		if m[4] >= 0 && m[5] >= 0 {
			code = ruleStr[m[4]:m[5]] // @js: 分组2
		} else if m[2] >= 0 && m[3] >= 0 {
			code = ruleStr[m[2]:m[3]] // <js> 分组1
		}
		list = append(list, newSourceRule(ar, code, ModeJs))
		start = m[1]
	}
	if len(ruleStr) > start {
		tmp := strings.TrimSpace(ruleStr[start:])
		if tmp != "" {
			list = append(list, newSourceRule(ar, tmp, mode))
		}
	}
	return list
}

// —— 变量（供 JS 的 java.put/java.get 使用）——

// Put 保存变量（chapter > book > ruleData > source）
func (ar *AnalyzeRule) Put(key, value string) string {
	if key == "bookName" || key == "title" {
		ar.log("≡变量 " + key + " 在特定情况下会被覆盖，建议使用其他键名")
	}
	switch {
	case ar.Chapter != nil:
		ar.Chapter.PutVariable(key, value)
	case ar.Book != nil:
		ar.Book.PutVariable(key, value)
	case ar.RuleData != nil:
		ar.RuleData.PutVariable(key, value)
	case ar.Source != nil:
		ar.Source.Put(key, value)
	default:
		ar.varsMu.Lock()
		if ar.vars == nil {
			ar.vars = map[string]string{}
		}
		ar.vars[key] = value
		ar.varsMu.Unlock()
	}
	return value
}

// Get 读取变量
func (ar *AnalyzeRule) Get(key string) string {
	switch key {
	case "bookName":
		if ar.Book != nil {
			return ar.Book.Name
		}
	case "title":
		if ar.Chapter != nil {
			return ar.Chapter.Title
		}
	}
	cands := []string{}
	if ar.Chapter != nil {
		cands = append(cands, ar.Chapter.GetVariable(key))
	}
	if ar.Book != nil {
		cands = append(cands, ar.Book.GetVariable(key))
	}
	if ar.RuleData != nil {
		cands = append(cands, ar.RuleData.GetVariable(key))
	}
	if ar.Source != nil {
		cands = append(cands, ar.Source.Get(key))
	}
	for _, c := range cands {
		if c != "" {
			return c
		}
	}
	ar.varsMu.RLock()
	defer ar.varsMu.RUnlock()
	return ar.vars[key]
}

func (ar *AnalyzeRule) put(key string) string { return ar.Put(key, ar.GetString(key)) }

// —— 求值 ——

func (ar *AnalyzeRule) ensureNodes() []*html.Node {
	ar.mu.Lock()
	defer ar.mu.Unlock()
	if ar.nodesParsed {
		return ar.nodes
	}
	ar.nodesParsed = true
	if s, ok := ar.content.(string); ok {
		doc, err := html.Parse(strings.NewReader(s))
		if err == nil && doc != nil {
			ar.nodes = []*html.Node{doc}
		}
	}
	if ar.nodes == nil {
		ar.nodes = []*html.Node{}
	}
	return ar.nodes
}

func (ar *AnalyzeRule) ensureJSON() any {
	ar.mu.Lock()
	defer ar.mu.Unlock()
	if ar.jsonParsed {
		return ar.jsonData
	}
	ar.jsonParsed = true
	if s, ok := ar.content.(string); ok {
		var v any
		if err := json.Unmarshal([]byte(s), &v); err == nil {
			ar.jsonData = v
		}
	}
	return ar.jsonData
}

// nodesFor Default(jsoup) 模式使用的节点集合
func (ar *AnalyzeRule) nodesFor(result any) []*html.Node {
	if result == nil {
		return ar.ensureNodes()
	}
	switch t := result.(type) {
	case []*html.Node:
		if len(t) > 0 {
			return t
		}
		return ar.ensureNodes()
	case *html.Node:
		return []*html.Node{t}
	case []any:
		nodes := make([]*html.Node, 0, len(t))
		for _, x := range t {
			if n, ok := x.(*html.Node); ok {
				nodes = append(nodes, n)
			} else if w, ok := x.(*js.ElementWrap); ok {
				nodes = append(nodes, w.Node())
			}
		}
		if len(nodes) > 0 {
			return nodes
		}
	}
	return ar.ensureNodes()
}

// strFor XPath / Regex 模式使用的字符串
func (ar *AnalyzeRule) strFor(result any) string {
	if result == nil {
		if s, ok := ar.content.(string); ok {
			return s
		}
		return renderNodes(ar.ensureNodes())
	}
	switch t := result.(type) {
	case string:
		return t
	case *html.Node:
		return util.Render(t)
	case []*html.Node:
		return renderNodes(t)
	case []any:
		var sb strings.Builder
		for _, x := range t {
			switch y := x.(type) {
			case string:
				sb.WriteString(y)
			case *html.Node:
				sb.WriteString(util.Render(y))
			default:
				sb.WriteString(fmt.Sprint(y))
			}
		}
		return sb.String()
	}
	return fmt.Sprint(result)
}

// jsonFor Json 模式使用的数据
func (ar *AnalyzeRule) jsonFor(result any) any {
	r := result
	if r == nil {
		r = ar.content
	}
	switch t := r.(type) {
	case nil:
		return ""
	case string:
		return t
	case *NativeObject:
		return t.M
	case map[string]any, []any:
		return t
	case *html.Node:
		return util.Render(t)
	case []*html.Node:
		return renderNodes(t)
	}
	return ar.ensureJSON()
}

func renderNodes(nodes []*html.Node) string {
	var sb strings.Builder
	for _, n := range nodes {
		sb.WriteString(util.Render(n))
	}
	return sb.String()
}

func (ar *AnalyzeRule) evalScalar(mode Mode, rule string, result any, isURL bool) any {
	switch mode {
	case ModeJs:
		return ar.evalJS(rule, result)
	case ModeJson:
		l := JsonGetStringList(ar.jsonFor(result), rule)
		if len(l) > 0 {
			return l[0]
		}
		return ""
	case ModeXPath:
		l := XPathGetStringList(ar.strFor(result), rule)
		if len(l) > 0 {
			return l[0]
		}
		return ""
	case ModeDefault:
		l := JsoupGetStringList(ar.nodesFor(result), rule)
		switch len(l) {
		case 0:
			return ""
		case 1:
			return l[0]
		}
		// 对齐 legado：取单个字符串时多结果用换行拼接（getString），
		// 取 URL 时只取第一个（getString0）
		if isURL {
			return l[0]
		}
		return strings.Join(l, "\n")
	}
	// Mode.Regex：与 Kotlin 一致，直接返回拼好的规则串
	return rule
}

func (ar *AnalyzeRule) evalList(mode Mode, rule string, result any) any {
	switch mode {
	case ModeJs:
		return toSlice(ar.evalJS(rule, result))
	case ModeJson:
		return JsonGetStringList(ar.jsonFor(result), rule)
	case ModeXPath:
		return XPathGetStringList(ar.strFor(result), rule)
	case ModeDefault:
		return JsoupGetStringList(ar.nodesFor(result), rule)
	}
	return rule
}

func (ar *AnalyzeRule) evalElements(mode Mode, rule string, result any) []any {
	switch mode {
	case ModeJs:
		return toSlice(ar.evalJS(rule, result))
	case ModeJson:
		return JsonGetList(ar.jsonFor(result), rule)
	case ModeXPath:
		out := []any{}
		for _, n := range XPathGetElements(ar.strFor(result), rule) {
			out = append(out, n)
		}
		return out
	case ModeRegex:
		res := RegexGetElements(ar.strFor(result), SplitRegexRules(rule), 0)
		out := make([]any, 0, len(res))
		for _, r := range res {
			out = append(out, r)
		}
		return out
	}
	out := []any{}
	for _, n := range JsoupGetElements(ar.nodesFor(result), rule) {
		out = append(out, n)
	}
	return out
}

func toSlice(v any) []any {
	switch t := v.(type) {
	case nil:
		return []any{}
	case []any:
		return t
	case []string:
		out := make([]any, 0, len(t))
		for _, s := range t {
			out = append(out, s)
		}
		return out
	}
	return []any{v}
}

// —— 对外 API ——

// GetString 取单个字符串
func (ar *AnalyzeRule) GetString(rule any, isUrl ...bool) string {
	isU := false
	if len(isUrl) > 0 {
		isU = isUrl[0]
	}
	list := ar.toRuleList(rule, false)
	return ar.getString(list, nil, isU)
}

// GetStringUnescape 取字符串（可关闭 HTML 反转义）
func (ar *AnalyzeRule) GetStringUnescape(rule any, unescape bool) string {
	list := ar.toRuleList(rule, false)
	return ar.getStringEx(list, nil, false, unescape)
}

func (ar *AnalyzeRule) getString(list []*SourceRule, mContent any, isUrl bool) string {
	return ar.getStringEx(list, mContent, isUrl, true)
}

func (ar *AnalyzeRule) getStringEx(list []*SourceRule, mContent any, isUrl, unescape bool) string {
	content := mContent
	if content == nil {
		content = ar.content
	}
	var result any
	if content != nil && len(list) > 0 {
		result = content
		if n, ok := result.(*NativeObject); ok {
			// 对齐 legado 的 NativeObject 分支：JS 对象走"键值直接访问"
			sr := list[0]
			for k, v := range sr.PutMap {
				ar.Put(k, ar.GetString(v))
			}
			sr.MakeUpRule(n)
			if sr.getParamSize() > 1 {
				result = sr.Rule
			} else if v, exist := n.Get(sr.Rule); exist {
				result = v
			} else {
				result = nil
			}
			if result != nil && sr.ReplaceRegex != "" {
				result = sr.ApplyReplace(jsToString(result))
			}
		} else {
			for _, sr := range list {
				for k, v := range sr.PutMap {
					ar.Put(k, ar.GetString(v))
				}
				sr.MakeUpRule(result)
				if result == nil {
					continue
				}
				r := sr.Rule
				if strings.TrimSpace(r) != "" || sr.ReplaceRegex == "" {
					result = ar.evalScalar(sr.Mode, r, result, isUrl)
				}
				if result != nil && sr.ReplaceRegex != "" {
					result = sr.ApplyReplace(fmt.Sprint(result))
				}
			}
		}
	}
	if result == nil {
		result = ""
	}
	str := ""
	switch t := result.(type) {
	case []any:
		if len(t) > 0 {
			str = jsToString(t[0])
		}
	case []string:
		if len(t) > 0 {
			str = t[0]
		}
	default:
		str = jsToString(result)
	}
	if unescape && strings.Contains(str, "&") {
		str = util.UnescapeHtml4(str)
	}
	if isUrl {
		if strings.TrimSpace(str) == "" {
			return ar.baseUrl
		}
		return util.GetAbsoluteURL(ar.redirectUrl, str)
	}
	return str
}

// GetStringList 取字符串列表
func (ar *AnalyzeRule) GetStringList(rule any, isUrl ...bool) []string {
	isU := false
	if len(isUrl) > 0 {
		isU = isUrl[0]
	}
	list := ar.toRuleList(rule, false)
	content := ar.content
	var result any
	if content != nil && len(list) > 0 {
		result = content
		if n, ok := result.(*NativeObject); ok {
			// 对齐 legado 的 NativeObject 分支
			sr := list[0]
			for k, v := range sr.PutMap {
				ar.Put(k, ar.GetString(v))
			}
			sr.MakeUpRule(n)
			if sr.getParamSize() > 1 {
				result = sr.Rule
			} else if v, exist := n.Get(sr.Rule); exist {
				result = v
			} else {
				result = nil
			}
			if result != nil && sr.ReplaceRegex != "" {
				switch t := result.(type) {
				case []any:
					out := make([]any, 0, len(t))
					for _, x := range t {
						out = append(out, sr.ApplyReplace(jsToString(x)))
					}
					result = out
				default:
					result = sr.ApplyReplace(jsToString(result))
				}
			}
		} else {
			for _, sr := range list {
				for k, v := range sr.PutMap {
					ar.Put(k, ar.GetString(v))
				}
				sr.MakeUpRule(result)
				if result == nil {
					continue
				}
				r := sr.Rule
				if r != "" || sr.ReplaceRegex == "" {
					result = ar.evalList(sr.Mode, r, result)
				}
				if result != nil && sr.ReplaceRegex != "" {
					switch t := result.(type) {
					case []string:
						out := make([]string, 0, len(t))
						for _, x := range t {
							out = append(out, sr.ApplyReplace(x))
						}
						result = out
					case []any:
						out := make([]any, 0, len(t))
						for _, x := range t {
							out = append(out, sr.ApplyReplace(fmt.Sprint(x)))
						}
						result = out
					default:
						result = sr.ApplyReplace(fmt.Sprint(result))
					}
				}
			}
		}
	}
	if result == nil {
		return nil
	}
	var arr []string
	switch t := result.(type) {
	case string:
		arr = strings.Split(t, "\n")
	case []string:
		arr = t
	case []any:
		arr = make([]string, 0, len(t))
		for _, x := range t {
			if x == nil {
				arr = append(arr, "")
			} else {
				arr = append(arr, jsToString(x))
			}
		}
	default:
		arr = []string{fmt.Sprint(result)}
	}
	if isU {
		out := []string{}
		for _, u := range arr {
			abs := util.GetAbsoluteURL(ar.redirectUrl, u)
			if abs != "" {
				dup := false
				for _, x := range out {
					if x == abs {
						dup = true
						break
					}
				}
				if !dup {
					out = append(out, abs)
				}
			}
		}
		return out
	}
	return arr
}

// GetElements 取元素列表
func (ar *AnalyzeRule) GetElements(ruleStr string) []any {
	if ruleStr == "" {
		return []any{}
	}
	list := ar.SplitSourceRule(ruleStr, true)
	content := ar.content
	if content == nil {
		return []any{}
	}
	var result any = content
	for _, sr := range list {
		for k, v := range sr.PutMap {
			ar.Put(k, ar.GetString(v))
		}
		sr.MakeUpRule(result)
		if result == nil {
			continue
		}
		result = ar.evalElements(sr.Mode, sr.Rule, result)
	}
	if result == nil {
		return []any{}
	}
	switch t := result.(type) {
	case []any:
		return t
	case []*html.Node:
		out := make([]any, 0, len(t))
		for _, n := range t {
			out = append(out, n)
		}
		return out
	case []string:
		out := make([]any, 0, len(t))
		for _, s := range t {
			out = append(out, s)
		}
		return out
	}
	return []any{result}
}

// GetElement 取单个元素
func (ar *AnalyzeRule) GetElement(ruleStr string) any {
	els := ar.GetElements(ruleStr)
	if len(els) == 0 {
		return nil
	}
	return els[0]
}

func (ar *AnalyzeRule) toRuleList(rule any, allInOne bool) []*SourceRule {
	switch t := rule.(type) {
	case nil:
		return nil
	case []*SourceRule:
		return t
	case *SourceRule:
		return []*SourceRule{t}
	case string:
		return ar.SplitSourceRule(t, allInOne)
	}
	return nil
}

// —— JS ——

func (ar *AnalyzeRule) evalJS(jsStr string, result any) any {
	b := &js.Bindings{
		Source:         ar.Source,
		Book:           ar.Book,
		Chapter:        ar.Chapter,
		Result:         ar.toJSResult(result),
		BaseUrl:        ar.baseUrl,
		Src:            unwrapNative(ar.content),
		NextChapterUrl: ar.nextChapterUrl,
		Vars:           ar,
	}
	if ar.Chapter != nil {
		b.Title = ar.Chapter.Title
	}
	v, err := js.DefaultEngine().Eval(jsStr, b)
	if err != nil {
		ar.log("JS 执行出错: " + err.Error())
		return nil
	}
	// JS 返回的对象需要标记为 NativeObject（对应 Rhino 的 NativeObject）
	return wrapNative(v)
}

// toJSResult 把中间结果转成 JS 友好形式
// EvalJS 以当前上下文执行 JS（供 preUpdateJs 等调用）
func (ar *AnalyzeRule) EvalJS(jsStr string) any {
	if ar.content == nil {
		ar.SetContent("")
	}
	return ar.evalJS(jsStr, ar.content)
}

func (ar *AnalyzeRule) toJSResult(result any) any {
	switch t := result.(type) {
	case nil:
		return nil
	case *html.Node:
		return js.NewElementWrap(t)
	case []*html.Node:
		return js.WrapNodes(t)
	case *NativeObject:
		return unwrapNative(t)
	case []any:
		out := make([]any, 0, len(t))
		for _, x := range t {
			switch y := x.(type) {
			case *html.Node:
				out = append(out, js.NewElementWrap(y))
			default:
				out = append(out, unwrapNative(x))
			}
		}
		return out
	}
	return result
}

func (ar *AnalyzeRule) log(msg string) {
	js.OnLog("[rule] " + msg)
}

// —— 辅助 ——

func isJSONString(s string) bool {
	t := strings.TrimSpace(s)
	if t == "" {
		return false
	}
	if !((strings.HasPrefix(t, "{") && strings.HasSuffix(t, "}")) ||
		(strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]"))) {
		return false
	}
	return json.Valid([]byte(t))
}

func (ar *AnalyzeRule) get(key string) string { return ar.Get(key) }
