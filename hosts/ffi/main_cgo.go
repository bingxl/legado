//go:build cgo && !android

// Package main 是 c-shared 宿主：把 core 编译成 legado.dll / liblegado.so，
// 供 Flutter 通过 dart:ffi 调用（单进程分发，无子进程）。
//
// 构建（需要 C 工具链，Windows 上为 mingw-w64）：
//
//	go build -buildmode=c-shared -o dist/legado.dll ./ffi
//
// 协议与 HTTP 的 /rpc 完全一致：传入请求信封 JSON，返回响应信封 JSON。
// 字符串由本库分配，调用方用完必须调用 LegadoFree 释放。
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"sync"
	"unsafe"

	"github.com/legado/core/boot"
	"github.com/legado/hosts/rt"
)

var (
	mu  sync.Mutex
	run *rt.Runtime
)

//export LegadoInit
func LegadoInit(root *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if run != nil {
		return respOK(map[string]any{"version": run.Reg.Env.Version})
	}
	home := ""
	if root != nil {
		home = C.GoString(root)
	}
	r, err := rt.Open(home, boot.Options{}, "")
	if err != nil {
		return respErr(err)
	}
	run = r
	return respOK(map[string]any{"version": r.Reg.Env.Version, "root": r.Reg.Env.Root})
}

//export LegadoCall
func LegadoCall(req *C.char) *C.char {
	mu.Lock()
	r := run
	mu.Unlock()
	if r == nil {
		var err error
		r, err = rt.Open("", boot.Options{}, "")
		if err != nil {
			return respErr(err)
		}
		mu.Lock()
		run = r
		mu.Unlock()
	}
	if req == nil {
		return respErr(errInvalid("空请求"))
	}
	out := r.Reg.Handle(context.Background(), []byte(C.GoString(req)))
	return C.CString(string(out))
}

//export LegadoFree
func LegadoFree(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

//export LegadoClose
func LegadoClose() {
	mu.Lock()
	defer mu.Unlock()
	if run != nil {
		_ = run.Close()
		run = nil
	}
}

func respOK(data any) *C.char {
	b, _ := json.Marshal(map[string]any{"ok": true, "data": data})
	return C.CString(string(b))
}

func respErr(err error) *C.char {
	b, _ := json.Marshal(map[string]any{"ok": false, "err": map[string]string{"code": "INTERNAL", "msg": err.Error()}})
	return C.CString(string(b))
}

type errInvalid string

func (e errInvalid) Error() string { return string(e) }

func main() {}
