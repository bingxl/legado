//go:build !android

package main

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/adrg/xdg"

	"github.com/wailsapp/wails/v3/pkg/application"
)

// platformName 供前端区分桌面端与移动端布局，经 SystemAPI.Platform 暴露。
const platformName = "desktop"

// dataDir 返回桌面端数据目录：默认遵循 XDG 规范，可用环境变量覆盖。
func dataDir() string {
	if v := os.Getenv("LEGADO_DESKTOP_HOME"); v != "" {
		return v
	}
	return filepath.Join(xdg.DataHome, "legado-desktop")
}

// windowsOptions 桌面端窗口宿主选项。
//
// WebviewUserDataPath 刻意指到临时目录：不指定时 WebView2 会把用户数据目录放在
// %APPDATA%\<exe 名>，Roaming 属于 Defender 受控文件夹访问的保护范围。
//
// 目录名再按**进程完整性级别**分档（-u 普通 / -h 管理员，见 webviewProfileSuffix）：
// Chromium 的 profile 单例是带完整性标签的命名互斥体，管理员进程建的 profile
// 无法被普通进程复用，CreateCoreWebView2Controller 会报 0x800700AA 后直接退出，
// 症状是"双击没反应，只能以管理员身份运行"。分档后两种方式互不干扰。
func windowsOptions() application.WindowsOptions {
	return application.WindowsOptions{
		WebviewUserDataPath:   filepath.Join(os.TempDir(), "legado-desktop-webview"+webviewProfileSuffix()),
		AdditionalBrowserArgs: webviewBrowserArgs(),
	}
}

// windowOptions 桌面端主窗口：固定尺寸 + 平台装饰。
func windowOptions() application.WebviewWindowOptions {
	return application.WebviewWindowOptions{
		Title:  "Legado",
		Width:  1200,
		Height: 780,
		Mac: application.MacWindow{
			InvisibleTitleBarHeight: 50,
			Backdrop:                application.MacBackdropTranslucent,
			TitleBar:                application.MacTitleBarHiddenInset,
		},
		BackgroundColour: application.NewRGB(255, 255, 255),
		URL:              "/",
	}
}

// webviewBrowserArgs 返回传给 WebView2 的附加启动参数。
//
// 默认带 --disable-gpu：WebView2 Runtime 155 起，部分机器（Intel 核显 + 独显混合、
// 或装了虚拟显示驱动的环境）GPU 进程初始化失败，CreateCoreWebView2Controller 会返回
// 0x8000ffff（Catastrophic failure），Wails 直接 os.Exit，留下一个纯白窗口——
// 表现像前端挂了，实际是 WebView 根本没挂到窗口上。
// 参考 MicrosoftEdge/WebView2Feedback#5759。
//
// 需要 GPU 加速（WebGL / canvas 加速）时用 LEGADO_WEBVIEW_ARGS 覆盖，
// 逗号分隔，会整体替换默认值，例如 LEGADO_WEBVIEW_ARGS=--disable-gpu-compositing。
func webviewBrowserArgs() []string {
	if v := os.Getenv("LEGADO_WEBVIEW_ARGS"); v != "" {
		return strings.Split(v, ",")
	}
	return []string{"--disable-gpu"}
}

// safeAreaJSON 桌面端没有刘海屏/系统手势区，返回空串让前端跳过适配。
func safeAreaJSON() string { return "" }

// setFullscreen 切换主窗口全屏态，返回操作后的实际状态。
//
// 走 Wails 的 Window 接口（Fullscreen / UnFullscreen / IsFullscreen 三个方法都在
// Window 接口上）。拿不到窗口（应用未就绪、窗口已销毁）时返回 false，
// 前端据此判定"这次没切成功"，不会把界面留在错误的沉浸状态。
func setFullscreen(on bool) bool {
	w := currentWindow()
	if w == nil {
		return false
	}
	if on {
		w.Fullscreen()
	} else {
		w.UnFullscreen()
	}
	return w.IsFullscreen()
}

// isFullscreen 查询主窗口是否全屏。
func isFullscreen() bool {
	w := currentWindow()
	if w == nil {
		return false
	}
	return w.IsFullscreen()
}

// currentWindow 取当前活动窗口；应用或窗口还不存在时返回 nil。
func currentWindow() application.Window {
	app := application.Get()
	if app == nil || app.Window == nil {
		return nil
	}
	return app.Window.Current()
}
