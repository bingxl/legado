//go:build android

package main

import (
	"os"
	"path/filepath"

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
//
// 顺带在这里把 SQLite 的临时目录设好（见下方 setSQLiteTempDir）：
// run() 里 dataDir() 是第一个调用，一定赶在 bootstrap 打开数据库之前。
func dataDir() string {
	dir := application.Android.StoragePath()
	setSQLiteTempDir(dir)
	return dir
}

// setSQLiteTempDir 给 SQLite 补一个可写的临时目录。
//
// 为什么必须做：modernc sqlite 在排序/临时表溢出内存时要写临时文件，找目录的
// 顺序是 SQLITE_TMPDIR → TMPDIR → /var/tmp → /usr/tmp → /tmp → "."（android
// 下等价实现见 modernc sqlite lib 的 _unixTempFileDir）。安卓进程的 TMPDIR
// 环境变量是空的（Android 不会为 app 进程设置它），那几个目录也不存在，
// 于是所有候选全灭，凡是查询结果大到排序溢出磁盘（如导入上千个书源后的
// ORDER BY 列表）就报 disk I/O error (6410)，即 SQLITE_IOERR_GETTEMPPATH。
//
// 为什么用环境变量而不是 PRAGMA：modernc libc 的 environ 是**第一次 getenv
// 时**才从 os.Environ() 拍的快照（libc.go 的 Environ() 惰性初始化），而全进程
// 只有 sqlite 会调 getenv，且数据库在 bootstrap.New 里才打开 —— 这里提前
// os.Setenv 正好赶在快照之前。PRAGMA temp_store_directory 虽然也能设，但
// 已被上游标记废弃，且需要把目录一路传进 bootstrap 签名，得不偿失。
//
// 目录用 getFilesDir 的兄弟目录 cache（即 Context.getCacheDir()）：app 私有、
// 系统可在空间不足时清理、且不进入 auto-backup，正适合放临时文件。
func setSQLiteTempDir(filesDir string) {
	tmp := filepath.Join(filepath.Dir(filesDir), "cache")
	if err := os.MkdirAll(tmp, 0o755); err != nil {
		return
	}
	os.Setenv("SQLITE_TMPDIR", tmp) //nolint:errcheck // 环境变量设置失败无副作用
	os.Setenv("TMPDIR", tmp)        //nolint:errcheck
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
