//go:build !windows && !android

package main

// webviewProfileSuffix 在非 Windows 平台无需按完整性级别分档（没有 IL 概念，
// WebView 也不是 WebView2）。
func webviewProfileSuffix() string { return "" }
