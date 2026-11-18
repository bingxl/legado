//go:build !cgo || android

// 没有 C 工具链时（本机 CGO_ENABLED=0）不编译 c-shared，
// 但仍保留包占位，保证 `go build ./...` 与 IDE 索引正常。
package main

func main() {}
