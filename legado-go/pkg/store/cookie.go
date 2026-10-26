package store

import (
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"

	"github.com/legado/legado-go/pkg/util"
)

// CookieStore 对齐 legado help/http/CookieStore.kt + CookieManager.kt
// - 持久化 cookie：按二级域名保存，可落盘
// - 会话 cookie：仅内存，进程退出失效
type CookieStore struct {
	mu       sync.RWMutex
	domain   map[string]string // 持久化 cookie
	session  map[string]string // 会话期 cookie
	filePath string
}

var defaultStore = NewCookieStore()

// Default 全局 cookie 存储
func Default() *CookieStore { return defaultStore }

func NewCookieStore() *CookieStore {
	return &CookieStore{domain: map[string]string{}, session: map[string]string{}}
}

// SetCookieFile 指定持久化文件路径
func (c *CookieStore) SetCookieFile(path string) {
	c.mu.Lock()
	c.filePath = path
	c.mu.Unlock()
	_ = c.Load()
}

// SetCookie 覆盖保存某域名的 cookie
func (c *CookieStore) SetCookie(url, cookie string) {
	c.mu.Lock()
	c.domain[util.GetSubDomain(url)] = cookie
	path := c.filePath
	c.mu.Unlock()
	if path != "" {
		_ = c.Save()
	}
}

// ReplaceCookie 合并保存（新值覆盖同名 key）
func (c *CookieStore) ReplaceCookie(url, cookie string) {
	if strings.TrimSpace(url) == "" || strings.TrimSpace(cookie) == "" {
		return
	}
	d := util.GetSubDomain(url)
	c.mu.Lock()
	old := c.domain[d]
	if strings.TrimSpace(old) == "" {
		c.domain[d] = cookie
	} else {
		m := CookieToMap(old)
		for k, v := range CookieToMap(cookie) {
			m[k] = v
		}
		if s := MapToCookie(m); s != "" {
			c.domain[d] = s
		}
	}
	c.mu.Unlock()
	if c.filePath != "" {
		_ = c.Save()
	}
}

// GetCookie 获取域名下全部 cookie（持久 + 会话合并），超过 4096 字节时随机丢弃
func (c *CookieStore) GetCookie(url string) string {
	d := util.GetSubDomain(url)
	c.mu.RLock()
	ck := c.domain[d]
	sc := c.session[d]
	c.mu.RUnlock()
	m := MergeMaps(CookieToMap(ck), CookieToMap(sc))
	s := MapToCookie(m)
	for len(s) > 4096 && len(m) > 0 {
		// 随机移除一个 key（与 legado 行为一致）
		for k := range m {
			delete(m, k)
			break
		}
		c.mu.Lock()
		mm := CookieToMap(c.domain[d])
		for k := range m {
			if _, ok := mm[k]; !ok {
				delete(mm, k)
			}
		}
		// 用剩余集合重建
		newM := map[string]string{}
		for k := range m {
			if v, ok := mm[k]; ok {
				newM[k] = v
			}
		}
		c.domain[d] = MapToCookie(newM)
		c.mu.Unlock()
		s = MapToCookie(m)
	}
	return s
}

// GetKey 取单个 cookie 值
func (c *CookieStore) GetKey(url, key string) string {
	m := CookieToMap(c.GetCookie(url))
	return m[key]
}

// RemoveCookie 删除域名 cookie
func (c *CookieStore) RemoveCookie(url string) {
	d := util.GetSubDomain(url)
	c.mu.Lock()
	delete(c.domain, d)
	delete(c.session, d)
	c.mu.Unlock()
	if c.filePath != "" {
		_ = c.Save()
	}
}

// RemoveKey 删除单个 cookie
func (c *CookieStore) RemoveKey(url, key string) {
	d := util.GetSubDomain(url)
	c.mu.Lock()
	m := CookieToMap(c.domain[d])
	delete(m, key)
	c.domain[d] = MapToCookie(m)
	sm := CookieToMap(c.session[d])
	delete(sm, key)
	c.session[d] = MapToCookie(sm)
	c.mu.Unlock()
}

// GetSessionCookie 取会话 cookie
func (c *CookieStore) GetSessionCookie(domain string) string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.session[domain]
}

// UpdateSessionCookie 合并写入会话 cookie
func (c *CookieStore) UpdateSessionCookie(domain, cookies string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	old := c.session[domain]
	if old == "" {
		c.session[domain] = cookies
		return
	}
	c.session[domain] = MapToCookie(MergeMaps(CookieToMap(old), CookieToMap(cookies)))
}

// SaveResponseCookie 从 HTTP 响应中抽取并保存 cookie（对齐 CookieManager.saveResponse）
func (c *CookieStore) SaveResponseCookie(resp *http.Response) {
	if resp == nil {
		return
	}
	domain := util.GetSubDomain(resp.Request.URL.String())
	var persistPairs, sessionPairs []string
	for _, ck := range resp.Cookies() {
		pair := ck.Name + "=" + ck.Value
		if ck.MaxAge == 0 && ck.Expires.IsZero() {
			sessionPairs = append(sessionPairs, pair)
		} else {
			persistPairs = append(persistPairs, pair)
		}
	}
	if len(sessionPairs) > 0 {
		c.UpdateSessionCookie(domain, strings.Join(sessionPairs, "; "))
	}
	if len(persistPairs) > 0 {
		c.ReplaceCookie(domain, strings.Join(persistPairs, "; "))
	}
}

// CookieToMap "a=1; b=2" -> map
func CookieToMap(cookie string) map[string]string {
	m := map[string]string{}
	if strings.TrimSpace(cookie) == "" {
		return m
	}
	for _, pair := range strings.Split(cookie, ";") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		kv := strings.SplitN(pair, "=", 2)
		if len(kv) < 2 {
			continue
		}
		key := strings.TrimSpace(kv[0])
		val := strings.TrimSpace(kv[1])
		if val != "" || val == "null" {
			m[key] = val
		}
	}
	return m
}

// MapToCookie map -> "a=1; b=2"（key 排序保证稳定）
func MapToCookie(m map[string]string) string {
	if len(m) == 0 {
		return ""
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var sb strings.Builder
	for i, k := range keys {
		if i > 0 {
			sb.WriteString("; ")
		}
		sb.WriteString(k)
		sb.WriteString("=")
		sb.WriteString(m[k])
	}
	return sb.String()
}

// MergeMaps 合并多个 cookie map，后者覆盖前者
func MergeMaps(ms ...map[string]string) map[string]string {
	out := map[string]string{}
	for _, m := range ms {
		for k, v := range m {
			out[k] = v
		}
	}
	return out
}

// MergeCookies 合并多个 cookie 串
func MergeCookies(cs ...string) string {
	ms := make([]map[string]string, 0, len(cs))
	for _, c := range cs {
		ms = append(ms, CookieToMap(c))
	}
	return MapToCookie(MergeMaps(ms...))
}

// —— 持久化 ——

type cookieFile struct {
	Domain map[string]string `json:"domain"`
}

func (c *CookieStore) Save() error {
	if c.filePath == "" {
		return nil
	}
	c.mu.RLock()
	cp := make(map[string]string, len(c.domain))
	for k, v := range c.domain {
		cp[k] = v
	}
	c.mu.RUnlock()
	// 没有任何 cookie 且文件还不存在时不落盘，避免每条命令都生成空文件
	if len(cp) == 0 {
		if _, err := os.Stat(c.filePath); os.IsNotExist(err) {
			return nil
		}
	}
	return writeJSONFile(c.filePath, cookieFile{Domain: cp})
}

func (c *CookieStore) Load() error {
	if c.filePath == "" {
		return nil
	}
	var cf cookieFile
	if err := readJSONFile(c.filePath, &cf); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.domain == nil {
		c.domain = map[string]string{}
	}
	for k, v := range cf.Domain {
		c.domain[k] = v
	}
	return nil
}
