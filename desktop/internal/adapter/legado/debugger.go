// 本文件实现 port.SourceDebugger：把 legado-go 的调试打点接到桌面前端的事件流上。
//
// 之所以要写这一层而不是让 app 层直接调 webbook：调试链路里需要复刻
// Legado 客户端 Debug.startDebug 的分派与阶段推进（关键字 / URL / 分类::地址 /
// ++目录 / --正文），这套流程原本只存在于 legado-go 的 CLI（cmd/legado/debugcmd.go）。
// 放到 adapter 里，既能让桌面端和 CLI 共用同一份引擎语义，又不把第三方模型带进 app 层。
package legado

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/legado/legado-go/pkg/debug"
	"github.com/legado/legado-go/pkg/js"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/util"
	"github.com/legado/legado-go/pkg/webbook"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// debugSinkMutex 保证同一时刻只有一个调试会话。
//
// legado-go 的 debug 包用**进程级全局变量**保存 sink，两个会话同时跑会互相抢锁、
// 日志串台。加这把锁后，并发调试的后来者会直接排队——比串台的日志好排查得多。
var debugSinkMutex sync.Mutex

// Debugger 实现 port.SourceDebugger。
type Debugger struct {
	// UserAgent 与抓取器保持一致，避免调试结果与实际抓取不一致。
	UserAgent string

	// BodyLimit 是响应体打点的最大字节数，0 表示使用默认值。
	// 调试时看源码是定位规则问题最直接的手段，但正文页动辄几百 KB，
	// 全量推给前端会让事件通道和 UI 都卡住，所以默认截断。
	BodyLimit int
}

// NewDebugger 创建书源调试器。
func NewDebugger(userAgent string) *Debugger {
	return &Debugger{UserAgent: userAgent, BodyLimit: 4096}
}

var _ port.SourceDebugger = (*Debugger)(nil)

// 调试链路的执行深度，取值与 port.DebugStage* 一致。
type debugStage int

const (
	stageSearch debugStage = iota
	stageExplore
	stageInfo
	stageTOC
	stageContent
)

func parseDebugStage(s string) (debugStage, bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "all", "content":
		return stageContent, true
	case "search":
		return stageSearch, true
	case "explore":
		return stageExplore, true
	case "info", "detail":
		return stageInfo, true
	case "toc", "catalog", "directory":
		return stageTOC, true
	}
	return stageContent, false
}

// Debug 跑一遍书源调试链路。
func (d *Debugger) Debug(ctx context.Context, src *domain.BookSource, key string, stage string, sink port.DebugSink) (port.DebugResult, error) {
	if err := ctx.Err(); err != nil {
		return port.DebugResult{}, err
	}
	engineSrc, err := toEngineSource(src)
	if err != nil {
		return port.DebugResult{}, err
	}
	maxStage, ok := parseDebugStage(stage)
	if !ok {
		return port.DebugResult{}, fmt.Errorf("未知的调试阶段 %q", stage)
	}
	key = strings.TrimSpace(key)
	if key == "" {
		return port.DebugResult{}, fmt.Errorf("请填写调试入口：关键字、书籍地址，或 分类::地址")
	}

	debugSinkMutex.Lock()
	defer debugSinkMutex.Unlock()

	// 书源里的 java.log / console.log 直接进调试流（与客户端一致）。
	// js.OnLog 也是全局的，退出时必须还原，否则会影响正常抓取时的日志行为。
	prevOnLog := js.OnLog
	js.OnLog = func(msg string) { debug.Log(msg) }
	defer func() { js.OnLog = prevOnLog }()

	debug.SetSink(&eventSink{ctx: ctx, sink: sink, bodyLimit: d.bodyLimit()})
	defer debug.SetSink(nil)

	run := &dbgRun{src: engineSrc, max: maxStage, ctx: ctx}
	run.run(key)
	debug.Done("︽解析完成")

	return port.DebugResult{Failed: run.failed, Reason: run.reason}, nil
}

func (d *Debugger) bodyLimit() int {
	if d.BodyLimit > 0 {
		return d.BodyLimit
	}
	return 4096
}

// eventSink 把打点转给上层，并做两件事：响应体截断、取消后丢弃。
type eventSink struct {
	ctx       context.Context
	sink      port.DebugSink
	bodyLimit int
}

func (s *eventSink) Emit(e debug.Entry) {
	// 用户点了「停止」之后引擎还会把当前阶段跑完（引擎不接 ctx），
	// 这些后续打点没有意义，直接丢掉。
	if s.ctx.Err() != nil {
		return
	}
	msg := e.Msg
	if e.IsBody() {
		msg = truncateBody(msg, s.bodyLimit)
	}
	s.sink.Emit(port.DebugEntry{
		ElapsedMS: e.Elapsed.Milliseconds(),
		State:     e.State,
		Msg:       msg,
	})
}

func truncateBody(body string, limit int) string {
	if len(body) <= limit {
		return body
	}
	// 按合法 UTF-8 边界回退，避免把中文切成乱码（最多回退 3 字节）。
	cut := body[:limit]
	for len(cut) > 0 && !utf8.ValidString(cut) {
		cut = cut[:len(cut)-1]
	}
	return cut + fmt.Sprintf("\n…（响应体已截断，完整长度 %d 字节）", len(body))
}

// dbgRun 是一次调试过程的状态。
type dbgRun struct {
	src    *model.BookSource
	max    debugStage
	ctx    context.Context
	failed bool
	reason string
}

func (r *dbgRun) allow(s debugStage) bool { return r.max >= s }

func (r *dbgRun) canceled() bool { return r.ctx.Err() != nil }

// fail 记一条错误并把整次调试标记为失败（对应客户端的 state = -1）。
func (r *dbgRun) fail(stage string, err error) {
	r.failed = true
	r.reason = stage + "失败: " + err.Error()
	debug.Errorf("⇒%s失败: %v", stage, err)
}

func (r *dbgRun) newBook() *model.Book {
	book := model.NewBook()
	book.Origin = r.src.BookSourceUrl
	book.OriginName = r.src.BookSourceName
	book.SetSourceType(r.src.GetBookType())
	return book
}

// run 按入口形态分派，对齐 Kotlin 的 Debug.startDebug。
func (r *dbgRun) run(key string) {
	if r.canceled() {
		return
	}
	switch {
	case util.IsAbsUrl(key):
		book := r.newBook()
		book.BookUrl = key
		debug.Log("⇒开始访问详情页:" + key)
		r.infoDebug(book)

	case strings.Contains(key, "::"):
		prefix, rest, _ := strings.Cut(key, "::")
		url, err := r.exploreURL(prefix, rest)
		if err != nil {
			r.fail("发现页", err)
			return
		}
		debug.Log("⇒开始访问发现页:" + url)
		r.exploreDebug(url)

	case strings.HasPrefix(key, "++"):
		url := strings.TrimSpace(strings.TrimPrefix(key, "++"))
		book := r.newBook()
		book.TocUrl = url
		debug.Log("⇒开始访问目录页:" + url)
		r.tocDebug(book)

	case strings.HasPrefix(key, "--"):
		url := strings.TrimSpace(strings.TrimPrefix(key, "--"))
		book := r.newBook()
		chapter := model.NewBookChapter(book.BookUrl)
		chapter.Title = "调试"
		chapter.Url = url
		debug.Log("⇒开始访问正文页:" + url)
		r.contentDebug(book, chapter, "")

	default:
		debug.Log("⇒开始搜索关键字:" + key)
		r.searchDebug(key)
	}
}

// exploreURL 解析「分类::地址」：地址为空时按分类名查 exploreUrl，分类名为空时取第一个。
func (r *dbgRun) exploreURL(prefix, rest string) (string, error) {
	if u := strings.TrimSpace(rest); u != "" {
		return u, nil
	}
	kinds := webbook.GetExploreKinds(r.src)
	if len(kinds) == 0 {
		return "", fmt.Errorf("书源没有发现地址（exploreUrl），可直接填完整地址")
	}
	if name := strings.TrimSpace(prefix); name != "" {
		names := make([]string, 0, len(kinds))
		for _, k := range kinds {
			if u := strings.TrimSpace(k.Url); u != "" {
				if k.Title == name {
					return u, nil
				}
				names = append(names, k.Title)
			}
		}
		return "", fmt.Errorf("分类 %q 不存在，可选: %s", name, strings.Join(names, " / "))
	}
	for _, k := range kinds {
		if u := strings.TrimSpace(k.Url); u != "" {
			return u, nil
		}
	}
	return "", fmt.Errorf("发现地址里没有带地址的分类，只有分组标题")
}

func (r *dbgRun) searchDebug(keyword string) {
	debug.Log("︾开始解析搜索页")
	list, err := webbook.SearchBook(r.src, keyword, 1)
	if err != nil {
		r.fail("搜索页", err)
		return
	}
	if len(list) == 0 {
		r.failed = true
		r.reason = "搜索页未获取到书籍"
		debug.Errorf("︽未获取到书籍")
		return
	}
	debug.Log("︽搜索页解析完成")
	if !r.allow(stageInfo) || r.canceled() {
		return
	}
	r.infoDebug(list[0].ToBook())
}

func (r *dbgRun) exploreDebug(url string) {
	debug.Log("︾开始解析发现页")
	list, err := webbook.ExploreBook(r.src, url, 1)
	if err != nil {
		r.fail("发现页", err)
		return
	}
	if len(list) == 0 {
		r.failed = true
		r.reason = "发现页未获取到书籍"
		debug.Errorf("︽未获取到书籍")
		return
	}
	debug.Log("︽发现页解析完成")
	if !r.allow(stageInfo) || r.canceled() {
		return
	}
	r.infoDebug(list[0].ToBook())
}

func (r *dbgRun) infoDebug(book *model.Book) {
	if !r.allow(stageInfo) || r.canceled() {
		return
	}
	// 列表页已经把目录地址解析出来了（tocUrl 规则命中），就不必再请求详情页。
	if book.TocUrl != "" {
		debug.Log("≡已获取目录链接,跳过详情页")
		r.tocDebug(book)
		return
	}
	debug.Log("︾开始解析详情页")
	if err := webbook.GetBookInfo(r.src, book); err != nil {
		r.fail("详情页", err)
		return
	}
	debug.Log("︽详情页解析完成")
	if book.IsWebFile() {
		debug.Log("≡文件类书源跳过解析目录")
		return
	}
	r.tocDebug(book)
}

func (r *dbgRun) tocDebug(book *model.Book) {
	if !r.allow(stageTOC) || r.canceled() {
		return
	}
	debug.Log("︾开始解析目录页")
	chapters, err := webbook.GetChapterList(r.src, book, true)
	if err != nil {
		r.fail("目录页", err)
		return
	}
	debug.Log("︽目录页解析完成")

	// 卷名不算正文（对齐 Kotlin tocDebug 的过滤）。
	toc := make([]*model.BookChapter, 0, len(chapters))
	for _, c := range chapters {
		if c.IsVolume && strings.HasPrefix(c.Url, c.Title) {
			continue
		}
		toc = append(toc, c)
	}
	if len(toc) == 0 {
		r.failed = true
		r.reason = "目录页没有正文章节"
		debug.Errorf("≡没有正文章节")
		return
	}
	if !r.allow(stageContent) || r.canceled() {
		return
	}
	next := toc[0].Url
	if len(toc) > 1 {
		next = toc[1].Url
	}
	r.contentDebug(book, toc[0], next)
}

func (r *dbgRun) contentDebug(book *model.Book, chapter *model.BookChapter, nextChapterURL string) {
	if !r.allow(stageContent) || r.canceled() {
		return
	}
	debug.Log("︾开始解析正文页")
	content, err := webbook.GetContent(r.src, book, chapter, nextChapterURL)
	if err != nil {
		r.fail("正文页", err)
		return
	}
	if strings.TrimSpace(content) == "" {
		r.failed = true
		r.reason = "正文页解析结果为空"
		debug.Errorf("≡正文内容为空（共 %d 字）", len(content))
		return
	}
	debug.Log("︽正文页解析完成")
	debug.Logf("≡正文共 %d 字，开头：%s", len([]rune(content)), headRunes(content, 80))
}

func headRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
