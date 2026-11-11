// Package main 是应用的**组合根**（Composition Root）。
//
// 职责：装配依赖、注册 Wails 服务、创建窗口。
// 除本文件外，其余代码不应出现具体实现类型的硬编码装配——
// 依赖注入集中在此，便于替换实现与编写测试。
package main

import (
	"embed"
	"fmt"
	"io"
	"io/fs"
	"log"
	"log/slog"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"

	"github.com/wailsapp/wails/v3/pkg/application"

	"github.com/legado/desktop/api"
	"github.com/legado/desktop/internal/adapter/eventwails"
	"github.com/legado/desktop/internal/bootstrap"
)

//go:embed all:frontend/dist
var assets embed.FS

// dataDir / windowOptions / windowsOptions / safeAreaJSON 等平台相关实现
// 分别在 platform_desktop.go（!android）与 platform_android.go（android）中。
// 本文件只做装配，不含任何 GOOS/GOARCH 分支。

func main() {
	if err := run(); err != nil {
		log.Printf("启动失败: %v", err)
		showFatalDialog("Legado 启动失败", err.Error()+logHint())
		os.Exit(1)
	}
}

// appLogPath 启动日志的绝对路径（数据目录下的 app.log），空串表示还没建好。
var appLogPath string

// logHint 返回给用户的日志位置提示。
func logHint() string {
	if appLogPath == "" {
		return ""
	}
	return "\n\n详细日志：" + appLogPath
}

// setupLogging 把日志同时写到 stderr 与数据目录下的 app.log，并返回可复用的
// 写入器（Wails 系统日志也走它）。
//
// 为什么必须落文件：Wails 的致命错误（WebView2 控制器创建失败、宿主初始化失败等）
// 在库内部直接 os.Exit(1)，错误只经标准库 log 输出到 stderr。而从资源管理器双击
// 启动的进程**没有控制台**，stderr 无处可去 —— 用户只看到"双击没反应"，既不知道
// 原因也没法自救。落盘后可以在弹窗里告知路径，也便于自动化测试断言失败原因。
//
// 另外生产构建下 Wails 默认日志器是 io.Discard（见 wails application.go：
// Options.Logger 为空且非 debug 模式时直接丢弃），宿主层错误一个字都不会留下。
func setupLogging(root string) io.Writer {
	appLogPath = filepath.Join(root, "app.log")
	f, err := os.OpenFile(appLogPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		log.SetOutput(os.Stderr)
		return os.Stderr
	}
	w := io.MultiWriter(os.Stderr, &fatalSniffer{w: f})
	log.SetOutput(w)
	log.SetFlags(log.LstdFlags)
	return w
}

// fatalSniffer 在写日志的同时识别致命错误标记并弹出原生错误框。
//
// Wails 的致命错误是库内部 os.Exit(1)，main 里的错误处理根本走不到，
// 只能在日志输出这一层拦截。同一错误只弹一次，避免刷屏。
type fatalSniffer struct {
	w     io.Writer
	mu    sync.Mutex
	buf   []byte
	shown bool
}

// fatalMarkers 是"启动即致命"的日志特征 → 面向用户的中文说明。
var fatalMarkers = []struct{ mark, hint string }{
	{"[WebView2 Error]", "WebView 渲染内核初始化失败。"},
	{"mcp: failed to listen", "调试端口 9099 已被占用（可能已有一个实例在运行）。"},
}

// Write 实现 io.Writer：先落盘，再判断是否需要弹窗。
func (f *fatalSniffer) Write(p []byte) (int, error) {
	n, err := f.w.Write(p)

	f.mu.Lock()
	f.buf = append(f.buf, p...)
	if len(f.buf) > 8192 {
		f.buf = f.buf[len(f.buf)-8192:]
	}
	for _, m := range fatalMarkers {
		if f.shown || !strings.Contains(string(f.buf), m.mark) {
			continue
		}
		f.shown = true
		line := firstLineWith(f.buf, m.mark)
		f.mu.Unlock()
		// 同步弹窗：宿主紧接着就会 os.Exit，异步执行会来不及显示。
		showFatalDialog("Legado 启动失败", m.hint+"\n"+line+logHint())
		f.mu.Lock()
		break
	}
	f.mu.Unlock()
	return n, err
}

// firstLineWith 返回包含 mark 的那一行（去掉前缀时间戳）。
func firstLineWith(buf []byte, mark string) string {
	s := string(buf)
	i := strings.Index(s, mark)
	if i < 0 {
		return mark
	}
	rest := s[i:]
	if j := strings.IndexByte(rest, '\n'); j >= 0 {
		rest = rest[:j]
	}
	return strings.TrimSpace(rest)
}

// run 装配并启动应用，把错误统一收敛到 main。
//
// 业务依赖由 internal/bootstrap 装配，本函数只负责 Wails 宿主相关的部分：
// 事件总线实现、绑定层与窗口。
func run() error {
	root := dataDir()
	if err := os.MkdirAll(root, 0o755); err != nil {
		return fmt.Errorf("创建数据目录失败: %w", err)
	}
	appLog := setupLogging(root)

	// ── 事件总线 ────────────────────────────────────────────────
	// 先创建占位实例，Wails App 就绪后再 Attach。
	// 这样服务层在启动阶段发出的进度事件不会丢失。
	bus := eventwails.New()

	biz, err := bootstrap.New(root, bus)
	if err != nil {
		return err
	}
	defer biz.Close()

	// ── Wails 绑定层 ────────────────────────────────────────────
	systemAPI := api.NewSystemAPI(platformName, safeAreaJSON, setFullscreen, isFullscreen)
	bookshelfAPI := api.NewBookshelfAPI(biz.Bookshelf)
	libraryAPI := api.NewLibraryAPI(biz.Library)
	readerAPI := api.NewReaderAPI(biz.Reader)
	sourceAPI := api.NewSourceAPI(biz.Source)
	webdavAPI := api.NewWebDAVAPI(biz.WebDAV)
	cacheAPI := api.NewCacheAPI(biz.Cache)
	aiAPI := api.NewAIAPI(biz.AI)
	replaceRuleAPI := api.NewReplaceRuleAPI(biz.ReplaceRule)
	sourceDebugAPI := api.NewSourceDebugAPI(biz.SourceDebug)
	sourceLoginAPI := api.NewSourceLoginAPI(biz.SourceLogin)
	dictAPI := api.NewDictAPI(biz.Dict)

	wailsApp := application.New(application.Options{
		Name:        "legado-desktop",
		Description: "Legado 桌面阅读器",
		// 显式给日志器：生产构建下 Wails 默认丢弃全部系统日志，
		// 宿主层错误将无处可查（见 setupLogging 的说明）。
		Logger: slog.New(slog.NewTextHandler(appLog, &slog.HandlerOptions{Level: slog.LevelInfo})),
		Services: []application.Service{
			application.NewService(bookshelfAPI),
			application.NewService(libraryAPI),
			application.NewService(readerAPI),
			application.NewService(sourceAPI),
			application.NewService(webdavAPI),
			application.NewService(cacheAPI),
			application.NewService(replaceRuleAPI),
			application.NewService(sourceDebugAPI),
			application.NewService(sourceLoginAPI),
			application.NewService(aiAPI),
			application.NewService(dictAPI),
			application.NewService(systemAPI),
		},
		Assets: application.AssetOptions{
			Handler: assetHandler(root),
		},
		Windows: windowsOptions(),
		Mac: application.MacOptions{
			ApplicationShouldTerminateAfterLastWindowClosed: true,
		},
	})

	// App 就绪后回填到需要它的组件。
	bus.Attach(wailsApp)
	systemAPI.Attach(wailsApp)

	wailsApp.Window.NewWithOptions(windowOptions())

	return wailsApp.Run()
}

// assetHandler 组合前端静态资源与本地资源路由。
//
// 路由：
//   - "/"          前端构建产物（嵌入的 frontend/dist）
//   - "/local/..." 应用数据目录，用于封面与漫画图片缓存
//   - "/raw/<arg>[.ext]" 任意本地文件（arg = base64url(绝对路径)），用于 PDF 与本地图片直读
//   - "/img/<arg>[.ext]" 网络图片代理（arg = base64url(图片地址 + "\n" + 书源地址)），绕开图床防盗链
//
// 参数编进路径段而不是查询串，是安卓端能读到文件的必要条件，见 asset_url.go。
// 旧写法 "?p=" / "?u=&src=" 仍然兼容（桌面端早期链接与测试用）。
//
// 前端因此可以用普通 <img src> / <iframe src> 访问本地资源，无需 base64 内联。
func assetHandler(root string) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/", spaHandler())
	// http.FileServer 会自行规整路径，天然防御目录穿越。
	mux.Handle("/local/", http.StripPrefix("/local/", http.FileServer(http.Dir(root))))
	mux.HandleFunc("/raw/", serveRawFile)
	mux.HandleFunc("/img/", serveRemoteImage)
	return mux
}

// spaHandler 提供前端构建产物，并为前端路由补上 index.html 回退。
//
// Wails 的 AssetFileServerFS 只是纯静态服务：路径在 dist 里不存在就直接 404。
// 而前端用的是 history 模式路由（/book/2、/reader/2 这类地址没有对应文件），
// 一旦发生整页加载（F5 / Ctrl+R / 窗口重建），用户会看到白屏 404 且无法返回。
// 这里把「无扩展名的 GET/HEAD 路径」统一回退到 index.html，交给前端路由解析。
func spaHandler() http.Handler {
	files := application.AssetFileServerFS(assets)
	serveIndex := func(w http.ResponseWriter, r *http.Request) {
		r2 := r.Clone(r.Context())
		r2.URL.Path = "/"
		files.ServeHTTP(w, r2)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			files.ServeHTTP(w, r)
			return
		}
		// 带扩展名的是真实静态资源（.js/.css/.png…），找不到就该 404。
		if p := path.Clean(r.URL.Path); p == "/" || path.Ext(p) != "" {
			files.ServeHTTP(w, r)
			return
		}
		if _, err := fs.Stat(assets, "frontend/dist"+path.Clean(r.URL.Path)); err != nil {
			serveIndex(w, r)
			return
		}
		files.ServeHTTP(w, r)
	})
}

// serveRawFile 按绝对路径提供本地文件，供文本导入、PDF 阅读与本地图片预览使用。
//
// 安全说明：这是单用户桌面应用，读取本地文件属于正常需求；
// http.ServeFile 会规整路径，不会因 "../" 而越界。
// 若将来开放为多用户服务，必须改为白名单校验。
func serveRawFile(w http.ResponseWriter, r *http.Request) {
	filePath, ok := decodeAssetArg(r, rawPrefix, "p")
	if !ok {
		http.Error(w, "缺少文件路径", http.StatusBadRequest)
		return
	}
	if _, err := os.Stat(filePath); err != nil {
		http.Error(w, "文件不可访问", http.StatusNotFound)
		return
	}
	http.ServeFile(w, r, filePath)
}
