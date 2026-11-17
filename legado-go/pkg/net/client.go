package net

import (
	"crypto/tls"
	"io"
	"maps"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/legado/legado-go/pkg/store"
	"github.com/legado/legado-go/pkg/util"
)

const (
	// CookieJarHeader 与 legado 一致的 CookieJar 标记头
	CookieJarHeader = "CookieJar"
	// DefaultUserAgent 默认 UA
	DefaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

// Response 统一响应结构（对齐 StrResponse）
type Response struct {
	URL        string // 最终 URL（重定向后）
	RuleURL    string // 规则 URL
	StatusCode int
	Headers    map[string]string
	Body       string
	Bytes      []byte
	IsRedirect bool
}

// Options 请求参数
type Options struct {
	URL         string
	Method      string
	Headers     map[string]string
	Body        string // 原始 body（form 串 / json 串 / 任意文本）
	ContentType string // 显式指定则原样发送
	Charset     string
	Retry       int
	Timeout     time.Duration
	Proxy       string
	// SaveCookie 是否把响应 cookie 回写 CookieStore
	SaveCookie bool
	// CookieDomain 覆盖 cookie 作用域
	CookieDomain string
	// NoChallenge 跳过反爬人工验证。
	//
	// 验证通过后的"重新取正文"必须置 true：否则一旦凭证还没生效，
	// 引擎会再弹一次验证窗口，用户会看到窗口反复弹出。
	NoChallenge bool
}

// Client HTTP 客户端
type Client struct {
	HTTPClient *http.Client
	UserAgent  string
	// 全局默认超时
	Timeout time.Duration
}

var defaultClient = &Client{
	HTTPClient: &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	},
	UserAgent: DefaultUserAgent,
	Timeout:   30 * time.Second,
}

// Default 全局客户端
func Default() *Client { return defaultClient }

func (c *Client) timeout(o *Options) time.Duration {
	if o.Timeout > 0 {
		return o.Timeout
	}
	if c.Timeout > 0 {
		return c.Timeout
	}
	return 30 * time.Second
}

// Do 执行请求（含 cookie 注入、编码识别、重试与反爬人工验证）
func (c *Client) Do(opt Options) (*Response, error) {
	method := strings.ToUpper(opt.Method)
	if method == "" {
		method = http.MethodGet
	}
	timeout := c.timeout(&opt)
	hc := c.HTTPClient
	if opt.Proxy != "" || c.HTTPClient.Timeout != timeout {
		hc = &http.Client{Timeout: timeout, Transport: newTransport(opt.Proxy)}
	}

	domain := opt.CookieDomain
	if domain == "" {
		domain = util.GetSubDomain(opt.URL)
	}

	// 基础请求头：不含 Cookie——每轮都要按最新的 CookieStore 重新拼，
	// 否则验证拿到 cf_clearance 之后的重试仍然带的是旧 Cookie。
	baseHeaders := map[string]string{}
	maps.Copy(baseHeaders, opt.Headers)
	delete(baseHeaders, CookieJarHeader)

	// UA 决策：域名上存在验证覆盖值时一律用覆盖值。
	//
	// cf_clearance 与 UA 绑定，书源自己配的 UA 如果和通过验证时浏览器的 UA
	// 不一致，Cloudflare 会认为凭证不属于这个客户端，验证过了照样 403。
	uaKey := ""
	for k := range baseHeaders {
		if strings.EqualFold(k, "User-Agent") {
			uaKey = k
			break
		}
	}
	overridden := UserAgentOverride(domain)
	switch {
	case uaKey != "" && overridden != "":
		baseHeaders[uaKey] = overridden
	case uaKey == "":
		ua := c.UserAgent
		if overridden != "" {
			ua = overridden
		}
		baseHeaders["User-Agent"] = ua
	}

	// 请求体只在这里定格一次：重试与换凭证重试都要重新造 reader，
	// 复用同一个 reader 会让第二轮读到已经消费完的 body（POST 书源变空 body）。
	bodyStr := ""
	if (method == http.MethodPost || method == http.MethodPut || method == http.MethodPatch) && opt.Body != "" {
		bodyStr = opt.Body
		if opt.ContentType != "" {
			baseHeaders["Content-Type"] = opt.ContentType
		} else if _, ok := baseHeaders["Content-Type"]; !ok {
			if looksJSON(opt.Body) {
				baseHeaders["Content-Type"] = "application/json;charset=UTF-8"
			} else {
				baseHeaders["Content-Type"] = "application/x-www-form-urlencoded"
			}
		}
	}

	retries := max(opt.Retry, 0)
	var lastErr error
	challengeTried := false
	// pendingBody 是宿主回填的"浏览器渲染结果"。凭证没生效时用它兜底：
	// 这类站点不用 cf_clearance（自建验证/只有 __cf_bm），重试必然还是挑战页。
	var pendingBody string
	for i := 0; i <= retries; i++ {
		headers := map[string]string{}
		maps.Copy(headers, baseHeaders)
		if stored := store.Default().GetCookie(domain); stored != "" {
			headers["Cookie"] = store.MergeCookies(headers["Cookie"], stored)
		}

		var bodyReader io.Reader
		if bodyStr != "" {
			bodyReader = strings.NewReader(bodyStr)
		}
		req, err := http.NewRequest(method, opt.URL, bodyReader)
		if err != nil {
			return nil, err
		}
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		resp, err := hc.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		if opt.SaveCookie {
			store.Default().SaveResponseCookie(resp)
		}
		raw, err := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if err != nil {
			lastErr = err
			continue
		}
		ct := resp.Header.Get("Content-Type")
		cs := opt.Charset
		if cs == "" {
			cs = util.DetectCharset(ct, raw)
		}
		finalURL := opt.URL
		if resp.Request != nil && resp.Request.URL != nil {
			finalURL = resp.Request.URL.String()
		}
		isRedirect := false
		if resp.Request != nil && resp.Request.Response != nil {
			isRedirect = true
		}
		hdr := map[string]string{}
		for k := range resp.Header {
			hdr[k] = resp.Header.Get(k)
		}
		body := util.DecodeBytes(raw, cs)

		// 上一轮宿主回填了浏览器渲染结果、但凭证没让上游放行：用它兜底。
		// 放在验证块之前，避免第二次弹窗（challengeTried 已为 true，也不会弹）。
		if pendingBody != "" {
			if ok, _ := IsCloudflareChallenge(resp.StatusCode, hdr, body); ok {
				return &Response{
					URL:        finalURL,
					StatusCode: http.StatusOK,
					Headers:    hdr,
					Body:       pendingBody,
					Bytes:      []byte(pendingBody),
					IsRedirect: isRedirect,
				}, nil
			}
			pendingBody = ""
		}

		// 反爬拦截：交给宿主完成人工验证，然后带着新凭证重试一次。
		//
		// 只试一次——宿主放弃或凭证仍然无效时原样返回本次响应，
		// 不能陷入"弹窗 → 重试 → 再弹窗"的死循环。
		if !challengeTried && !opt.NoChallenge {
			if ok, reason := IsCloudflareChallenge(resp.StatusCode, hdr, body); ok {
				res, solved := RunChallenge(Challenge{
					URL:        opt.URL,
					Domain:     domain,
					StatusCode: resp.StatusCode,
					Reason:     reason,
				})
				if solved {
					challengeTried = true
					// 宿主只拿到页面内容、没有 Cookie：直接当响应体用。
					// 对应原版 startBrowserAwait(refetchAfterSuccess = false)。
					if res.Body != "" {
						pendingBody = res.Body
					}
					if res.Cookie == "" {
						return &Response{
							URL:        finalURL,
							StatusCode: http.StatusOK,
							Headers:    hdr,
							Body:       res.Body,
							Bytes:      []byte(res.Body),
							IsRedirect: isRedirect,
						}, nil
					}
					i-- // 验证重试不占用网络重试次数
					// 浏览器 UA 必须立刻生效：baseHeaders 是循环外定格的，
					// 只写进覆盖表对"当前这次重试"不起作用。
					if res.UserAgent != "" {
						if uaKey == "" {
							uaKey = "User-Agent"
						}
						baseHeaders[uaKey] = res.UserAgent
					}
					continue
				}
			}
		}

		return &Response{
			URL:        finalURL,
			StatusCode: resp.StatusCode,
			Headers:    hdr,
			Body:       body,
			Bytes:      raw,
			IsRedirect: isRedirect,
		}, nil
	}
	return nil, lastErr
}

// GetBytes 下载二进制
func (c *Client) GetBytes(u string, headers map[string]string, saveCookie bool) ([]byte, error) {
	resp, err := c.Do(Options{
		URL:        u,
		Method:     http.MethodGet,
		Headers:    headers,
		SaveCookie: saveCookie,
	})
	if err != nil {
		return nil, err
	}
	return resp.Bytes, nil
}

func looksJSON(s string) bool {
	t := strings.TrimSpace(s)
	return (strings.HasPrefix(t, "{") && strings.HasSuffix(t, "}")) ||
		(strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]"))
}

func newTransport(proxy string) *http.Transport {
	tr := &http.Transport{
		TLSClientConfig:       &tls.Config{InsecureSkipVerify: true},
		MaxIdleConns:          100,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	}
	if proxy != "" {
		if pu, err := url.Parse(proxy); err == nil {
			tr.Proxy = http.ProxyURL(pu)
		}
	}
	return tr
}
