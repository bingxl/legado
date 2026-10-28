package model

import (
	"encoding/json"
	"maps"
	"strings"
	"sync"

	"github.com/legado/legado-go/pkg/util"
)

// VariableHolder 变量容器（对齐 RuleDataInterface）
type VariableHolder struct {
	mu   sync.RWMutex
	vars map[string]string
	// 大变量（>=10000 字符）单独存放，避免污染 JSON 变量串
	big map[string]string
}

func NewVariableHolder() *VariableHolder {
	return &VariableHolder{vars: map[string]string{}, big: map[string]string{}}
}

func (v *VariableHolder) ensure() {
	if v.vars == nil {
		v.vars = map[string]string{}
	}
	if v.big == nil {
		v.big = map[string]string{}
	}
}

// PutVariable 保存变量，超过 10000 字符转为"大变量"
func (v *VariableHolder) PutVariable(key, value string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.ensure()
	delete(v.big, key)
	if len(value) >= 10000 {
		delete(v.vars, key)
		v.big[key] = value
		return
	}
	v.vars[key] = value
}

func (v *VariableHolder) GetVariable(key string) string {
	v.mu.RLock()
	defer v.mu.RUnlock()
	v.ensure()
	if s, ok := v.vars[key]; ok {
		return s
	}
	return v.big[key]
}

func (v *VariableHolder) DelVariable(key string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.ensure()
	delete(v.vars, key)
	delete(v.big, key)
}

// ToJSON 序列化为 JSON 字符串（不含大变量）
func (v *VariableHolder) ToJSON() string {
	v.mu.RLock()
	defer v.mu.RUnlock()
	if len(v.vars) == 0 {
		return ""
	}
	b, _ := json.Marshal(v.vars)
	return string(b)
}

func (v *VariableHolder) LoadJSON(s string) {
	if strings.TrimSpace(s) == "" {
		return
	}
	m := map[string]string{}
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		return
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	v.ensure()
	maps.Copy(v.vars, m)
}

// Book 书籍（对齐 data/entities/Book.kt 的常用字段）
type Book struct {
	*VariableHolder `json:"-"`

	Name               string   `json:"name"`
	Author             string   `json:"author"`
	BookUrl            string   `json:"bookUrl"`
	TocUrl             string   `json:"tocUrl,omitempty"`
	Origin             string   `json:"origin,omitempty"`
	OriginName         string   `json:"originName,omitempty"`
	OriginOrder        int      `json:"originOrder,omitempty"`
	Type               int      `json:"type,omitempty"`
	Kind               string   `json:"kind,omitempty"`
	WordCount          string   `json:"wordCount,omitempty"`
	Intro              string   `json:"intro,omitempty"`
	CoverUrl           string   `json:"coverUrl,omitempty"`
	LatestChapterTitle string   `json:"latestChapterTitle,omitempty"`
	TotalChapterNum    int      `json:"totalChapterNum,omitempty"`
	DurChapterIndex    int      `json:"durChapterIndex,omitempty"`
	DurChapterTitle    string   `json:"durChapterTitle,omitempty"`
	Variable           string   `json:"variable,omitempty"`
	InfoHtml           string   `json:"-"`
	TocHtml            string   `json:"-"`
	DownloadUrls       []string `json:"downloadUrls,omitempty"`
	ReverseToc         bool     `json:"-"`
}

func NewBook() *Book {
	return &Book{VariableHolder: NewVariableHolder()}
}

func (b *Book) GetReverseToc() bool { return b.ReverseToc }

// IsWebFile 是否为文件型书籍（下载站）
func (b *Book) IsWebFile() bool { return b.Type == BookTypeFile }

// BaseList 供列表规则统一访问
type BookListRule interface {
	GetBookList() string
	GetName() string
	GetAuthor() string
	GetIntro() string
	GetKind() string
	GetLastChapter() string
	GetBookUrl() string
	GetCoverUrl() string
	GetWordCount() string
}

func (r *SearchRule) GetBookList() string    { return r.BookList }
func (r *SearchRule) GetName() string        { return r.Name }
func (r *SearchRule) GetAuthor() string      { return r.Author }
func (r *SearchRule) GetIntro() string       { return r.Intro }
func (r *SearchRule) GetKind() string        { return r.Kind }
func (r *SearchRule) GetLastChapter() string { return r.LastChapter }
func (r *SearchRule) GetBookUrl() string     { return r.BookUrl }
func (r *SearchRule) GetCoverUrl() string    { return r.CoverUrl }
func (r *SearchRule) GetWordCount() string   { return r.WordCount }

func (r *ExploreRule) GetBookList() string    { return r.BookList }
func (r *ExploreRule) GetName() string        { return r.Name }
func (r *ExploreRule) GetAuthor() string      { return r.Author }
func (r *ExploreRule) GetIntro() string       { return r.Intro }
func (r *ExploreRule) GetKind() string        { return r.Kind }
func (r *ExploreRule) GetLastChapter() string { return r.LastChapter }
func (r *ExploreRule) GetBookUrl() string     { return r.BookUrl }
func (r *ExploreRule) GetCoverUrl() string    { return r.CoverUrl }
func (r *ExploreRule) GetWordCount() string   { return r.WordCount }

// SearchBook 搜索结果
type SearchBook struct {
	*VariableHolder `json:"-"`

	Name               string `json:"name"`
	Author             string `json:"author"`
	BookUrl            string `json:"bookUrl"`
	Origin             string `json:"origin,omitempty"`
	OriginName         string `json:"originName,omitempty"`
	OriginOrder        int    `json:"originOrder,omitempty"`
	Type               int    `json:"type,omitempty"`
	Kind               string `json:"kind,omitempty"`
	WordCount          string `json:"wordCount,omitempty"`
	Intro              string `json:"intro,omitempty"`
	CoverUrl           string `json:"coverUrl,omitempty"`
	LatestChapterTitle string `json:"latestChapterTitle,omitempty"`
	Variable           string `json:"variable,omitempty"`
	InfoHtml           string `json:"-"`
}

func NewSearchBook() *SearchBook {
	return &SearchBook{VariableHolder: NewVariableHolder()}
}

// ToBook 搜索结果转书籍
func (s *SearchBook) ToBook() *Book {
	b := NewBook()
	b.Name = s.Name
	b.Author = s.Author
	b.BookUrl = s.BookUrl
	b.Origin = s.Origin
	b.OriginName = s.OriginName
	b.OriginOrder = s.OriginOrder
	b.Type = s.Type
	b.Kind = s.Kind
	b.WordCount = s.WordCount
	b.Intro = s.Intro
	b.CoverUrl = s.CoverUrl
	b.LatestChapterTitle = s.LatestChapterTitle
	b.InfoHtml = s.InfoHtml
	b.Variable = s.Variable
	if s.Variable != "" {
		b.LoadJSON(s.Variable)
	}
	return b
}

// BookChapter 章节
type BookChapter struct {
	*VariableHolder `json:"-"`

	BookUrl     string `json:"bookUrl"`
	Index       int    `json:"index"`
	Title       string `json:"title"`
	Url         string `json:"url"`
	BaseUrl     string `json:"baseUrl,omitempty"`
	Tag         string `json:"tag,omitempty"`
	IsVolume    bool   `json:"isVolume"`
	IsVip       bool   `json:"isVip"`
	IsPay       bool   `json:"isPay"`
	WordCount   int    `json:"wordCount,omitempty"`
	ResourceUrl string `json:"resourceUrl,omitempty"`
}

func NewBookChapter(bookUrl string) *BookChapter {
	return &BookChapter{BookUrl: bookUrl, VariableHolder: NewVariableHolder()}
}

// GetAbsoluteURL 章节绝对地址
func (c *BookChapter) GetAbsoluteURL() string {
	if c.BaseUrl == "" {
		return c.Url
	}
	return util.GetAbsoluteURL(c.BaseUrl, c.Url)
}

// RuleData 无书籍上下文时的临时变量容器
type RuleData struct {
	*VariableHolder
}

func NewRuleData() *RuleData { return &RuleData{NewVariableHolder()} }
