//go:build windows

package main

import "golang.org/x/sys/windows"

// webviewProfileSuffix 返回按进程完整性级别区分的 WebView2 profile 目录后缀：
// 管理员运行（High IL）用 "-h"，普通运行（Medium IL）用 "-u"。
//
// 为什么必须分档：Chromium 的 profile 进程单例是**带完整性标签的命名互斥体**。
// 管理员进程创建的互斥体对普通进程不可见，CreateCoreWebView2Controller 会返回
// 0x800700AA（ERROR_SHARING_VIOLATION，"请求的资源正在使用中"），Wails 随即
// os.Exit(1) —— 症状是"双击没反应，只能以管理员身份运行"。
// 分档后两种启动方式各用各的 profile，互不干扰。
//
// 注意：这是"按提权与否"分档而不是按实际 IL 数值。对本应用而言两者等价：
// 未提权的管理员令牌是 Medium IL，提权后是 High IL。
func webviewProfileSuffix() string {
	if windows.GetCurrentProcessToken().IsElevated() {
		return "-h"
	}
	return "-u"
}
