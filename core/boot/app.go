// Package boot 装配业务层依赖，是**与宿主无关的组合根**。
//
// 三个宿主（CLI / FFI / Wails 壳）都通过它构建同一套依赖图，
// 从而保证「命令行里验证过的行为」与「应用里实际运行的行为」完全一致。
//
// 本包只组装，不含业务规则，也不依赖任何 UI 框架 ——
// 平台相关的适配（Wails 验证窗口、日志事件）由宿主通过 Options 注入。
package boot

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/legado/core/adapters/aihttp"
	"github.com/legado/core/adapters/bookparser"
	"github.com/legado/core/adapters/dictbuild"
	"github.com/legado/core/adapters/dictsqlite"
	"github.com/legado/core/adapters/exporter"
	"github.com/legado/core/adapters/filesystem"
	"github.com/legado/core/adapters/imagefetch"
	"github.com/legado/core/adapters/legado"
	"github.com/legado/core/adapters/persistence/sqlite"
	legadowebdav "github.com/legado/core/adapters/webdav"
	"github.com/legado/core/app"
	"github.com/legado/core/domain"
	"github.com/legado/core/kernel"
	"github.com/legado/core/port"
	"github.com/legado/legado-go/pkg/store"
)

// Options 是宿主可注入的差异点。零值即可用于 CLI / 测试。
type Options struct {
	// Events 是业务事件总线。为空时用丢弃实现。
	Events port.EventBus
	// InstallVerifier 注册人机验证求解器（Wails 弹窗 / Android 覆盖层）。
	// 为空表示当前宿主无法求解挑战 —— 引擎遇到拦截会原样返回，由调用方提示用户。
	InstallVerifier func(port.EventBus)
	// Trace 是结构化调试总线。为空时新建一个。
	Trace *kernel.TraceBus
	// UserAgent 覆盖默认 UA（Android 常需移动端 UA）。
	UserAgent string
}

// App 是装配产物：一组可直接使用的应用服务与共享基础设施。
type App struct {
	Root string
	DB   *sqlite.DB
	// Blobs 管理封面等二进制资源。
	Blobs port.BlobStore
	// Parsers 是按格式分发的本地书解析器注册表。
	Parsers *bookparser.Registry
	// Settings 是应用级键值配置（WebDAV、阅读偏好等）。
	// 各功能服务已经在用同一个实例，这里再暴露一份给 settings 模块注册。
	Settings port.SettingsStore

	Bookshelf   *app.BookshelfService
	Reader      *app.ReaderService
	Source      *app.SourceService
	Library     *app.LibraryService
	WebDAV      *app.WebDAVService
	Cache       *app.CacheService
	ReplaceRule *app.ReplaceRuleService
	SourceDebug *app.SourceDebugService
	SourceLogin *app.SourceLoginService
	Content     *app.ContentProvider
	AI          *app.AIService
	Dict        *app.DictService
	Audio       *app.AudioService

	// Trace 供平台模块与调试宿主使用。
	Trace *kernel.TraceBus
	// Events 是宿主注入的事件总线。
	Events port.EventBus
}

// New 在 root 下装配全部业务依赖。
func New(root string, opt Options) (*App, error) {
	installErrorMapper()
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, fmt.Errorf("创建数据目录失败: %w", err)
	}
	events := opt.Events
	if events == nil {
		events = nopBus{}
	}
	trace := opt.Trace
	if trace == nil {
		trace = kernel.NewTraceBus(512)
	}
	ua := opt.UserAgent
	if ua == "" {
		ua = DefaultUserAgent()
	}

	dbPath := filepath.Join(root, "legado.db")
	db, err := sqlite.Open(dbPath)
	if err != nil {
		return nil, err
	}

	blobs, err := filesystem.NewBlobStore(root)
	if err != nil {
		db.Close() //nolint:errcheck
		return nil, err
	}

	// ── 仓储（端口实现） ────────────────────────────────────
	books := sqlite.NewBookRepo(db)
	groups := sqlite.NewBookGroupRepo(db)
	chapters := sqlite.NewChapterRepo(db)
	progress := sqlite.NewProgressRepo(db)
	sources := sqlite.NewBookSourceRepo(db)
	subs := sqlite.NewSubscriptionRepo(db)
	sourceVars := sqlite.NewSourceVariableRepo(db)
	rules := sqlite.NewReplaceRuleRepo(db)
	settings := sqlite.NewSettingsStore(db)
	chapterCache := sqlite.NewChapterCacheRepo(db)

	// ── 本地书解析与导出 ────────────────────────────────────
	parsers := bookparser.NewRegistry()
	parsers.Register(bookparser.NewTXTParser())
	parsers.Register(bookparser.NewEPUBParser())
	parsers.Register(bookparser.NewComicParser(filepath.Join(root, "cache", "comic"), "/local/cache/comic"))
	parsers.Register(bookparser.NewPDFParser())

	txtExporter := exporter.NewTXTExporter()
	epubExporter := exporter.NewEPUBExporter()

	// ── 书源引擎 ────────────────────────────────────────────
	//
	// Cookie 必须落盘：登录态就存在引擎的 CookieStore 里，不指定文件的话
	// 每次重启应用都要重新登录一遍（书源的 Set-Cookie 也会随之丢失）。
	store.Default().SetCookieFile(filepath.Join(root, "cookies.json"))
	fetcher := legado.NewFetcher(ua)

	// 站点人机验证（Cloudflare 托管挑战）的求解器由宿主注入：
	// 桌面弹 WebView 窗口，Android 叠覆盖层，CLI/headless 不注入（无解，属预期）。
	if opt.InstallVerifier != nil {
		opt.InstallVerifier(events)
	}

	// ── 应用服务 ────────────────────────────────────────────
	content := app.NewContentProvider(books, chapters, sources, parsers, fetcher, chapterCache)

	cache := app.NewCacheService(app.CacheDeps{
		Root:     root,
		Books:    books,
		Chapters: chapters,
		Cache:    chapterCache,
		Content:  content,
		Images:   imagefetch.New(ua),
		Events:   events,
	})

	bookshelf := app.NewBookshelfService(books, groups, progress, db).WithCache(cache)
	reader := app.NewReaderService(content, chapters, books, bookshelf, db)
	source := app.NewSourceService(app.SourceDeps{
		Sources:  sources,
		Subs:     subs,
		Books:    books,
		Chapters: chapters,
		Fetcher:  fetcher,
		Events:   events,
		Vars:     sourceVars,
		UoW:      db,
		Session:  fetcher,
	})
	library := app.NewLibraryService(app.LibraryDeps{
		Books:    books,
		Chapters: chapters,
		Parsers:  parsers,
		Exporters: map[domain.BookFormat]port.BookExporter{
			txtExporter.Format():  txtExporter,
			epubExporter.Format(): epubExporter,
		},
		Blobs:    blobs,
		Events:   events,
		Settings: settings,
		Content:  content,
		UoW:      db,
	})
	webdav := app.NewWebDAVService(settings, legadowebdav.NewFactory(), events, dbPath).
		WithBookImport(root, library)
	sourceLogin := app.NewSourceLoginService(app.SourceLoginDeps{
		Sources: sources,
		Logins:  sqlite.NewSourceLoginRepo(db),
		Engine:  legado.NewLoginer(ua),
	})
	sourceDebug := app.NewSourceDebugService(app.SourceDebugDeps{
		Sources:  source,
		Debugger: legado.NewDebugger(ua),
		Events:   events,
	})
	ai := app.NewAIService(app.AIDeps{
		Settings:  settings,
		LLM:       aihttp.New(aihttp.Options{UserAgent: ua}),
		Bus:       events,
		Content:   content,
		Cache:     chapterCache,
		Chunks:    sqlite.NewAIChunkRepo(db),
		Summaries: sqlite.NewAISummaryRepo(db),
		States:    sqlite.NewAIIndexStateRepo(db),
		Chats:     sqlite.NewAIChatRepo(db),
	})

	// 词典：核心词库随二进制内嵌，首次查词时解压到 <root>/dict/。
	dict := app.NewDictService(app.DictDeps{
		Root:     root,
		Settings: settings,
		Events:   events,
		OpenRepo: func(path string) (port.DictionaryRepository, error) {
			return dictsqlite.OpenReadOnly(path)
		},
		Build: func(ctx context.Context, kind, srcPath, outPath, tier string, progress func(done, total int64)) (int, error) {
			switch kind {
			case "ecdict":
				return dictbuild.ECDICT(ctx, srcPath, outPath, tier, progress)
			case "cedict":
				return dictbuild.CEDICT(ctx, srcPath, outPath, progress)
			default:
				return 0, fmt.Errorf("未知的词库类型 %q", kind)
			}
		},
	})

	audio := app.NewAudioService(app.AudioDeps{
		Root:     root,
		Books:    books,
		Chapters: chapters,
		Sources:  sources,
		Vars:     sourceVars,
		Resolver: fetcher,
		Events:   events,
	})

	return &App{
		Root:        root,
		DB:          db,
		Blobs:       blobs,
		Parsers:     parsers,
		Settings:    settings,
		Bookshelf:   bookshelf,
		Reader:      reader,
		Source:      source,
		Library:     library,
		WebDAV:      webdav,
		Cache:       cache,
		ReplaceRule: app.NewReplaceRuleService(rules),
		Content:     content,
		SourceDebug: sourceDebug,
		SourceLogin: sourceLogin,
		AI:          ai,
		Dict:        dict,
		Audio:       audio,
		Trace:       trace,
		Events:      events,
	}, nil
}

// Close 释放装配持有的资源（后台任务与数据库句柄）。
func (a *App) Close() error {
	if a == nil {
		return nil
	}
	if a.Cache != nil {
		a.Cache.StopAll()
	}
	if a.Audio != nil {
		a.Audio.StopAll()
	}
	if a.WebDAV != nil {
		a.WebDAV.StopImport()
	}
	if a.Dict != nil {
		a.Dict.Close() //nolint:errcheck
	}
	if a.DB == nil {
		return nil
	}
	return a.DB.Close()
}

// DefaultUserAgent 返回默认 User-Agent，可通过 LEGADO_UA 覆盖。
func DefaultUserAgent() string {
	if v := os.Getenv("LEGADO_UA"); v != "" {
		return v
	}
	if v := os.Getenv("LEGADO_DESKTOP_UA"); v != "" {
		return v
	}
	return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
}

// nopBus 是事件总线的空实现（CLI 与测试默认使用）。
type nopBus struct{}

func (nopBus) Emit(context.Context, string, any) error { return nil }

// errorMapperOnce 保证映射器只注册一次。
//
// boot.New 在测试里会被调用很多次；不加 once 就会往内核的映射器切片里
// 反复追加同一份逻辑，虽然结果一样但白占内存、也让「注册了几个」不可信。
var errorMapperOnce sync.Once

// installErrorMapper 把 domain 错误哨兵翻译成控制面错误码。
//
// 放在组合根而不是 kernel：kernel 不认识 domain（依赖方向会倒过来），
// 而 boot 本来就同时知道两者。不装这个映射器的话，128 个反射注册的老方法
// 返回的 `domain.ErrNotFound` 会全被折叠成 INTERNAL，
// Dart 侧就没法靠 code 分支（例如「书已被删」要退回书架而不是弹重试）。
func installErrorMapper() {
	errorMapperOnce.Do(func() {
		kernel.RegisterErrorMapper(func(err error) (*kernel.Error, bool) {
			switch {
			case errors.Is(err, domain.ErrNotFound):
				return kernel.E(kernel.CodeNotFound, err.Error()), true
			case errors.Is(err, domain.ErrInvalidArgument),
				errors.Is(err, domain.ErrUnsupportedFormat),
				errors.Is(err, domain.ErrParseFailed):
				return kernel.E(kernel.CodeInvalid, err.Error()), true
			case errors.Is(err, domain.ErrAlreadyExists):
				// 没有专门的「冲突」码，按参数非法处理：调用方要的是「别再试一次」。
				return kernel.E(kernel.CodeInvalid, err.Error()), true
			case errors.Is(err, domain.ErrNotConfigured):
				return kernel.E(kernel.CodeUnsupported, err.Error()), true
			case errors.Is(err, domain.ErrRemoteFailed):
				return kernel.E(kernel.CodeNetTimeout, err.Error()), true
			}
			return nil, false
		})
	})
}
