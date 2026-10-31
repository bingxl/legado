//go:build android

package main

import (
	"github.com/wailsapp/wails/v3/pkg/application"
)

// platformName 供前端区分桌面端与移动端布局，经 SystemAPI.Platform 暴露。
const platformName = "android"

// dataDir 返回安卓端数据目录。
//
// 用 application.Android.StoragePath()，它对应 Activity.getFilesDir()
// （形如 /data/data/cn.bingxl.legado/files）：app 私有、无需申请存储权限、
// 卸载时随 app 一起清除。SQLite 库、章节缓存、漫画落盘都放在这里。
//
// 调用时机是安全的：Java 侧 onCreate 先 `new WailsBridge(this)` 再
// `bridge.initialize()`，后者经 JNI 调 nativeInit —— 该函数先把 bridge
// 全局引用存下来，才 `go mainFunc()`，因此此处拿 Activity 一定非空。
func dataDir() string {
	return application.Android.StoragePath()
}

// windowsOptions 安卓端没有"窗口宿主"这一层，WebView 由 Activity 直接持有，
// WebviewUserDataPath / AdditionalBrowserArgs 都无对应概念，返回零值。
func windowsOptions() application.WindowsOptions {
	return application.WindowsOptions{}
}

// windowOptions 安卓端窗口选项。
//
// WebView 铺满 Activity，Width / Height / Title / Frameless / Mac 等字段在
// webview_window_android.go 里都是 no-op，设置它们只会误导读者，因此这里只给 URL。
func windowOptions() application.WebviewWindowOptions {
	return application.WebviewWindowOptions{URL: "/"}
}

// webviewBrowserArgs 安卓端没有浏览器进程参数可传。
func webviewBrowserArgs() []string { return nil }

// safeAreaJSON 返回刘海屏/挖孔屏/系统手势区的安全区尺寸，供前端做顶部与底部避让。
//
// 对应 Wails 的 application.Android.SafeAreaJSON()（Java 侧 WindowInsets）。
// 首次调用时 Activity 可能尚未完成布局，返回空串，前端按 0 处理即可。
func safeAreaJSON() string { return application.Android.SafeAreaJSON() }
