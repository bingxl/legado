// Package http 是 loopback 数据面宿主：控制面之外的大对象与事件走这里。
//
// 分工（Architecture §2）：
//   - 控制面（<64KB、列表、设置）：优先走 FFI；HTTP 的 /rpc 是等价备用通道
//   - 数据面（正文、图片、音频）：一律走 HTTP，避免 JSON 拷贝与 Dart 侧大字符串
//   - 事件：SSE（/events），CLI 与 Flutter 订阅同一份
package http

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/legado/core/kernel"
	"github.com/legado/hosts/rt"
)

// Server 是 loopback HTTP 宿主。
type Server struct {
	rt  *rt.Runtime
	srv *http.Server
	ln  net.Listener
}

// New 创建服务器。addr 支持 :0（随机端口）与 127.0.0.1:0。
func New(r *rt.Runtime, addr string) *Server {
	if addr == "" {
		addr = "127.0.0.1:0"
	}
	mux := http.NewServeMux()
	s := &Server{rt: r}

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("/schema", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, r.Schema())
	})
	mux.HandleFunc("/methods", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, r.Reg.Methods())
	})
	mux.HandleFunc("/rpc", func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodPost {
			http.Error(w, "只支持 POST", http.StatusMethodNotAllowed)
			return
		}
		body, err := io.ReadAll(io.LimitReader(req.Body, 8<<20))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(r.Reg.Handle(req.Context(), body))
	})
	mux.HandleFunc("/events", func(w http.ResponseWriter, req *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "不支持流式", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")

		ch, cancel := r.Biz.Trace.Subscribe()
		defer cancel()
		for _, e := range r.Biz.Trace.Recent() {
			writeSSE(w, e)
		}
		flusher.Flush()

		heartbeat := time.NewTicker(20 * time.Second)
		defer heartbeat.Stop()
		for {
			select {
			case <-req.Context().Done():
				return
			case e, ok := <-ch:
				if !ok {
					return
				}
				writeSSE(w, e)
				flusher.Flush()
			case <-heartbeat.C:
				_, _ = io.WriteString(w, ": ping\n\n")
				flusher.Flush()
			}
		}
	})

	s.srv = &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	return s
}

func writeSSE(w io.Writer, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintf(w, "data: %s\n\n", b)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

// Addr 返回实际监听地址（Listen 之后可用）。
func (s *Server) Addr() string {
	if s.ln == nil {
		return ""
	}
	return s.ln.Addr().String()
}

// URL 返回可访问的基地址。
func (s *Server) URL() string {
	a := s.Addr()
	if a == "" {
		return ""
	}
	if strings.HasPrefix(a, "127.0.0.1") || strings.HasPrefix(a, "[::]") || strings.HasPrefix(a, "0.0.0.0") {
		_, port, err := net.SplitHostPort(a)
		if err == nil {
			return "http://127.0.0.1:" + port
		}
	}
	return "http://" + a
}

// Listen 在指定地址上开始监听（不阻塞）。
func (s *Server) Listen(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	s.ln = ln
	go func() { _ = s.srv.Serve(ln) }()
	return nil
}

// Close 关闭服务器。
func (s *Server) Close() error {
	if s.srv == nil {
		return nil
	}
	return s.srv.Close()
}

// ErrorOf 把内核错误转成 HTTP 状态码（供数据面复用）。
func ErrorOf(err error) int {
	ke := kernel.AsError(err)
	switch ke.Code {
	case kernel.CodeNotFound:
		return http.StatusNotFound
	case kernel.CodeInvalid:
		return http.StatusBadRequest
	case kernel.CodeAuthRequired:
		return http.StatusUnauthorized
	case kernel.CodeUnsupported:
		return http.StatusNotImplemented
	default:
		return http.StatusInternalServerError
	}
}
