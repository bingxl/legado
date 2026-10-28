package webbook_test

// 录制/回放基础设施：让测试用真实书源跑真实规则，但不依赖网络。
//
//   - 回放（默认）：把所有 HTTP 响应替换为 testdata/fixtures/<case>/ 下的快照，
//     断言可以精确到书名、章节数、正文特征，CI 与断网环境都能跑。
//   - 录制：LEGADO_RECORD=1 go test ./pkg/webbook -run TestSourceManhuaReplay
//     会真实请求站点并把响应写回 testdata/fixtures/<case>/（引擎侧无任何改动，
//     拦截点就是 net.Client 的 http.Client）。

import (
	"bytes"
	"crypto/sha1"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/net"
	"github.com/legado/legado-go/pkg/source"
)

const fixturesRoot = "../../testdata/fixtures"

// vcrEntry 一条请求-响应对
type vcrEntry struct {
	Method      string   `json:"method"`
	URL         string   `json:"url"`
	BodySHA1    string   `json:"body_sha1,omitempty"`
	Status      int      `json:"status"`
	ContentType string   `json:"content_type,omitempty"`
	SetCookie   []string `json:"set_cookie,omitempty"`
	File        string   `json:"file"`
}

type vcrIndex struct {
	// RecordedAt 便于人工确认快照时间
	RecordedAt string     `json:"recorded_at,omitempty"`
	Entries    []vcrEntry `json:"entries"`
}

// vcr 实现 http.RoundTripper
type vcr struct {
	t      *testing.T
	dir    string
	record bool
	base   http.RoundTripper
	mu     sync.Mutex // 保护记录阶段的索引与文件编号（下载是并发抓取的）
	idx    *vcrIndex
	nameOf map[string]string // key -> file
}

// useVCR 安装录制/回放传输层，测试结束自动还原
func useVCR(t *testing.T, cas string) {
	t.Helper()
	dir := filepath.Join(fixturesRoot, cas)
	v := &vcr{
		t:      t,
		dir:    dir,
		record: os.Getenv("LEGADO_RECORD") == "1",
		base:   &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}},
		idx:    &vcrIndex{},
		nameOf: map[string]string{},
	}
	if v.record {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("创建快照目录失败: %v", err)
		}
		v.idx.RecordedAt = time.Now().Format(time.RFC3339)
	} else {
		b, err := os.ReadFile(filepath.Join(dir, "index.json"))
		if err != nil {
			t.Fatalf("读取快照失败（先执行 LEGADO_RECORD=1 go test 录制）: %v", err)
		}
		if err := json.Unmarshal(b, v.idx); err != nil {
			t.Fatalf("解析快照索引失败: %v", err)
		}
		for _, e := range v.idx.Entries {
			v.nameOf[v.key(e.Method, e.URL, e.BodySHA1)] = e.File
		}
	}
	old := net.Default().HTTPClient
	net.Default().HTTPClient = &http.Client{Transport: v, Timeout: 30 * time.Second}
	t.Cleanup(func() {
		net.Default().HTTPClient = old
		if v.record {
			v.save()
		}
	})
}

func (v *vcr) key(method, url, bodySHA string) string {
	return strings.ToUpper(method) + " " + url + " " + bodySHA
}

func (v *vcr) RoundTrip(req *http.Request) (*http.Response, error) {
	bodySHA := ""
	if req.Body != nil {
		b, err := io.ReadAll(req.Body)
		if err == nil {
			bodySHA = sha1Hex(b)
			req.Body = io.NopCloser(bytes.NewReader(b))
		}
	}
	k := v.key(req.Method, req.URL.String(), bodySHA)
	if v.record {
		return v.recordRoundTrip(req, k, bodySHA)
	}
	return v.replayRoundTrip(req, k)
}

func (v *vcr) recordRoundTrip(req *http.Request, key, bodySHA string) (*http.Response, error) {
	resp, err := v.base.RoundTrip(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	v.mu.Lock()
	n := len(v.idx.Entries) + 1
	name := fmt.Sprintf("%03d_%s_%s.%s", n, strings.ToLower(req.Method),
		slug(req.URL.Path), extOf(resp.Header.Get("Content-Type")))
	e := vcrEntry{
		Method:      strings.ToUpper(req.Method),
		URL:         req.URL.String(),
		BodySHA1:    bodySHA,
		Status:      resp.StatusCode,
		ContentType: resp.Header.Get("Content-Type"),
		SetCookie:   resp.Header.Values("Set-Cookie"),
		File:        name,
	}
	v.idx.Entries = append(v.idx.Entries, e)
	v.nameOf[key] = name
	v.mu.Unlock()
	if err := os.WriteFile(filepath.Join(v.dir, name), raw, 0o644); err != nil {
		return nil, err
	}
	v.t.Logf("录制 %s %s → %s (%d 字节)", e.Method, e.URL, name, len(raw))

	// 重建响应（body 已被读走）
	out := *resp
	out.Body = io.NopCloser(bytes.NewReader(raw))
	out.Request = req
	return &out, nil
}

func (v *vcr) replayRoundTrip(req *http.Request, key string) (*http.Response, error) {
	name, ok := v.nameOf[key]
	if !ok {
		v.t.Errorf("缺少快照: %s %s（重新录制请用 LEGADO_RECORD=1）", req.Method, req.URL)
		return &http.Response{
			Status:     "599 Fixture Missing",
			StatusCode: 599,
			Header:     http.Header{"Content-Type": []string{"text/plain; charset=utf-8"}},
			Body:       io.NopCloser(strings.NewReader("fixture missing: " + req.Method + " " + req.URL.String())),
			Request:    req,
		}, nil
	}
	raw, err := os.ReadFile(filepath.Join(v.dir, name))
	if err != nil {
		return nil, err
	}
	var entry vcrEntry
	for _, e := range v.idx.Entries {
		if e.File == name {
			entry = e
			break
		}
	}
	h := http.Header{}
	if entry.ContentType != "" {
		h.Set("Content-Type", entry.ContentType)
	}
	for _, c := range entry.SetCookie {
		h.Add("Set-Cookie", c)
	}
	status := entry.Status
	if status == 0 {
		status = 200
	}
	return &http.Response{
		Status:        strconv.Itoa(status) + " " + http.StatusText(status),
		StatusCode:    status,
		Header:        h,
		Body:          io.NopCloser(bytes.NewReader(raw)),
		ContentLength: int64(len(raw)),
		Request:       req,
	}, nil
}

func (v *vcr) save() {
	b, err := json.MarshalIndent(v.idx, "", "  ")
	if err != nil {
		v.t.Fatalf("序列化快照索引失败: %v", err)
	}
	if err := os.WriteFile(filepath.Join(v.dir, "index.json"), append(b, '\n'), 0o644); err != nil {
		v.t.Fatalf("写入快照索引失败: %v", err)
	}
	v.t.Logf("快照已写入 %s（共 %d 条）", v.dir, len(v.idx.Entries))
}

func sha1Hex(b []byte) string {
	h := sha1.Sum(b)
	return hex.EncodeToString(h[:])
}

func slug(p string) string {
	p = strings.Trim(p, "/")
	if p == "" {
		return "root"
	}
	var sb strings.Builder
	for _, r := range p {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			sb.WriteRune(r)
		case r == '/' || r == '.' || r == '-' || r == '_':
			sb.WriteByte('_')
		default:
			sb.WriteByte('x')
		}
	}
	s := sb.String()
	if len(s) > 40 {
		s = s[:40]
	}
	return s
}

func extOf(contentType string) string {
	switch {
	case strings.Contains(contentType, "json"):
		return "json"
	case strings.Contains(contentType, "html"):
		return "html"
	case strings.Contains(contentType, "javascript"):
		return "js"
	case strings.Contains(contentType, "image/jpeg"):
		return "jpg"
	case strings.Contains(contentType, "image/png"):
		return "png"
	case strings.Contains(contentType, "image/webp"):
		return "webp"
	}
	return "bin"
}

// loadSource 从 testdata/sources 里按文件与名称取书源
func loadSource(t *testing.T, file, name string) *model.BookSource {
	t.Helper()
	list, err := source.LoadFile(filepath.Join("../../testdata/sources", file))
	if err != nil {
		t.Fatalf("加载书源失败: %v", err)
	}
	for _, s := range list {
		if s.BookSourceName == name {
			return s
		}
	}
	t.Fatalf("书源 %q 不在 %s 中（共 %d 个）", name, file, len(list))
	return nil
}
