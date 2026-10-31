// Package aihttp 实现 OpenAI 兼容协议的大模型客户端。
//
// 之所以只做 OpenAI 兼容协议：它是事实标准，OpenAI / DeepSeek / 通义 / 智谱 /
// Moonshot / 本机 Ollama 都提供兼容端点。为每家写适配器既无收益也难维护。
package aihttp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

const (
	defaultMaxRetries    = 2
	defaultRetryBase     = 500 * time.Millisecond
	defaultChatTimeout   = 120 * time.Second
	defaultStreamTimeout = 300 * time.Second
	// embedBatchSize 控制单次 embedding 请求的条数。
	// 太大会撞到服务端的 input 数量/总 token 上限，太小则往返开销高。
	embedBatchSize = 64
	// maxErrorBody 限制错误响应体的读取长度，避免异常服务灌满内存。
	maxErrorBody = 4 << 10
)

// Options 构造客户端参数。零值即合理默认，测试可注入 http.Client 与极短退避。
type Options struct {
	// HTTPClient 为 nil 时使用不带总超时的客户端——超时统一由每次调用的 ctx 控制，
	// 否则长回答会被 http.Client.Timeout 拦腰截断。
	HTTPClient *http.Client
	UserAgent  string
	// MaxRetries 是「额外」重试次数，0 表示只调一次。
	MaxRetries *int
	RetryBase  time.Duration
}

// Client 是 OpenAI 兼容协议客户端。
type Client struct {
	http       *http.Client
	ua         string
	maxRetries int
	retryBase  time.Duration
}

// 编译期确认满足端口契约。
var _ port.LLMClient = (*Client)(nil)

// New 创建客户端。
func New(opts Options) *Client {
	hc := opts.HTTPClient
	if hc == nil {
		hc = &http.Client{Timeout: 0}
	}
	retries := defaultMaxRetries
	if opts.MaxRetries != nil {
		retries = *opts.MaxRetries
	}
	base := opts.RetryBase
	if base <= 0 {
		base = defaultRetryBase
	}
	return &Client{http: hc, ua: opts.UserAgent, maxRetries: retries, retryBase: base}
}

// ── 协议结构 ────────────────────────────────────────────────

type chatPayload struct {
	Model       string             `json:"model"`
	Messages    []port.ChatMessage `json:"messages"`
	Temperature *float64           `json:"temperature,omitempty"`
	MaxTokens   int                `json:"max_tokens,omitempty"`
	Stream      bool               `json:"stream,omitempty"`
}

type apiErrorBody struct {
	Message string `json:"message"`
	Type    string `json:"type"`
	Code    any    `json:"code"`
}

type chatResponseBody struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
		Delta struct {
			Content string `json:"content"`
		} `json:"delta"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
	Usage *struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
	Error *apiErrorBody `json:"error"`
}

type embedResponseBody struct {
	Data []struct {
		Embedding []float64 `json:"embedding"`
		Index     int       `json:"index"`
	} `json:"data"`
	Model string        `json:"model"`
	Error *apiErrorBody `json:"error"`
}

// ── Chat ───────────────────────────────────────────────────

// Chat 执行一次非流式补全。
func (c *Client) Chat(ctx context.Context, cfg domain.AIConfig, req port.ChatRequest) (port.ChatResponse, error) {
	if err := requireChatConfig(cfg); err != nil {
		return port.ChatResponse{}, err
	}
	ctx, cancel := withDefaultTimeout(ctx, defaultChatTimeout)
	defer cancel()

	payload := buildChatPayload(cfg, req, false)
	var out port.ChatResponse

	err := c.withRetry(ctx, func() error {
		resp, err := c.postJSON(ctx, cfg.ChatEndpoint()+"/chat/completions", cfg.APIKey, payload)
		if err != nil {
			return err
		}
		defer resp.Body.Close()

		var body chatResponseBody
		if err := json.NewDecoder(io.LimitReader(resp.Body, 16<<20)).Decode(&body); err != nil {
			return &port.AIError{Kind: port.AIErrProtocol, Message: "响应不是合法 JSON: " + err.Error()}
		}
		if body.Error != nil {
			return &port.AIError{Kind: port.AIErrBadRequest, Message: body.Error.Message}
		}
		if len(body.Choices) == 0 {
			return &port.AIError{Kind: port.AIErrProtocol, Message: "响应中没有 choices"}
		}
		out.Content = body.Choices[0].Message.Content
		if body.Usage != nil {
			out.PromptTokens = body.Usage.PromptTokens
			out.CompletionTokens = body.Usage.CompletionTokens
		}
		return nil
	})
	return out, err
}

// ── ChatStream ─────────────────────────────────────────────

// ChatStream 执行流式补全。
//
// 重试策略：只在「尚未吐出任何内容」时重试。一旦已经回调过 onDelta，
// 再重试会让前端看到重复文本，比直接报错更糟。
func (c *Client) ChatStream(ctx context.Context, cfg domain.AIConfig, req port.ChatRequest,
	onDelta func(delta string) error) (port.ChatResponse, error) {

	if err := requireChatConfig(cfg); err != nil {
		return port.ChatResponse{}, err
	}
	ctx, cancel := withDefaultTimeout(ctx, defaultStreamTimeout)
	defer cancel()

	payload := buildChatPayload(cfg, req, true)

	var resp *http.Response
	err := c.withRetry(ctx, func() error {
		r, err := c.postJSON(ctx, cfg.ChatEndpoint()+"/chat/completions", cfg.APIKey, payload)
		if err != nil {
			return err
		}
		resp = r
		return nil
	})
	if err != nil {
		return port.ChatResponse{}, err
	}
	defer resp.Body.Close()

	var sb strings.Builder
	var usage port.ChatResponse
	scanErr := scanSSE(resp.Body, func(data string) error {
		var chunk chatResponseBody
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			return &port.AIError{Kind: port.AIErrProtocol, Message: "流式分片解析失败: " + err.Error()}
		}
		// 部分服务在流中途以 error 对象报告失败（配额耗尽等）。
		if chunk.Error != nil {
			return &port.AIError{Kind: port.AIErrServer, Message: chunk.Error.Message}
		}
		if chunk.Usage != nil {
			usage = usageFrom(chunk.Usage)
		}
		if len(chunk.Choices) == 0 {
			return nil
		}
		delta := chunk.Choices[0].Delta.Content
		if delta == "" {
			return nil
		}
		sb.WriteString(delta)
		if onDelta != nil {
			return onDelta(delta)
		}
		return nil
	})

	out := port.ChatResponse{
		Content:          sb.String(),
		PromptTokens:     usage.PromptTokens,
		CompletionTokens: usage.CompletionTokens,
	}
	return out, scanErr
}

// ── Embed ──────────────────────────────────────────────────

// Embed 批量计算文本向量，返回顺序与输入一致。
func (c *Client) Embed(ctx context.Context, cfg domain.AIConfig, model string, inputs []string) ([][]float32, error) {
	if len(inputs) == 0 {
		return nil, nil
	}
	if model == "" {
		model = cfg.EmbeddingModel
	}
	url := cfg.EmbeddingEndpoint()
	if strings.TrimSpace(url) == "" || strings.TrimSpace(model) == "" {
		return nil, &port.AIError{Kind: port.AIErrBadRequest, Message: "未配置 embedding 地址或模型"}
	}

	out := make([][]float32, 0, len(inputs))
	for start := 0; start < len(inputs); start += embedBatchSize {
		end := start + embedBatchSize
		if end > len(inputs) {
			end = len(inputs)
		}
		batch, err := c.embedBatch(ctx, url, cfg.APIKey, model, inputs[start:end])
		if err != nil {
			return nil, err
		}
		out = append(out, batch...)
	}
	return out, nil
}

func (c *Client) embedBatch(ctx context.Context, url, apiKey, model string, inputs []string) ([][]float32, error) {
	ctx, cancel := withDefaultTimeout(ctx, defaultChatTimeout)
	defer cancel()

	payload := map[string]any{"model": model, "input": inputs}
	var out [][]float32

	err := c.withRetry(ctx, func() error {
		resp, err := c.postJSON(ctx, url+"/embeddings", apiKey, payload)
		if err != nil {
			return err
		}
		defer resp.Body.Close()

		var body embedResponseBody
		if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<20)).Decode(&body); err != nil {
			return &port.AIError{Kind: port.AIErrProtocol, Message: "embedding 响应不是合法 JSON: " + err.Error()}
		}
		if body.Error != nil {
			return &port.AIError{Kind: port.AIErrBadRequest, Message: body.Error.Message}
		}
		if len(body.Data) != len(inputs) {
			return &port.AIError{
				Kind:    port.AIErrProtocol,
				Message: fmt.Sprintf("embedding 返回 %d 条，期望 %d 条", len(body.Data), len(inputs)),
			}
		}
		// 按 index 排序，而不是信任返回顺序——有服务端并行处理后不保序。
		sort.Slice(body.Data, func(i, j int) bool { return body.Data[i].Index < body.Data[j].Index })
		vecs := make([][]float32, len(body.Data))
		for i, d := range body.Data {
			v := make([]float32, len(d.Embedding))
			for k, f := range d.Embedding {
				v[k] = float32(f)
			}
			vecs[i] = v
		}
		out = vecs
		return nil
	})
	return out, err
}

// ── 内部工具 ────────────────────────────────────────────────

func requireChatConfig(cfg domain.AIConfig) error {
	if !cfg.Configured() {
		return &port.AIError{Kind: port.AIErrBadRequest, Message: "未配置 AI 服务地址或模型"}
	}
	return nil
}

func buildChatPayload(cfg domain.AIConfig, req port.ChatRequest, stream bool) chatPayload {
	model := req.Model
	if model == "" {
		model = cfg.Model
	}
	temp := req.Temperature
	if temp == nil && cfg.Temperature > 0 {
		t := cfg.Temperature
		temp = &t
	}
	return chatPayload{
		Model:       model,
		Messages:    req.Messages,
		Temperature: temp,
		MaxTokens:   req.MaxTokens,
		Stream:      stream,
	}
}

func usageFrom(u *struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
}) port.ChatResponse {
	return port.ChatResponse{PromptTokens: u.PromptTokens, CompletionTokens: u.CompletionTokens}
}

// postJSON 发起 POST 请求并在非 2xx 时转换成结构化 AIError。
func (c *Client) postJSON(ctx context.Context, url, apiKey string, payload any) (*http.Response, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, &port.AIError{Kind: port.AIErrProtocol, Message: "请求序列化失败: " + err.Error()}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, &port.AIError{Kind: port.AIErrBadRequest, Message: "请求地址非法: " + err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	if c.ua != "" {
		req.Header.Set("User-Agent", c.ua)
	}
	if apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+apiKey)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, wrapTransportError(ctx, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		defer resp.Body.Close()
		msg := readErrorBody(resp.Body)
		return nil, classifyStatus(resp.StatusCode, msg)
	}
	return resp, nil
}

// readErrorBody 尽量从错误响应体里取出可读信息。
//
// 服务端可能返回 JSON({error:{message}}) 也可能是纯文本（网关页），
// 两种都要能给出人话，否则用户只能看到「HTTP 500」。
func readErrorBody(r io.Reader) string {
	raw, _ := io.ReadAll(io.LimitReader(r, maxErrorBody))
	text := strings.TrimSpace(string(raw))
	if text == "" {
		return "服务未返回错误详情"
	}
	var body struct {
		Error *apiErrorBody `json:"error"`
	}
	if json.Unmarshal(raw, &body) == nil && body.Error != nil && body.Error.Message != "" {
		return body.Error.Message
	}
	if len(text) > 300 {
		return text[:300] + "…"
	}
	return text
}

func classifyStatus(status int, msg string) *port.AIError {
	kind := port.AIErrServer
	switch {
	case status == http.StatusUnauthorized, status == http.StatusForbidden:
		kind = port.AIErrAuth
	case status == http.StatusTooManyRequests:
		kind = port.AIErrRate
	case status >= 400 && status < 500:
		kind = port.AIErrBadRequest
	}
	return &port.AIError{Kind: kind, Status: status, Message: msg}
}

// wrapTransportError 把底层传输错误归类为超时或网络故障。
func wrapTransportError(ctx context.Context, err error) error {
	// 用户主动取消要原样返回，上层靠 errors.Is(err, context.Canceled) 识别「点了停止」。
	if errors.Is(ctx.Err(), context.Canceled) {
		return context.Canceled
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return &port.AIError{Kind: port.AIErrTimeout, Message: "请求超时"}
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return &port.AIError{Kind: port.AIErrTimeout, Message: err.Error()}
	}
	return &port.AIError{Kind: port.AIErrNetwork, Message: err.Error()}
}

// withRetry 按指数退避重试可重试的错误。
func (c *Client) withRetry(ctx context.Context, fn func() error) error {
	var last error
	for attempt := 0; ; attempt++ {
		err := fn()
		if err == nil {
			return nil
		}
		last = err

		if ctx.Err() != nil {
			if errors.Is(ctx.Err(), context.Canceled) {
				return context.Canceled
			}
			return last
		}

		var aiErr *port.AIError
		if !errors.As(err, &aiErr) || !aiErr.Retryable() {
			return err
		}
		if attempt >= c.maxRetries {
			return err
		}

		delay := c.retryBase << attempt
		select {
		case <-time.After(delay):
		case <-ctx.Done():
			if errors.Is(ctx.Err(), context.Canceled) {
				return context.Canceled
			}
			return last
		}
	}
}

func withDefaultTimeout(ctx context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	if _, ok := ctx.Deadline(); ok {
		return context.WithCancel(ctx)
	}
	return context.WithTimeout(ctx, d)
}
