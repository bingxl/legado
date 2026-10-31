package aihttp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

func testClient(retries int) *Client {
	return New(Options{MaxRetries: &retries, RetryBase: time.Millisecond})
}

func testConfig(baseURL string) domain.AIConfig {
	return domain.AIConfig{BaseURL: baseURL, APIKey: "sk-test", Model: "test-model"}
}

func asAIError(t *testing.T, err error) *port.AIError {
	t.Helper()
	var aiErr *port.AIError
	if !errors.As(err, &aiErr) {
		t.Fatalf("期望 *port.AIError，实际 %T: %v", err, err)
	}
	return aiErr
}

// ── Chat ───────────────────────────────────────────────────

func TestChatSuccess(t *testing.T) {
	var gotAuth, gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotPath = r.URL.Path

		var payload chatPayload
		_ = json.NewDecoder(r.Body).Decode(&payload)
		if payload.Stream {
			t.Error("非流式请求不应带 stream=true")
		}
		if payload.Model != "test-model" {
			t.Errorf("model = %q", payload.Model)
		}

		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"choices":[{"message":{"content":"你好"}}],
			"usage":{"prompt_tokens":11,"completion_tokens":7}}`)
	}))
	defer srv.Close()

	out, err := testClient(0).Chat(context.Background(), testConfig(srv.URL), port.ChatRequest{
		Messages: []port.ChatMessage{{Role: "user", Content: "hi"}},
	})
	if err != nil {
		t.Fatalf("Chat 失败: %v", err)
	}
	if out.Content != "你好" {
		t.Fatalf("Content = %q", out.Content)
	}
	if out.PromptTokens != 11 || out.CompletionTokens != 7 {
		t.Fatalf("用量解析错误: %+v", out)
	}
	if gotAuth != "Bearer sk-test" {
		t.Fatalf("Authorization = %q", gotAuth)
	}
	if gotPath != "/chat/completions" {
		t.Fatalf("请求路径 = %q", gotPath)
	}
}

func TestChatBaseURLTrailingSlash(t *testing.T) {
	// 用户填地址时常带结尾斜杠，拼出来不能变成 //chat/completions。
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" {
			t.Errorf("路径出现了重复斜杠: %q", r.URL.Path)
		}
		io.WriteString(w, `{"choices":[{"message":{"content":"ok"}}]}`)
	}))
	defer srv.Close()

	cfg := testConfig(srv.URL + "/")
	if _, err := testClient(0).Chat(context.Background(), cfg, port.ChatRequest{}); err != nil {
		t.Fatalf("Chat 失败: %v", err)
	}
}

func TestChatMissingConfig(t *testing.T) {
	_, err := testClient(0).Chat(context.Background(), domain.AIConfig{}, port.ChatRequest{})
	if err == nil {
		t.Fatal("未配置时应报错")
	}
	if kind := asAIError(t, err).Kind; kind != port.AIErrBadRequest {
		t.Fatalf("Kind = %q, 期望 bad_request", kind)
	}
}

// ── 错误分类与重试 ──────────────────────────────────────────

func TestChatAuthErrorNotRetried(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.WriteHeader(http.StatusUnauthorized)
		io.WriteString(w, `{"error":{"message":"invalid api key"}}`)
	}))
	defer srv.Close()

	_, err := testClient(2).Chat(context.Background(), testConfig(srv.URL), port.ChatRequest{})
	aiErr := asAIError(t, err)
	if aiErr.Kind != port.AIErrAuth {
		t.Fatalf("Kind = %q, 期望 auth", aiErr.Kind)
	}
	if !strings.Contains(aiErr.Message, "invalid api key") {
		t.Fatalf("错误消息未提取出服务端详情: %q", aiErr.Message)
	}
	// 鉴权失败重试无意义，只会放大用户等待。
	if n := atomic.LoadInt32(&calls); n != 1 {
		t.Fatalf("鉴权失败被重试了 %d 次", n)
	}
}

func TestChatRetriesRateLimitThenSucceeds(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&calls, 1) <= 2 {
			w.WriteHeader(http.StatusTooManyRequests)
			io.WriteString(w, `{"error":{"message":"rate limited"}}`)
			return
		}
		io.WriteString(w, `{"choices":[{"message":{"content":"终于成功"}}]}`)
	}))
	defer srv.Close()

	out, err := testClient(2).Chat(context.Background(), testConfig(srv.URL), port.ChatRequest{})
	if err != nil {
		t.Fatalf("限流后应重试成功: %v", err)
	}
	if out.Content != "终于成功" {
		t.Fatalf("Content = %q", out.Content)
	}
	if n := atomic.LoadInt32(&calls); n != 3 {
		t.Fatalf("调用次数 = %d, 期望 3", n)
	}
}

func TestChatServerErrorExhaustsRetries(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.WriteHeader(http.StatusInternalServerError)
		io.WriteString(w, "upstream boom")
	}))
	defer srv.Close()

	_, err := testClient(2).Chat(context.Background(), testConfig(srv.URL), port.ChatRequest{})
	aiErr := asAIError(t, err)
	if aiErr.Kind != port.AIErrServer {
		t.Fatalf("Kind = %q, 期望 server", aiErr.Kind)
	}
	// 首次 + 2 次重试。
	if n := atomic.LoadInt32(&calls); n != 3 {
		t.Fatalf("调用次数 = %d, 期望 3", n)
	}
	// 纯文本错误体也要能给出人话。
	if !strings.Contains(aiErr.Message, "upstream boom") {
		t.Fatalf("纯文本错误体未透出: %q", aiErr.Message)
	}
}

func TestChatProtocolErrorWhenNotJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "<html>502 Bad Gateway</html>")
	}))
	defer srv.Close()

	_, err := testClient(0).Chat(context.Background(), testConfig(srv.URL), port.ChatRequest{})
	if kind := asAIError(t, err).Kind; kind != port.AIErrProtocol {
		t.Fatalf("Kind = %q, 期望 protocol", kind)
	}
}

func TestChatEmptyChoicesIsProtocolError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"choices":[]}`)
	}))
	defer srv.Close()

	_, err := testClient(0).Chat(context.Background(), testConfig(srv.URL), port.ChatRequest{})
	if kind := asAIError(t, err).Kind; kind != port.AIErrProtocol {
		t.Fatalf("Kind = %q, 期望 protocol", kind)
	}
}

func TestChatTimeoutClassified(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(300 * time.Millisecond)
		io.WriteString(w, `{"choices":[{"message":{"content":"late"}}]}`)
	}))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	_, err := testClient(0).Chat(ctx, testConfig(srv.URL), port.ChatRequest{})
	if kind := asAIError(t, err).Kind; kind != port.AIErrTimeout {
		t.Fatalf("Kind = %q, 期望 timeout", kind)
	}
}

func TestChatUserCancelNotRetried(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		time.Sleep(500 * time.Millisecond)
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()

	_, err := testClient(2).Chat(ctx, testConfig(srv.URL), port.ChatRequest{})
	if err == nil {
		t.Fatal("取消后应返回错误")
	}
	// 用户点「停止」必须能被上层识别，不能伪装成网络错误。
	if !strings.Contains(err.Error(), "context canceled") {
		t.Fatalf("应返回 context.Canceled，实际: %v", err)
	}
	if n := atomic.LoadInt32(&calls); n != 1 {
		t.Fatalf("取消后不应重试，实际调用 %d 次", n)
	}
}

// ── ChatStream ─────────────────────────────────────────────

func writeSSE(w http.ResponseWriter, chunks []string, done bool) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.WriteHeader(http.StatusOK)
	fl, _ := w.(http.Flusher)
	for _, c := range chunks {
		fmt.Fprintf(w, "data: %s\n\n", c)
		if fl != nil {
			fl.Flush()
		}
	}
	if done {
		io.WriteString(w, "data: [DONE]\n\n")
		if fl != nil {
			fl.Flush()
		}
	}
}

func TestChatStreamConcatenatesDeltas(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload chatPayload
		_ = json.NewDecoder(r.Body).Decode(&payload)
		if !payload.Stream {
			t.Error("流式请求必须带 stream=true")
		}
		writeSSE(w, []string{
			`{"choices":[{"delta":{"content":"你"}}]}`,
			`{"choices":[{"delta":{"content":""}}]}`,
			`{"choices":[{"delta":{"content":"好"}}]}`,
			`{"choices":[{"delta":{}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}`,
		}, true)
	}))
	defer srv.Close()

	var deltas []string
	out, err := testClient(0).ChatStream(context.Background(), testConfig(srv.URL), port.ChatRequest{},
		func(d string) error {
			deltas = append(deltas, d)
			return nil
		})
	if err != nil {
		t.Fatalf("ChatStream 失败: %v", err)
	}
	if out.Content != "你好" {
		t.Fatalf("Content = %q", out.Content)
	}
	// 空 delta 不应回调，否则前端会收到大量无意义事件。
	if len(deltas) != 2 || deltas[0] != "你" || deltas[1] != "好" {
		t.Fatalf("回调序列 = %v", deltas)
	}
	if out.PromptTokens != 3 || out.CompletionTokens != 2 {
		t.Fatalf("流式用量未解析: %+v", out)
	}
}

func TestChatStreamMissingDoneStillReturnsContent(t *testing.T) {
	// 上游没发 [DONE] 直接断开，属于常见的不规范实现。
	// 此时应把已收到的内容当作结果返回，而不是整个失败。
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeSSE(w, []string{`{"choices":[{"delta":{"content":"半截"}}]}`}, false)
	}))
	defer srv.Close()

	out, err := testClient(0).ChatStream(context.Background(), testConfig(srv.URL), port.ChatRequest{}, nil)
	if err != nil {
		t.Fatalf("缺 [DONE] 不应报错: %v", err)
	}
	if out.Content != "半截" {
		t.Fatalf("Content = %q", out.Content)
	}
}

func TestChatStreamMidStreamErrorObject(t *testing.T) {
	// 有些服务在流中途以 error 对象报告配额耗尽。
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeSSE(w, []string{
			`{"choices":[{"delta":{"content":"前半"}}]}`,
			`{"error":{"message":"quota exceeded"}}`,
		}, false)
	}))
	defer srv.Close()

	out, err := testClient(0).ChatStream(context.Background(), testConfig(srv.URL), port.ChatRequest{}, nil)
	if err == nil {
		t.Fatal("流中 error 对象应作为错误返回")
	}
	if !strings.Contains(err.Error(), "quota exceeded") {
		t.Fatalf("错误信息丢失: %v", err)
	}
	// 已生成的部分仍要保留，便于前端展示「答到一半失败」。
	if out.Content != "前半" {
		t.Fatalf("部分内容 = %q", out.Content)
	}
}

func TestChatStreamCallbackErrorAborts(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeSSE(w, []string{
			`{"choices":[{"delta":{"content":"a"}}]}`,
			`{"choices":[{"delta":{"content":"b"}}]}`,
		}, true)
	}))
	defer srv.Close()

	sentinel := errors.New("stop now")
	_, err := testClient(0).ChatStream(context.Background(), testConfig(srv.URL), port.ChatRequest{},
		func(string) error { return sentinel })
	if err == nil || !strings.Contains(err.Error(), "stop now") {
		t.Fatalf("回调错误应中断并上抛，实际: %v", err)
	}
}

func TestChatStreamRetriesBeforeFirstDelta(t *testing.T) {
	// 还没吐出任何内容时重试是安全的，应利用这一点扛住瞬时 5xx。
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&calls, 1) == 1 {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		writeSSE(w, []string{`{"choices":[{"delta":{"content":"恢复"}}]}`}, true)
	}))
	defer srv.Close()

	out, err := testClient(1).ChatStream(context.Background(), testConfig(srv.URL), port.ChatRequest{}, nil)
	if err != nil {
		t.Fatalf("首包失败后重试应成功: %v", err)
	}
	if out.Content != "恢复" {
		t.Fatalf("Content = %q", out.Content)
	}
}

// ── Embed ──────────────────────────────────────────────────

func TestEmbedKeepsInputOrder(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 故意乱序返回，验证客户端按 index 重排而不是信任顺序。
		io.WriteString(w, `{"data":[
			{"index":2,"embedding":[3,0]},
			{"index":0,"embedding":[1,0]},
			{"index":1,"embedding":[2,0]}
		]}`)
	}))
	defer srv.Close()

	cfg := testConfig(srv.URL)
	cfg.EmbeddingModel = "emb"
	vecs, err := testClient(0).Embed(context.Background(), cfg, "", []string{"a", "b", "c"})
	if err != nil {
		t.Fatalf("Embed 失败: %v", err)
	}
	if len(vecs) != 3 {
		t.Fatalf("返回 %d 条", len(vecs))
	}
	for i, want := range []float32{1, 2, 3} {
		if vecs[i][0] != want {
			t.Fatalf("第 %d 条首分量 = %v, 期望 %v（未按 index 排序）", i, vecs[i][0], want)
		}
	}
}

func TestEmbedCountMismatchIsProtocolError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"data":[{"index":0,"embedding":[1]}]}`)
	}))
	defer srv.Close()

	cfg := testConfig(srv.URL)
	cfg.EmbeddingModel = "emb"
	_, err := testClient(0).Embed(context.Background(), cfg, "", []string{"a", "b"})
	if kind := asAIError(t, err).Kind; kind != port.AIErrProtocol {
		t.Fatalf("Kind = %q, 期望 protocol", kind)
	}
}

func TestEmbedBatchesLargeInput(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		var payload struct {
			Input []string `json:"input"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		items := make([]string, len(payload.Input))
		for i := range payload.Input {
			items[i] = fmt.Sprintf(`{"index":%d,"embedding":[%d]}`, i, i)
		}
		io.WriteString(w, `{"data":[`+strings.Join(items, ",")+`]}`)
	}))
	defer srv.Close()

	cfg := testConfig(srv.URL)
	cfg.EmbeddingModel = "emb"

	inputs := make([]string, embedBatchSize+10)
	for i := range inputs {
		inputs[i] = fmt.Sprintf("t%d", i)
	}
	vecs, err := testClient(0).Embed(context.Background(), cfg, "", inputs)
	if err != nil {
		t.Fatalf("Embed 失败: %v", err)
	}
	if len(vecs) != len(inputs) {
		t.Fatalf("返回 %d 条, 期望 %d", len(vecs), len(inputs))
	}
	// 超出单批上限时应拆成两次请求，避免撞服务端的 input 数量限制。
	if n := atomic.LoadInt32(&calls); n != 2 {
		t.Fatalf("请求次数 = %d, 期望 2", n)
	}
}

func TestEmbedWithoutConfig(t *testing.T) {
	// 显式配了 chat 但没配 embedding 模型时必须明确报错，
	// 上层据此降级为关键词召回。
	cfg := domain.AIConfig{BaseURL: "https://api.deepseek.com/v1", Model: "deepseek-chat"}
	_, err := testClient(0).Embed(context.Background(), cfg, "", []string{"a"})
	if kind := asAIError(t, err).Kind; kind != port.AIErrBadRequest {
		t.Fatalf("Kind = %q, 期望 bad_request", kind)
	}
}

func TestEmbedEmptyInputSkipsRequest(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
	}))
	defer srv.Close()

	cfg := testConfig(srv.URL)
	cfg.EmbeddingModel = "emb"
	vecs, err := testClient(0).Embed(context.Background(), cfg, "", nil)
	if err != nil {
		t.Fatalf("空输入不应报错: %v", err)
	}
	if len(vecs) != 0 {
		t.Fatalf("应返回空结果，实际 %d 条", len(vecs))
	}
	if n := atomic.LoadInt32(&calls); n != 0 {
		t.Fatalf("空输入不应发起请求，实际 %d 次", n)
	}
}
