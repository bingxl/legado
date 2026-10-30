package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// 前端用 history 模式路由，整页加载 /book/2、/reader/2 时必须回退到 index.html，
// 否则 Wails 的静态文件服务会直接 404（白屏且无法退回应用）。
func TestAssetHandlerSPAFallback(t *testing.T) {
	h := assetHandler(t.TempDir())

	cases := []struct {
		name       string
		method     string
		path       string
		wantStatus int
		wantHTML   bool
	}{
		{"根路径", http.MethodGet, "/", http.StatusOK, true},
		{"详情页深链", http.MethodGet, "/book/2", http.StatusOK, true},
		{"阅读器深链", http.MethodGet, "/reader/2", http.StatusOK, true},
		{"未知前端路由", http.MethodGet, "/nope", http.StatusOK, true},
		{"缺失的静态资源仍 404", http.MethodGet, "/assets/missing.js", http.StatusNotFound, false},
	}
	for _, c := range cases {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(c.method, c.path, nil)
		h.ServeHTTP(rec, req)
		if rec.Code != c.wantStatus {
			t.Fatalf("%s: 状态码应为 %d，实际 %d", c.name, c.wantStatus, rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); c.wantHTML {
			if !strings.Contains(ct, "text/html") {
				t.Fatalf("%s: 应返回 html，实际 Content-Type=%q", c.name, ct)
			}
			if !strings.Contains(rec.Body.String(), `id="app"`) {
				t.Fatalf("%s: 返回内容不是前端入口页", c.name)
			}
		}
	}
}
