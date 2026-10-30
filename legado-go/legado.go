// Package legado 是 Legado(阅读) 书源/漫画源规则引擎的 Go 实现。
//
// 能力：
//   - 完整解析书源规则语法（JSoup/CSS、XPath、JSONPath、正则、JS、@put/@get/{{}}/$N/##）
//   - 自动管理 Cookie（按二级域名持久化 + 会话 cookie + 请求时自动注入）
//   - 向书源 JS 注入 java/source/book/chapter/result/cache/cookie 等对象与变量
//   - 指定书源文件夹加载 + 书源语法校验（离线/在线）
//   - 按书源下载书籍或漫画
package legado

import (
	"fmt"
	"time"

	"github.com/legado/legado-go/pkg/config"
	"github.com/legado/legado-go/pkg/download"
	"github.com/legado/legado-go/pkg/js"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/net"
	"github.com/legado/legado-go/pkg/source"
	"github.com/legado/legado-go/pkg/store"
	"github.com/legado/legado-go/pkg/webbook"
)

// Engine 书源引擎：持有一批书源与全局运行时配置
type Engine struct {
	Sources    []*model.BookSource
	LoadErrors []error
	CookieFile string
	CacheFile  string
}

// Config 引擎配置
type Config struct {
	SourceDir   string // 书源文件夹
	SourceFile  string // 单个书源文件
	CookieFile  string // Cookie 持久化文件
	CacheFile   string // 缓存持久化文件
	UserAgent   string
	JSTimeout   time.Duration
	HTTPTimeout time.Duration
	Log         func(msg string)
}

// FromFileConfig 把 config.json 的内容转成运行时配置。
// 传 nil 的 log 表示不输出调试日志。
func FromFileConfig(c *config.FileConfig, log func(msg string)) Config {
	if c == nil {
		return Config{Log: log}
	}
	return Config{
		SourceDir:   c.SourceDir,
		SourceFile:  c.SourceFile,
		CookieFile:  c.CookieFile,
		CacheFile:   c.CacheFile,
		UserAgent:   c.UserAgent,
		JSTimeout:   time.Duration(c.JSTimeout) * time.Second,
		HTTPTimeout: time.Duration(c.HTTPTimeout) * time.Second,
		Log:         log,
	}
}

// New 创建引擎并加载书源
func New(cfg Config) (*Engine, error) {
	e := &Engine{CookieFile: cfg.CookieFile, CacheFile: cfg.CacheFile}
	if cfg.CookieFile != "" {
		store.Default().SetCookieFile(cfg.CookieFile)
	}
	if cfg.CacheFile != "" {
		store.DefaultCache().SetFile(cfg.CacheFile)
	}
	if cfg.UserAgent != "" {
		// 两处都改：net 用于没有书源 header 的请求，model 用于给书源 header 补默认 UA
		net.Default().UserAgent = cfg.UserAgent
		model.DefaultUserAgent = cfg.UserAgent
	}
	if cfg.HTTPTimeout > 0 {
		net.Default().Timeout = cfg.HTTPTimeout
		net.Default().HTTPClient.Timeout = cfg.HTTPTimeout
	}
	if cfg.JSTimeout > 0 {
		js.DefaultEngine().SetTimeout(cfg.JSTimeout)
	}
	if cfg.Log != nil {
		js.OnLog = cfg.Log
	}
	switch {
	case cfg.SourceFile != "":
		list, err := source.LoadFile(cfg.SourceFile)
		if err != nil {
			return nil, err
		}
		e.Sources = list
	case cfg.SourceDir != "":
		list, errs := source.LoadDir(cfg.SourceDir)
		e.Sources = list
		e.LoadErrors = errs
	default:
		return nil, fmt.Errorf("必须指定书源文件夹(SourceDir)或书源文件(SourceFile)")
	}
	if len(e.Sources) == 0 && len(e.LoadErrors) > 0 {
		return e, e.LoadErrors[0]
	}
	return e, nil
}

// notFoundErr 生成带候选列表与写法提示的错误
func notFoundErr(list []*model.BookSource, key string) error {
	return fmt.Errorf("未找到书源: %q\n%s", key, source.HintNotFound(list))
}

// Find 按 URL / 名称 / 文件名 / 域名 / 序号查找书源
func (e *Engine) Find(key string) *model.BookSource {
	return source.Find(e.Sources, key)
}

// ValidateAll 校验全部书源语法
func (e *Engine) ValidateAll() []*source.Result {
	out := make([]*source.Result, 0, len(e.Sources))
	for _, s := range e.Sources {
		out = append(out, source.Validate(s))
	}
	return out
}

// ValidateOnline 在线校验指定书源
func (e *Engine) ValidateOnline(key, keyword string, items source.CheckItems) (*source.Result, error) {
	s := e.Find(key)
	if s == nil {
		return nil, notFoundErr(e.Sources, key)
	}
	return source.ValidateOnline(s, keyword, items), nil
}

// Search 搜索
func (e *Engine) Search(key, keyword string, page int) ([]*model.SearchBook, error) {
	s := e.Find(key)
	if s == nil {
		return nil, notFoundErr(e.Sources, key)
	}
	return webbook.SearchBook(s, keyword, page)
}

// Explore 发现
func (e *Engine) Explore(key, url string, page int) ([]*model.SearchBook, error) {
	s := e.Find(key)
	if s == nil {
		return nil, notFoundErr(e.Sources, key)
	}
	return webbook.ExploreBook(s, url, page)
}

// GetBookInfo 书籍详情
func (e *Engine) GetBookInfo(key string, book *model.Book) error {
	s := e.Find(key)
	if s == nil {
		return notFoundErr(e.Sources, key)
	}
	return webbook.GetBookInfo(s, book)
}

// GetChapterList 目录
func (e *Engine) GetChapterList(key string, book *model.Book) ([]*model.BookChapter, error) {
	s := e.Find(key)
	if s == nil {
		return nil, notFoundErr(e.Sources, key)
	}
	return webbook.GetChapterList(s, book, false)
}

// GetContent 正文。
// nextChapterUrl 用于「下一页 == 下一章」的刹车判定：规则误选中下一章链接时，
// 不传它就会把下一章正文拼到本章末尾。省略该参数等价于传空。
func (e *Engine) GetContent(key string, book *model.Book, chapter *model.BookChapter, nextChapterUrl ...string) (string, error) {
	s := e.Find(key)
	if s == nil {
		return "", notFoundErr(e.Sources, key)
	}
	next := ""
	if len(nextChapterUrl) > 0 {
		next = nextChapterUrl[0]
	}
	return webbook.GetContent(s, book, chapter, next)
}

// Download 下载整本书（书籍或漫画）
func (e *Engine) Download(key string, book *model.Book, opt download.Options) (*download.Result, error) {
	s := e.Find(key)
	if s == nil {
		return nil, notFoundErr(e.Sources, key)
	}
	return download.DownloadBook(s, book, opt)
}

// SaveCookies 落盘 cookie
func (e *Engine) SaveCookies() error {
	return store.Default().Save()
}
