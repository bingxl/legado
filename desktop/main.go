// Package main 是应用的**组合根**（Composition Root）。
//
// 职责：装配依赖、注册 Wails 服务、创建窗口。
// 除本文件外，其余代码不应出现具体实现类型的硬编码装配——
// 依赖注入集中在此，便于替换实现与编写测试。
package main

import (
	"embed"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path"

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
		log.Fatal(err)
	}
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
	systemAPI := api.NewSystemAPI(platformName, safeAreaJSON)
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

	wailsApp := application.New(application.Options{
		Name:        "legado-desktop",
		Description: "Legado 桌面阅读器",
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
//   - "/raw/"      任意本地文件（?p=绝对路径），用于 PDF 与本地图片直读
//   - "/img/"      网络图片代理（?u=图片地址&src=书源地址），用于绕开图床防盗链
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

// serveRawFile 按绝对路径提供本地文件，供 PDF 阅读与本地图片预览使用。
//
// 安全说明：这是单用户桌面应用，读取本地文件属于正常需求；
// http.ServeFile 会规整路径，不会因 "../" 而越界。
// 若将来开放为多用户服务，必须改为白名单校验。
func serveRawFile(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Query().Get("p")
	if path == "" {
		http.Error(w, "缺少参数 p", http.StatusBadRequest)
		return
	}
	if _, err := os.Stat(path); err != nil {
		http.Error(w, "文件不可访问", http.StatusNotFound)
		return
	}
	http.ServeFile(w, r, path)
}
