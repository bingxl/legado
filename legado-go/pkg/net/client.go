package net

import (
	"bytes"
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

// Do 执行请求（含 cookie 注入、编码识别、重试）
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

	// 1. 注入已保存 cookie
	domain := opt.CookieDomain
	if domain == "" {
		domain = util.GetSubDomain(opt.URL)
	}
	headers := map[string]string{}
	maps.Copy(headers, opt.Headers)
	if _, ok := headers["User-Agent"]; !ok {
		headers["User-Agent"] = c.UserAgent
	}
	stored := store.Default().GetCookie(domain)
	if stored != "" {
		headers["Cookie"] = store.MergeCookies(headers["Cookie"], stored)
	}
	delete(headers, CookieJarHeader)

	// 2. 构造 body
	var bodyReader io.Reader
	if (method == http.MethodPost || method == http.MethodPut || method == http.MethodPatch) && opt.Body != "" {
		bodyReader = bytes.NewReader([]byte(opt.Body))
		if opt.ContentType != "" {
			headers["Content-Type"] = opt.ContentType
		} else if _, ok := headers["Content-Type"]; !ok {
			if looksJSON(opt.Body) {
				headers["Content-Type"] = "application/json;charset=UTF-8"
			} else {
				headers["Content-Type"] = "application/x-www-form-urlencoded"
			}
		}
	}

	retries := max(opt.Retry, 0)
	var lastErr error
	for i := 0; i <= retries; i++ {
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
		// 3. 回写 cookie
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
		return &Response{
			URL:        finalURL,
			StatusCode: resp.StatusCode,
			Headers:    hdr,
			Body:       util.DecodeBytes(raw, cs),
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
