package domain

import (
	"strings"
	"time"
)

// SourceLogin 是一个书源（含漫画源）的登录信息。
//
// 为什么按 bookSourceUrl 而不是书源 id 存：
//   - 登录态是**跟着站点**走的，同一个站点换一份书源 JSON 应该继续有效；
//   - 反过来，书源地址改了（换域名）旧登录必然失效，按 URL 存正好自动作废。
//
// Form 是 loginUi 表单里用户填过的值（键名与 loginUi 的 name 一一对应）。
// 之所以要留存：原版就是这么做的——换号登录时不用重新敲一遍账号，
// 而且部分书源的 login 脚本会复用其中的字段（如设备号、区服）。
type SourceLogin struct {
	SourceURL string            // 书源唯一标识（bookSourceUrl）
	Form      map[string]string // 登录表单值
	Header    string            // 登录请求头 JSON（通常含 Cookie）
	UpdatedAt time.Time
}

// HasForm 报告是否保存过登录表单值。
func (l SourceLogin) HasForm() bool { return len(l.Form) > 0 }

// HasHeader 报告是否保存过登录请求头。
func (l SourceLogin) HasHeader() bool { return strings.TrimSpace(l.Header) != "" }

// IsEmpty 报告是否完全没有任何登录信息。
func (l SourceLogin) IsEmpty() bool { return !l.HasForm() && !l.HasHeader() }
