package model

import (
	"encoding/json"
	"regexp"
	"strings"
	"sync"
)

// 书源类型（对齐 BookSourceType）
const (
	BookTypeText  = 0 // 文本
	BookTypeAudio = 1 // 音频
	BookTypeImage = 2 // 图片/漫画
	BookTypeFile  = 3 // 文件（下载站）
)

// SearchRule 搜索结果规则
type SearchRule struct {
	CheckKeyWord string `json:"checkKeyWord,omitempty"`
	BookList     string `json:"bookList,omitempty"`
	Name         string `json:"name,omitempty"`
	Author       string `json:"author,omitempty"`
	Intro        string `json:"intro,omitempty"`
	Kind         string `json:"kind,omitempty"`
	LastChapter  string `json:"lastChapter,omitempty"`
	UpdateTime   string `json:"updateTime,omitempty"`
	BookUrl      string `json:"bookUrl,omitempty"`
	CoverUrl     string `json:"coverUrl,omitempty"`
	WordCount    string `json:"wordCount,omitempty"`
}

// ExploreRule 发现结果规则
type ExploreRule struct {
	BookList    string `json:"bookList,omitempty"`
	Name        string `json:"name,omitempty"`
	Author      string `json:"author,omitempty"`
	Intro       string `json:"intro,omitempty"`
	Kind        string `json:"kind,omitempty"`
	LastChapter string `json:"lastChapter,omitempty"`
	UpdateTime  string `json:"updateTime,omitempty"`
	BookUrl     string `json:"bookUrl,omitempty"`
	CoverUrl    string `json:"coverUrl,omitempty"`
	WordCount   string `json:"wordCount,omitempty"`
}

// BookInfoRule 详情页规则
type BookInfoRule struct {
	Init         string `json:"init,omitempty"`
	Name         string `json:"name,omitempty"`
	Author       string `json:"author,omitempty"`
	Intro        string `json:"intro,omitempty"`
	Kind         string `json:"kind,omitempty"`
	LastChapter  string `json:"lastChapter,omitempty"`
	UpdateTime   string `json:"updateTime,omitempty"`
	CoverUrl     string `json:"coverUrl,omitempty"`
	TocUrl       string `json:"tocUrl,omitempty"`
	WordCount    string `json:"wordCount,omitempty"`
	CanReName    string `json:"canReName,omitempty"`
	DownloadUrls string `json:"downloadUrls,omitempty"`
}

// TocRule 目录规则
type TocRule struct {
	PreUpdateJs  string `json:"preUpdateJs,omitempty"`
	ChapterList  string `json:"chapterList,omitempty"`
	ChapterName  string `json:"chapterName,omitempty"`
	ChapterUrl   string `json:"chapterUrl,omitempty"`
	FormatJs     string `json:"formatJs,omitempty"`
	IsVolume     string `json:"isVolume,omitempty"`
	IsVip        string `json:"isVip,omitempty"`
	IsPay        string `json:"isPay,omitempty"`
	UpdateTime   string `json:"updateTime,omitempty"`
	NextTocUrl   string `json:"nextTocUrl,omitempty"`
	NextTocUrlJs string `json:"nextTocUrlJs,omitempty"`
}

// ContentRule 正文规则
type ContentRule struct {
	Content        string `json:"content,omitempty"`
	Title          string `json:"title,omitempty"`
	NextContentUrl string `json:"nextContentUrl,omitempty"`
	WebJs          string `json:"webJs,omitempty"`
	SourceRegex    string `json:"sourceRegex,omitempty"`
	ReplaceRegex   string `json:"replaceRegex,omitempty"`
	ImageStyle     string `json:"imageStyle,omitempty"`
	ImageDecode    string `json:"imageDecode,omitempty"`
	PayAction      string `json:"payAction,omitempty"`
}

// ExploreKind 发现分类
type ExploreKind struct {
	Title string `json:"title,omitempty"`
	Url   string `json:"url,omitempty"`
	Style any    `json:"style,omitempty"`
}

// BookSource 书源（对齐 data/entities/BookSource.kt）
type BookSource struct {
	BookSourceUrl     string        `json:"bookSourceUrl"`
	BookSourceName    string        `json:"bookSourceName"`
	BookSourceGroup   string        `json:"bookSourceGroup,omitempty"`
	BookSourceType    int           `json:"bookSourceType"`
	BookUrlPattern    string        `json:"bookUrlPattern,omitempty"`
	CustomOrder       int           `json:"customOrder"`
	Enabled           *bool         `json:"enabled,omitempty"`
	EnabledExplore    *bool         `json:"enabledExplore,omitempty"`
	JsLib             string        `json:"jsLib,omitempty"`
	EnabledCookieJar  *bool         `json:"enabledCookieJar,omitempty"`
	ConcurrentRate    string        `json:"concurrentRate,omitempty"`
	Header            string        `json:"header,omitempty"`
	LoginUrl          string        `json:"loginUrl,omitempty"`
	LoginUi           string        `json:"loginUi,omitempty"`
	LoginCheckJs      string        `json:"loginCheckJs,omitempty"`
	CoverDecodeJs     string        `json:"coverDecodeJs,omitempty"`
	BookSourceComment string        `json:"bookSourceComment,omitempty"`
	VariableComment   string        `json:"variableComment,omitempty"`
	LastUpdateTime    int64         `json:"lastUpdateTime,omitempty"`
	RespondTime       int64         `json:"respondTime,omitempty"`
	Weight            int           `json:"weight,omitempty"`
	SearchUrl         string        `json:"searchUrl,omitempty"`
	ExploreUrl        string        `json:"exploreUrl,omitempty"`
	ExploreScreen     string        `json:"exploreScreen,omitempty"`
	RuleExplore       *ExploreRule  `json:"ruleExplore,omitempty"`
	RuleSearch        *SearchRule   `json:"ruleSearch,omitempty"`
	RuleBookInfo      *BookInfoRule `json:"ruleBookInfo,omitempty"`
	RuleToc           *TocRule      `json:"ruleToc,omitempty"`
	RuleContent       *ContentRule  `json:"ruleContent,omitempty"`

	// FileName 书源所在文件名（含扩展名），由加载器填充，仅用于 -source 选源与报错提示，不参与序列化
	FileName string `json:"-"`
}

// 书源级变量（source.put/source.get），按书源 URL 隔离
var (
	sourceVarMu sync.RWMutex
	sourceVars  = map[string]map[string]string{}
)

// 兼容 rule 字段既可能是对象，也可能是"对象 JSON 字符串"
func unmarshalRule(v any, out any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case string:
		s := strings.TrimSpace(t)
		if s == "" || s == "null" {
			return false
		}
		return json.Unmarshal([]byte(s), out) == nil
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return false
		}
		return json.Unmarshal(b, out) == nil
	}
}

func (s *BookSource) UnmarshalJSON(data []byte) error {
	type plain BookSource
	var p plain
	if err := json.Unmarshal(data, &p); err != nil {
		return err
	}
	*s = BookSource(p)
	// 重新解析可能被压成字符串的规则对象
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err == nil {
		for _, k := range []string{"ruleExplore", "ruleSearch", "ruleBookInfo", "ruleToc", "ruleContent"} {
			v, ok := raw[k]
			if !ok {
				continue
			}
			switch k {
			case "ruleExplore":
				var r ExploreRule
				if unmarshalRule(v, &r) {
					s.RuleExplore = &r
				}
			case "ruleSearch":
				var r SearchRule
				if unmarshalRule(v, &r) {
					s.RuleSearch = &r
				}
			case "ruleBookInfo":
				var r BookInfoRule
				if unmarshalRule(v, &r) {
					s.RuleBookInfo = &r
				}
			case "ruleToc":
				var r TocRule
				if unmarshalRule(v, &r) {
					s.RuleToc = &r
				}
			case "ruleContent":
				var r ContentRule
				if unmarshalRule(v, &r) {
					s.RuleContent = &r
				}
			}
		}
	}
	return nil
}

// —— BaseSource 接口实现 ——

func (s *BookSource) GetKey() string { return s.BookSourceUrl }

func (s *BookSource) GetTag() string { return s.BookSourceName }

func (s *BookSource) GetBookType() int { return s.BookSourceType }

// EnabledCookieJarOn 是否启用 cookieJar 自动保存
func (s *BookSource) EnabledCookieJarOn() bool {
	if s.EnabledCookieJar == nil {
		return false
	}
	return *s.EnabledCookieJar
}

func (s *BookSource) IsEnabled() bool {
	if s.Enabled == nil {
		return true
	}
	return *s.Enabled
}

func (s *BookSource) IsEnabledExplore() bool {
	if s.EnabledExplore == nil {
		return true
	}
	return *s.EnabledExplore
}

// 书源级自定义变量（source.put / source.get，可在 JS 中调用）
func (s *BookSource) Put(key, value string) string {
	sourceVarMu.Lock()
	defer sourceVarMu.Unlock()
	m, ok := sourceVars[s.BookSourceUrl]
	if !ok {
		m = map[string]string{}
		sourceVars[s.BookSourceUrl] = m
	}
	m[key] = value
	return value
}

func (s *BookSource) Get(key string) string {
	sourceVarMu.RLock()
	defer sourceVarMu.RUnlock()
	return sourceVars[s.BookSourceUrl][key]
}

// Del 删除书源变量
func (s *BookSource) Del(key string) {
	sourceVarMu.Lock()
	delete(sourceVars[s.BookSourceUrl], key)
	sourceVarMu.Unlock()
}

// SetVariable / GetVariable 书源自定义变量（持久化用）
func (s *BookSource) SetVariable(v string) { s.Put("__variable__", v) }

func (s *BookSource) GetVariable() string { return s.Get("__variable__") }

// —— 规则访问器（永不返回 nil）——

func (s *BookSource) GetSearchRule() *SearchRule {
	if s.RuleSearch == nil {
		s.RuleSearch = &SearchRule{}
	}
	return s.RuleSearch
}

func (s *BookSource) GetExploreRule() *ExploreRule {
	if s.RuleExplore == nil {
		s.RuleExplore = &ExploreRule{}
	}
	return s.RuleExplore
}

func (s *BookSource) GetBookInfoRule() *BookInfoRule {
	if s.RuleBookInfo == nil {
		s.RuleBookInfo = &BookInfoRule{}
	}
	return s.RuleBookInfo
}

func (s *BookSource) GetTocRule() *TocRule {
	if s.RuleToc == nil {
		s.RuleToc = &TocRule{}
	}
	return s.RuleToc
}

func (s *BookSource) GetContentRule() *ContentRule {
	if s.RuleContent == nil {
		s.RuleContent = &ContentRule{}
	}
	return s.RuleContent
}

// DefaultUserAgent 默认 UA。书源 header 里没写 User-Agent 时用它；
// 可通过 legado.Config.UserAgent / CLI 的 -ua 覆盖。
var DefaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

// EvalJSHook 由 JS 层注册的求值钩子（避免 model 反向依赖 js 包）
var EvalJSHook func(src *BookSource, jsStr string) string

// GetHeaderMap 解析书源请求头（支持 JSON / @js: / <js></js>）
func (s *BookSource) GetHeaderMap(hasLoginHeader ...bool) map[string]string {
	m := map[string]string{}
	h := s.Header
	if h != "" {
		jsonStr := h
		low := strings.ToLower(h)
		switch {
		case strings.HasPrefix(low, "@js:"):
			if EvalJSHook != nil {
				jsonStr = EvalJSHook(s, h[4:])
			}
		case strings.HasPrefix(low, "<js>"):
			if idx := strings.LastIndex(h, "<"); idx > 4 && EvalJSHook != nil {
				jsonStr = EvalJSHook(s, h[4:idx])
			}
		}
		out := map[string]string{}
		if err := json.Unmarshal([]byte(jsonStr), &out); err == nil {
			for k, v := range out {
				m[k] = v
			}
		} else {
			// 宽松解析
			relaxed := regexp.MustCompile(`([{,]\s*)([A-Za-z_][\w]*)\s*:`).ReplaceAllString(jsonStr, `$1"$2":`)
			out2 := map[string]string{}
			if err2 := json.Unmarshal([]byte(relaxed), &out2); err2 == nil {
				for k, v := range out2 {
					m[k] = v
				}
			}
		}
	}
	hasUA := false
	for k := range m {
		if strings.EqualFold(k, "User-Agent") {
			hasUA = true
			break
		}
	}
	if !hasUA {
		m["User-Agent"] = DefaultUserAgent
	}
	if len(hasLoginHeader) > 0 && hasLoginHeader[0] {
		if lh := s.GetLoginHeaderMap(); lh != nil {
			for k, v := range lh {
				m[k] = v
			}
		}
	}
	return m
}

// GetLoginHeaderMap 登录后的请求头（由 putLoginHeader 写入）
func (s *BookSource) GetLoginHeaderMap() map[string]string {
	cache := s.Get("loginHeader_" + s.GetKey())
	if cache == "" {
		return nil
	}
	m := map[string]string{}
	if err := json.Unmarshal([]byte(cache), &m); err != nil {
		return nil
	}
	return m
}

// PutLoginHeader 保存登录请求头，并同步 cookie
func (s *BookSource) PutLoginHeader(header string) {
	m := map[string]string{}
	if err := json.Unmarshal([]byte(header), &m); err == nil {
		if c, ok := m["Cookie"]; ok {
			CookieStoreHook(s.GetKey(), c)
		} else if c, ok := m["cookie"]; ok {
			CookieStoreHook(s.GetKey(), c)
		}
	}
	s.Put("loginHeader_"+s.GetKey(), header)
}

// CookieStoreHook 由上层注册的 cookie 写入钩子
var CookieStoreHook = func(url, cookie string) {}

// RemoveLoginHeader 移除登录请求头
func (s *BookSource) RemoveLoginHeader() {
	s.Del("loginHeader_" + s.GetKey())
}

// GetCheckKeyword 取校验关键字
func (s *BookSource) GetCheckKeyword(def string) string {
	if s.RuleSearch != nil && strings.TrimSpace(s.RuleSearch.CheckKeyWord) != "" {
		return s.RuleSearch.CheckKeyWord
	}
	return def
}

// GetExploreKinds 解析发现分类列表。
// 兼容两种写法：
//  1. JSON 数组：[{"title":"分类","url":"/xx"}, ...]
//  2. 按行书写：分类名::/xx（或裸地址）
func (s *BookSource) GetExploreKinds() []ExploreKind {
	raw := strings.TrimSpace(s.ExploreUrl)
	if raw == "" {
		return nil
	}
	if strings.HasPrefix(raw, "[") || strings.HasPrefix(raw, "{") {
		var kinds []ExploreKind
		if err := json.Unmarshal([]byte(raw), &kinds); err == nil {
			out := make([]ExploreKind, 0, len(kinds))
			for _, k := range kinds {
				if strings.TrimSpace(k.Url) != "" {
					out = append(out, k)
				}
			}
			if len(out) > 0 {
				return out
			}
		}
		var one ExploreKind
		if err := json.Unmarshal([]byte(raw), &one); err == nil && strings.TrimSpace(one.Url) != "" {
			return []ExploreKind{one}
		}
	}
	out := []ExploreKind{}
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(strings.TrimRight(line, "\r"))
		if line == "" {
			continue
		}
		title, u := "", line
		if i := strings.LastIndex(line, "::"); i >= 0 {
			title = strings.TrimSpace(line[:i])
			u = strings.TrimSpace(line[i+2:])
		}
		if u != "" {
			out = append(out, ExploreKind{Title: title, Url: u})
		}
	}
	return out
}
