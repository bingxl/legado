// Package bootstrap 装配业务层依赖，是**与宿主无关的组合根**。
//
// main.go（Wails 图形界面）与 cmd/ 下的命令行工具都通过它构建同一套依赖图，
// 从而保证"工具里验证过的行为"与"应用里实际运行的行为"完全一致，
// 也避免装配逻辑在多处重复后各自漂移。
//
// 本包只组装，不含业务规则，也不依赖任何 UI 框架。
package bootstrap

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/legado/desktop/internal/adapter/bookparser"
	"github.com/legado/desktop/internal/adapter/exporter"
	"github.com/legado/desktop/internal/adapter/filesystem"
	"github.com/legado/desktop/internal/adapter/imagefetch"
	"github.com/legado/desktop/internal/adapter/legado"
	"github.com/legado/desktop/internal/adapter/persistence/sqlite"
	legadowebdav "github.com/legado/desktop/internal/adapter/webdav"
	"github.com/legado/desktop/internal/app"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// App 是装配产物：一组可直接使用的应用服务与共享基础设施。
type App struct {
	// Root 是数据根目录，存放数据库、封面与缓存。
	Root string
	// DB 是数据库句柄，同时充当工作单元（port.UnitOfWork）。
	DB *sqlite.DB
	// Blobs 管理封面等二进制资源。
	Blobs port.BlobStore
	// Parsers 是按格式分发的本地书解析器注册表。
	Parsers *bookparser.Registry

	Bookshelf *app.BookshelfService
	Reader    *app.ReaderService
	Source    *app.SourceService
	Library   *app.LibraryService
	WebDAV    *app.WebDAVService
	// Cache 负责章节的手动缓存与缓存管理。
	Cache *app.CacheService
	// SourceDebug 负责书源调试（真跑规则，把每一步打点推给前端）。
	SourceDebug *app.SourceDebugService
	// Content 供给章节正文（本地解析或走书源抓取）。
	// 需要按章节粒度取内容的场景（例如只导出前若干章）直接使用它。
	Content *app.ContentProvider
}

// New 在 root 下装配全部业务依赖。
//
// events 由宿主提供：图形界面用 Wails 实现，命令行工具用日志实现。
// 目录不存在时会自动创建。
func New(root string, events port.EventBus) (*App, error) {
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, fmt.Errorf("创建数据目录失败: %w", err)
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
	fetcher := legado.NewFetcher(DefaultUserAgent())

	// ── 应用服务 ────────────────────────────────────────────
	content := app.NewContentProvider(books, chapters, sources, parsers, fetcher, chapterCache)

	// 缓存服务要先于书架服务构造：删书时要连带清掉该书的缓存文件。
	cache := app.NewCacheService(app.CacheDeps{
		Root:     root,
		Books:    books,
		Chapters: chapters,
		Cache:    chapterCache,
		Content:  content,
		Images:   imagefetch.New(DefaultUserAgent()),
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
	// WebDAV：备份上传下载 + 「从 WebDAV 选书导入」。
	// 导入能力用链式注入，因为下载落点与导入器只有在 library 构造之后才就绪。
	webdav := app.NewWebDAVService(settings, legadowebdav.NewFactory(), events, dbPath).
		WithBookImport(root, library)
	sourceDebug := app.NewSourceDebugService(app.SourceDebugDeps{
		Sources:  source,
		Debugger: legado.NewDebugger(DefaultUserAgent()),
		Events:   events,
	})

	return &App{
		Root:        root,
		DB:          db,
		Blobs:       blobs,
		Parsers:     parsers,
		Bookshelf:   bookshelf,
		Reader:      reader,
		Source:      source,
		Library:     library,
		WebDAV:      webdav,
		Cache:       cache,
		Content:     content,
		SourceDebug: sourceDebug,
	}, nil
}

// Close 释放装配持有的资源（缓存任务与数据库句柄）。
func (a *App) Close() error {
	if a == nil {
		return nil
	}
	// 先停掉缓存任务再关库：任务还在写的时候关闭连接会留下半条记录。
	if a.Cache != nil {
		a.Cache.StopAll()
	}
	// WebDAV 导入是后台下载，退出时也要掐掉，否则进程会被挂住。
	if a.WebDAV != nil {
		a.WebDAV.StopImport()
	}
	if a.DB == nil {
		return nil
	}
	return a.DB.Close()
}

// DefaultUserAgent 返回默认 User-Agent，可通过环境变量 LEGADO_DESKTOP_UA 覆盖。
//
// 书源普遍按 UA 判断是否返回移动端页面，因此伪装成桌面浏览器是必要的。
func DefaultUserAgent() string {
	if v := os.Getenv("LEGADO_DESKTOP_UA"); v != "" {
		return v
	}
	return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
}
