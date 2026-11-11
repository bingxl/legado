package domain

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

// SourceMeta 是从书源原始 JSON 中提炼出的「管理摘要」。
//
// 书源以 Raw JSON 持久化，管理界面却需要一批结构化状态来做筛选、排序与
// 徽标展示（是否有发现、是否配置了登录、响应时间、权重、书源类型……）。
// 这些字段全部在 Raw 里，为它们各开一列既冗余又容易与 Raw 脱节，
// 因此统一由 ParseSourceMeta 在读取时派生。
//
// 默认值必须与 Legado 原生实体一致（BookSource.kt）：
// enabledExplore 默认 true、enabledCookieJar 默认 true、respondTime 默认 180000。
// 用「先赋默认值再覆盖」的方式解析，JSON 里缺字段时不会得到 Go 的零值。
type SourceMeta struct {
	Type            int    // bookSourceType：0 文本 / 1 音频 / 2 图片 / 3 文件
	EnabledExplore  bool   // 是否在「发现」页展示
	HasExploreURL   bool   // 是否配置了 exploreUrl
	HasLoginURL     bool   // 是否配置了 loginUrl
	EnabledCookie   bool   // 是否自动保存 Cookie
	Weight          int    // 智能排序权重
	RespondTime     int64  // 响应时间（毫秒），用于「按响应时间」排序
	VariableComment string // 源变量说明
	Group           string // Raw 里的分组串（逗号分隔多分组）
	Name            string // Raw 里的书源名（兜底列名）
}

// sourceMetaProbe 用指针区分「JSON 里没有这个字段」与「显式为 false/0」。
type sourceMetaProbe struct {
	Type            *int    `json:"bookSourceType"`
	EnabledExplore  *bool   `json:"enabledExplore"`
	ExploreURL      *string `json:"exploreUrl"`
	LoginURL        *string `json:"loginUrl"`
	EnabledCookie   *bool   `json:"enabledCookieJar"`
	Weight          *int    `json:"weight"`
	RespondTime     *int64  `json:"respondTime"`
	VariableComment *string `json:"variableComment"`
	Group           *string `json:"bookSourceGroup"`
	Name            *string `json:"bookSourceName"`
}

// ParseSourceMeta 解析书源原始 JSON，得到管理摘要。
//
// 解析失败（空 Raw、非法 JSON）时返回与 Legado 默认书源等价的摘要，
// 由调用方决定是否把「无法解析」作为问题呈现——解析本身不报错，
// 因为列表页不能因为一条坏书源就整体失败。
func ParseSourceMeta(raw string) SourceMeta {
	meta := SourceMeta{EnabledExplore: true, EnabledCookie: true, RespondTime: 180000}
	if strings.TrimSpace(raw) == "" {
		return meta
	}
	var probe sourceMetaProbe
	if err := json.Unmarshal([]byte(raw), &probe); err != nil {
		return meta
	}
	if probe.Type != nil {
		meta.Type = *probe.Type
	}
	if probe.EnabledExplore != nil {
		meta.EnabledExplore = *probe.EnabledExplore
	}
	if probe.ExploreURL != nil {
		meta.HasExploreURL = strings.TrimSpace(*probe.ExploreURL) != ""
	}
	if probe.LoginURL != nil {
		meta.HasLoginURL = strings.TrimSpace(*probe.LoginURL) != ""
	}
	if probe.EnabledCookie != nil {
		meta.EnabledCookie = *probe.EnabledCookie
	}
	if probe.Weight != nil {
		meta.Weight = *probe.Weight
	}
	if probe.RespondTime != nil && *probe.RespondTime > 0 {
		meta.RespondTime = *probe.RespondTime
	}
	if probe.VariableComment != nil {
		meta.VariableComment = *probe.VariableComment
	}
	if probe.Group != nil {
		meta.Group = *probe.Group
	}
	if probe.Name != nil {
		meta.Name = *probe.Name
	}
	return meta
}

// Meta 返回书源的管理摘要。
func (s *BookSource) Meta() SourceMeta {
	return ParseSourceMeta(s.Raw)
}

// PatchSourceRaw 修改书源原始 JSON 中的若干顶层字段，返回新的 JSON 文本。
//
// 为什么不用「反序列化到 map[string]any 再回写」：Go 默认把 JSON 数字解成
// float64，respondTime 这类毫秒时间戳会被写成 `1.8e+06`，Legado 端解析回
// long 时能过，但人工看 JSON 时全是科学计数法。这里用 UseNumber 保留数字原文。
//
// 未知字段原样保留（只增改 patch 里的键），因此书源里本端不认识的
// 上游新字段不会在编辑一次分组后就丢失。
func PatchSourceRaw(raw string, patch map[string]any) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		// 没有任何原始规则时，退化为只含 patch 的对象；
		// 缺 bookSourceUrl 的情形由调用方补（见 app.ensureSourceURL）。
		b, err := json.Marshal(patch)
		if err != nil {
			return raw, err
		}
		return string(b), nil
	}

	dec := json.NewDecoder(bytes.NewReader([]byte(trimmed)))
	dec.UseNumber()
	var obj map[string]any
	if err := dec.Decode(&obj); err != nil {
		return raw, fmt.Errorf("%w: 书源 JSON 解析失败: %v", ErrParseFailed, err)
	}
	for k, v := range patch {
		obj[k] = v
	}
	out, err := json.Marshal(obj)
	if err != nil {
		return raw, fmt.Errorf("%w: 书源 JSON 序列化失败: %v", ErrParseFailed, err)
	}
	return string(out), nil
}

// SplitGroups 拆分 Legado 的分组串。
//
// 书源的 bookSourceGroup 允许用逗号写多个分组（如 "玄幻,完本"），
// 空项与重复项在这里一并清掉——界面上的分组菜单必须是去重后的集合，
// 否则「玄幻」会出现两次。
func SplitGroups(group string) []string {
	parts := strings.Split(group, ",")
	out := make([]string, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for _, p := range parts {
		g := strings.TrimSpace(p)
		if g == "" {
			continue
		}
		if _, ok := seen[g]; ok {
			continue
		}
		seen[g] = struct{}{}
		out = append(out, g)
	}
	return out
}

// JoinGroups 把分组列表还原成 Legado 的逗号分隔写法。
func JoinGroups(groups []string) string { return strings.Join(groups, ",") }

// HasGroup 判断分组串里是否包含指定分组。
func HasGroup(group, target string) bool {
	for _, g := range SplitGroups(group) {
		if g == target {
			return true
		}
	}
	return false
}

// AddGroup 在分组串里加入一个分组（已存在则不变）。
func AddGroup(group, add string) string {
	add = strings.TrimSpace(add)
	if add == "" || HasGroup(group, add) {
		return group
	}
	groups := SplitGroups(group)
	groups = append(groups, add)
	return JoinGroups(groups)
}

// RemoveGroup 从分组串里移除一个分组。
func RemoveGroup(group, remove string) string {
	groups := SplitGroups(group)
	out := make([]string, 0, len(groups))
	for _, g := range groups {
		if g != remove {
			out = append(out, g)
		}
	}
	return JoinGroups(out)
}

// RenameGroup 把分组串里的 oldName 换成 newName，newName 为空表示删掉这个分组。
//
// 原位替换而不是「先删后加」：多分组时先删后加会把分组挪到末尾，
// 用户改个名字却发现分组顺序变了。重名会去重（A,B 改 A→B 得到 B）。
func RenameGroup(group, oldName, newName string) string {
	oldName = strings.TrimSpace(oldName)
	newName = strings.TrimSpace(newName)
	if oldName == "" {
		return group
	}
	groups := SplitGroups(group)
	out := make([]string, 0, len(groups))
	seen := make(map[string]struct{}, len(groups))
	for _, g := range groups {
		if g == oldName {
			g = newName
			if g == "" {
				continue
			}
		}
		if _, dup := seen[g]; dup {
			continue
		}
		seen[g] = struct{}{}
		out = append(out, g)
	}
	return JoinGroups(out)
}

// SourceGroup 是一个分组及其书源数量，供分组管理界面展示。
type SourceGroup struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
}
