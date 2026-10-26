package util

import (
	"net"
	"net/url"
	"strings"

	"golang.org/x/net/publicsuffix"
)

// IsAbsUrl 是否为绝对地址（对齐 legado String.isAbsUrl）
func IsAbsUrl(s string) bool {
	ls := strings.ToLower(strings.TrimSpace(s))
	return strings.HasPrefix(ls, "http://") || strings.HasPrefix(ls, "https://")
}

// IsDataUrl 是否为 data: 协议
func IsDataUrl(s string) bool {
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(s)), "data:")
}

// GetBaseUrl 取 协议+域名，失败返回空串
func GetBaseUrl(u string) string {
	if u == "" {
		return ""
	}
	ls := strings.ToLower(u)
	idx := strings.Index(ls, "://")
	if idx < 0 {
		return ""
	}
	if !strings.HasPrefix(ls, "http://") && !strings.HasPrefix(ls, "https://") {
		return ""
	}
	rest := u[idx+3:]
	if j := strings.Index(rest, "/"); j >= 0 {
		return u[:idx+3+j]
	}
	return u
}

// GetAbsoluteURL 相对地址转绝对地址（对齐 NetworkUtils.getAbsoluteURL）
func GetAbsoluteURL(baseURL string, relativePath string) string {
	rel := strings.TrimSpace(relativePath)
	if baseURL == "" {
		return rel
	}
	if IsAbsUrl(rel) {
		return rel
	}
	if IsDataUrl(rel) {
		return rel
	}
	if strings.HasPrefix(strings.ToLower(rel), "javascript") {
		return ""
	}
	base := baseURL
	if i := strings.Index(base, ","); i >= 0 {
		base = base[:i]
	}
	return joinURL(base, rel)
}

// joinURL 按 java.net.URL(base, spec) 的语义拼接地址。
//
// 关键点：Java 的 URL 不会对路径做百分号转义，而 Go 的 url.URL.String()
// 会把 { } [ ] 等字符转义掉。书源里 `src="{{$.pic}}"` 这类规则串必须原样
// 保留交给上层替换，所以这里用字符串拼接 + 路径归一化，不走 ResolveReference。
func joinURL(base, rel string) string {
	bu, err := url.Parse(base)
	if err != nil || bu.Scheme == "" || bu.Host == "" {
		return rel
	}
	prefix := bu.Scheme + "://" + bu.Host
	withQuery := ""
	if bu.RawQuery != "" {
		withQuery = "?" + bu.RawQuery
	}
	switch {
	case rel == "":
		return prefix + bu.Path + withQuery
	case strings.HasPrefix(rel, "//"):
		return bu.Scheme + ":" + rel
	case strings.HasPrefix(rel, "/"):
		return prefix + normalizeURLPath(rel)
	case strings.HasPrefix(rel, "?"):
		return prefix + bu.Path + rel
	case strings.HasPrefix(rel, "#"):
		return prefix + bu.Path + withQuery + rel
	case hasScheme(rel):
		return rel
	}
	dir := bu.Path
	if i := strings.LastIndex(dir, "/"); i >= 0 {
		dir = dir[:i+1]
	} else {
		dir = "/"
	}
	return prefix + normalizeURLPath(dir+rel)
}

// hasScheme 判断是否以 "xxx:" 形式的协议开头
func hasScheme(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z':
		case c >= '0' && c <= '9', c == '+', c == '-', c == '.':
			if i == 0 {
				return false
			}
		case c == ':':
			return i > 0
		default:
			return false
		}
	}
	return false
}

// normalizeURLPath 归一化 . 与 .. 段（query/fragment 原样保留，不做转义）
func normalizeURLPath(p string) string {
	path, rest := p, ""
	if i := strings.IndexAny(p, "?#"); i >= 0 {
		path, rest = p[:i], p[i:]
	}
	if path == "" {
		return rest
	}
	trailing := strings.HasSuffix(path, "/")
	segs := strings.Split(path, "/")
	out := make([]string, 0, len(segs))
	for i, s := range segs {
		switch s {
		case ".":
			if i == len(segs)-1 {
				trailing = true
			}
		case "..":
			if len(out) > 1 {
				out = out[:len(out)-1]
			} else if len(out) == 0 {
				out = append(out, "")
			}
			if i == len(segs)-1 {
				trailing = true
			}
		default:
			out = append(out, s)
		}
	}
	res := strings.Join(out, "/")
	if trailing && !strings.HasSuffix(res, "/") {
		res += "/"
	}
	return res + rest
}

// GetSubDomain 获取可用于 cookie 作用域的二级域名
// http://www.biquge.com.cn => biquge.com.cn ; http://1.2.3.4 => 1.2.3.4
func GetSubDomain(u string) string {
	base := GetBaseUrl(u)
	if base == "" {
		return u
	}
	pu, err := url.Parse(base)
	if err != nil {
		return base
	}
	host := pu.Hostname()
	if host == "" {
		return base
	}
	if net.ParseIP(host) != nil {
		return host
	}
	if d, err := publicsuffix.EffectiveTLDPlusOne(host); err == nil && d != "" {
		return d
	}
	return host
}

// GetDomain 取完整主机名
func GetDomain(u string) string {
	base := GetBaseUrl(u)
	if base == "" {
		return u
	}
	pu, err := url.Parse(base)
	if err != nil {
		return base
	}
	return pu.Hostname()
}

// GetSuffix 从 URL 取扩展名
func GetSuffix(u string) string {
	p := u
	if i := strings.Index(p, "?"); i >= 0 {
		p = p[:i]
	}
	if i := strings.LastIndex(p, "."); i >= 0 {
		return p[i+1:]
	}
	return ""
}

// EncodedQuery 判断字符串是否已按 query 规则编码（对齐 NetworkUtils.encodedQuery）
func EncodedQuery(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if notNeedEncodingQuery(c) {
			continue
		}
		if c == '%' && i+2 < len(s) && isHex(s[i+1]) && isHex(s[i+2]) {
			i += 2
			continue
		}
		return false
	}
	return true
}

// EncodedForm 判断字符串是否已按 form 规则编码
func EncodedForm(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if notNeedEncodingForm(c) {
			continue
		}
		if c == '%' && i+2 < len(s) && isHex(s[i+1]) && isHex(s[i+2]) {
			i += 2
			continue
		}
		return false
	}
	return true
}

func notNeedEncodingQuery(c byte) bool {
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return true
	}
	return strings.IndexByte("!$&()*+,-./:;=?@[]^_`{|}~", c) >= 0
}

func notNeedEncodingForm(c byte) bool {
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return true
	}
	return strings.IndexByte("*-._", c) >= 0
}

func isHex(c byte) bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// SplitNotBlank 按分隔符切分并去掉空串
func SplitNotBlank(s string, seps ...string) []string {
	var out []string
	parts := []string{s}
	for _, sep := range seps {
		var next []string
		for _, p := range parts {
			next = append(next, strings.Split(p, sep)...)
		}
		parts = next
	}
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
