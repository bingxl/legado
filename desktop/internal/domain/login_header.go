package domain

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// ParseLoginHeader 解析用户粘贴的「登录头」文本。
//
// 原版（BaseSource.putLoginHeader）只接受 JSON，但桌面端用户是从浏览器
// DevTools 里复制出来的，形态五花八门，这里刻意宽容：
//
//	{"Cookie":"sid=1","User-Agent":"..."}   ← JSON
//	Cookie: sid=1                            ← 单行请求头
//	sid=1; token=2                           ← 裸 Cookie
//
// 返回的键统一成标准写法（Cookie / User-Agent），下游只认一份。
func ParseLoginHeader(text string) (map[string]string, error) {
	s := strings.TrimSpace(text)
	if s == "" {
		return nil, fmt.Errorf("%w: 内容为空", ErrInvalidArgument)
	}
	if strings.HasPrefix(s, "{") {
		var raw map[string]string
		if err := json.Unmarshal([]byte(s), &raw); err != nil {
			return nil, fmt.Errorf("%w: JSON 格式不正确: %s", ErrInvalidArgument, err.Error())
		}
		out := make(map[string]string, len(raw))
		for k, v := range raw {
			out[canonicalHeaderKey(k)] = v
		}
		return out, nil
	}

	out := map[string]string{}
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if line == "" {
			continue
		}
		// 只在「没有 = 的冒号行」上认头名，避免把 Cookie 值里的冒号当分隔符。
		if k, v, ok := strings.Cut(line, ":"); ok && !strings.Contains(k, "=") {
			switch strings.ToLower(strings.TrimSpace(k)) {
			case "cookie":
				out["Cookie"] = strings.TrimSpace(v)
			case "user-agent":
				out["User-Agent"] = strings.TrimSpace(v)
			}
		}
	}
	if len(out) == 0 {
		// 既不是 JSON 也没有头行：整段当成裸 Cookie 串。
		out["Cookie"] = s
	}
	return out, nil
}

// canonicalHeaderKey 把常见的头名归一到标准写法。
func canonicalHeaderKey(k string) string {
	switch strings.ToLower(strings.TrimSpace(k)) {
	case "cookie":
		return "Cookie"
	case "user-agent", "useragent":
		return "User-Agent"
	}
	return k
}

// LoginHeaderJSON 把解析后的登录头重新序列化成规范 JSON。
//
// 存规范形态的好处：查看界面显示稳定、脚本里 `source.getLoginHeader()` 之类
// 的取值不会因为用户当初粘的是裸 Cookie 而拿到另一套结构。
func LoginHeaderJSON(m map[string]string) string {
	if len(m) == 0 {
		return ""
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteByte('{')
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		kb, _ := json.Marshal(k)
		vb, _ := json.Marshal(m[k])
		b.Write(kb)
		b.WriteByte(':')
		b.Write(vb)
	}
	b.WriteByte('}')
	return b.String()
}

// CookieFromLoginHeader 从登录头里取出 Cookie 值（没有则返回空串）。
func CookieFromLoginHeader(m map[string]string) string {
	for k, v := range m {
		if strings.EqualFold(k, "Cookie") {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// MaskCookie 把 Cookie 变成可展示的掩码。
//
// 登录态等于账号，界面不该把完整 Cookie 打在屏幕上（截图/录屏就泄露了）。
// 保留第一项的键名与前几位，够用户确认「登的是哪个号」。
func MaskCookie(cookie string) string {
	s := strings.TrimSpace(cookie)
	if s == "" {
		return ""
	}
	pairs := strings.Split(s, ";")
	first := strings.TrimSpace(pairs[0])
	name, value, ok := strings.Cut(first, "=")
	if !ok {
		return fmt.Sprintf("（%d 项，共 %d 字节）", len(pairs), len(s))
	}
	shown := value
	if len(shown) > 4 {
		shown = shown[:4] + "…"
	}
	if len(pairs) == 1 {
		return fmt.Sprintf("%s=%s", name, shown)
	}
	return fmt.Sprintf("%s=%s（共 %d 项，%d 字节）", name, shown, len(pairs), len(s))
}
