//go:build !windows

package main

import "log"

// showFatalDialog 在没有原生弹窗的平台（安卓）退化为日志输出。
//
// 安卓端由 Activity 承载，宿主崩溃会由系统接管；这里只保证错误不被吞掉。
func showFatalDialog(title, msg string) {
	log.Printf("[%s] %s", title, msg)
}
