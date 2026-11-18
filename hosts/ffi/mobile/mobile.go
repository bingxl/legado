// Package mobile 是 gomobile bind 的入口：把 core 运行时打包进 AAR，
// 由 Android 侧（Kotlin）通过 JNI 直接调用，进程内无子进程。
//
// 协议与 HTTP 的 /rpc、c-shared 的 LegadoCall 完全一致：
// 传入请求信封 JSON `{"id":n,"method":"Domain.Verb","args":[...]}`，
// 返回响应信封 JSON `{"ok":true,"data":...}` 或 `{"ok":false,"err":{...}}`。
//
// 构建见 hosts/README.md「Android（gomobile）」。
package mobile

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/legado/core/boot"
	"github.com/legado/hosts/rt"
)

var (
	mu  sync.RWMutex
	run *rt.Runtime
)

// Init 打开数据库与注册表。homeDir 为应用私有目录
// （通常是 Context.getFilesDir()），数据库、cache 都放在它下面。
//
// 必须在任何 Call 之前调用；重复调用是幂等的。
func Init(homeDir, version string) error {
	mu.Lock()
	defer mu.Unlock()
	if run != nil {
		return nil
	}
	if homeDir == "" {
		return fmt.Errorf("homeDir 不能为空")
	}
	if err := os.MkdirAll(homeDir, 0o755); err != nil {
		return fmt.Errorf("创建数据目录失败: %w", err)
	}

	// Android 上 SQLite（modernc）依赖 TMPDIR，缺省会导致
	// "disk I/O error: ... (6410)"。必须指向应用私有目录。
	cache := filepath.Join(homeDir, "cache")
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return fmt.Errorf("创建 cache 目录失败: %w", err)
	}
	_ = os.Setenv("TMPDIR", cache)
	_ = os.Setenv("TMP", cache)

	r, err := rt.Open(homeDir, boot.Options{}, version)
	if err != nil {
		return err
	}
	run = r
	return nil
}

// Call 执行一个控制面方法，req 为请求信封 JSON，返回响应信封 JSON。
//
// 返回 error 只在「运行时不可用 / 入参为空」这类无法信封化的情况下出现；
// 业务错误一律走响应信封的 err 字段，与 HTTP 通道保持一致。
func Call(req string) (string, error) {
	mu.RLock()
	r := run
	mu.RUnlock()
	if r == nil {
		return "", fmt.Errorf("core 尚未初始化，请先调用 Init")
	}
	if req == "" {
		return "", fmt.Errorf("空请求")
	}
	out := r.Reg.Handle(context.Background(), []byte(req))
	return string(out), nil
}

// Methods 导出方法表 JSON（schema），供调试与 Dart 侧自检。
func Methods() (string, error) {
	mu.RLock()
	r := run
	mu.RUnlock()
	if r == nil {
		return "", fmt.Errorf("core 尚未初始化，请先调用 Init")
	}
	b, err := json.Marshal(r.Schema())
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// Close 收尾：关库、停后台任务。可重复调用。
func Close() {
	mu.Lock()
	r := run
	run = nil
	mu.Unlock()
	if r != nil {
		_ = r.Close()
	}
}
