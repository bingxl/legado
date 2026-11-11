//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

// showFatalDialog 弹出 Windows 原生错误框。
//
// 启动失败时应用还没有窗口，Element Plus 的 toast 用不上，stderr 也无处可去
// （资源管理器双击启动没有控制台）。原生 MessageBox 是唯一能让用户立刻看到
// 原因、并据此采取行动（改用管理员运行、修 WebView2 运行时）的手段。
func showFatalDialog(title, msg string) {
	const (
		mbOK        = 0x00000000
		mbIconError = 0x00000010
	)

	msgPtr, err := syscall.UTF16PtrFromString(msg)
	if err != nil {
		return
	}
	titlePtr, err := syscall.UTF16PtrFromString(title)
	if err != nil {
		return
	}
	user32 := syscall.NewLazyDLL("user32.dll")
	_, _, _ = user32.NewProc("MessageBoxW").Call(
		0, // hWnd：没有父窗口
		uintptr(unsafe.Pointer(msgPtr)),
		uintptr(unsafe.Pointer(titlePtr)),
		uintptr(mbOK|mbIconError),
	)
}
