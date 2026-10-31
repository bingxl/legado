package app

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ReplaceRuleService 负责全局替换规则的增删改查与导入导出。
//
// 替换规则用于阅读前净化正文（去掉广告行、统一错字、清理空段落等），
// 与书源一样以 Raw 保存规则原文，避免字段映射随上游版本漂移。
type ReplaceRuleService struct {
	rules port.ReplaceRuleRepository
}

// NewReplaceRuleService 构造替换规则服务。
func NewReplaceRuleService(rules port.ReplaceRuleRepository) *ReplaceRuleService {
	return &ReplaceRuleService{rules: rules}
}

// List 列出全部替换规则。
func (s *ReplaceRuleService) List(ctx context.Context) ([]dto.ReplaceRuleView, error) {
	list, err := s.rules.List(ctx)
	if err != nil {
		return nil, err
	}
	return dto.NewReplaceRuleViews(list), nil
}

// Get 获取单条替换规则。
func (s *ReplaceRuleService) Get(ctx context.Context, id int64) (dto.ReplaceRuleView, error) {
	r, err := s.rules.Get(ctx, id)
	if err != nil {
		return dto.ReplaceRuleView{}, err
	}
	return dto.NewReplaceRuleView(r), nil
}

// Save 新增或更新替换规则；id 为 0 表示新增。
//
// raw 为空时兜一个空数组：规则原文是 JSON 数组，空串会让前端编辑器
// 拿到一个既非对象也非数组的字符串，解析必失败。
func (s *ReplaceRuleService) Save(ctx context.Context, id int64, name, group, raw string, enabled bool, order int) (dto.ReplaceRuleView, error) {
	if strings.TrimSpace(name) == "" {
		return dto.ReplaceRuleView{}, fmt.Errorf("%w: 规则名称不能为空", domain.ErrInvalidArgument)
	}
	if strings.TrimSpace(raw) == "" {
		raw = "[]"
	}

	if id == 0 {
		r := &domain.ReplaceRule{
			Name:    name,
			Group:   group,
			Enabled: enabled,
			Order:   order,
			Raw:     raw,
		}
		if err := s.rules.Create(ctx, r); err != nil {
			return dto.ReplaceRuleView{}, err
		}
		return dto.NewReplaceRuleView(r), nil
	}

	r, err := s.rules.Get(ctx, id)
	if err != nil {
		return dto.ReplaceRuleView{}, err
	}
	r.Name = name
	r.Group = group
	r.Enabled = enabled
	r.Order = order
	r.Raw = raw
	if err := s.rules.Update(ctx, r); err != nil {
		return dto.ReplaceRuleView{}, err
	}
	return dto.NewReplaceRuleView(r), nil
}

// Delete 删除替换规则。
func (s *ReplaceRuleService) Delete(ctx context.Context, id int64) error {
	return s.rules.Delete(ctx, id)
}

// SetEnabled 启停单条替换规则。
func (s *ReplaceRuleService) SetEnabled(ctx context.Context, id int64, enabled bool) error {
	r, err := s.rules.Get(ctx, id)
	if err != nil {
		return err
	}
	r.Enabled = enabled
	return s.rules.Update(ctx, r)
}

// Import 导入替换规则。
//
// 兼容两种写法：Legado 官方导出用 replaceRule 字段承载规则数组，
// 本应用导出用 raw。两者都收，避免用户从别处导来的文件全部失败。
//
// 去重按名称：替换规则没有稳定 URL 之类的天然主键，名称是唯一可依赖的标识。
// overwrite 为 true 时同名覆盖，否则跳过。
func (s *ReplaceRuleService) Import(ctx context.Context, data []byte, overwrite bool) (*dto.ReplaceRuleImportResult, error) {
	items, err := decodeRulePayload(data)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, fmt.Errorf("%w: 未解析到任何替换规则", domain.ErrParseFailed)
	}

	// 先建名称索引：逐条查库在导入几百条规则时会退化成 N 次查询。
	existing, err := s.rules.List(ctx)
	if err != nil {
		return nil, err
	}
	byName := make(map[string]*domain.ReplaceRule, len(existing))
	for _, r := range existing {
		byName[r.Name] = r
	}

	result := &dto.ReplaceRuleImportResult{
		Rules:    make([]dto.ReplaceRuleView, 0, len(items)),
		Failures: make([]dto.ImportRuleFailure, 0),
	}

	for _, item := range items {
		name := strings.TrimSpace(item.Name)
		if name == "" || item.Raw == "" {
			result.Failures = append(result.Failures, dto.ImportRuleFailure{
				Name: name, Reason: "缺少 name 或 replaceRule 字段",
			})
			continue
		}

		if old, ok := byName[name]; ok {
			if !overwrite {
				result.Skipped++
				result.Rules = append(result.Rules, dto.NewReplaceRuleView(old))
				continue
			}
			old.Group = firstNonEmpty(item.Group, old.Group)
			old.Raw = item.Raw
			old.Enabled = item.Enabled
			if item.Order != 0 {
				old.Order = item.Order
			}
			if err := s.rules.Update(ctx, old); err != nil {
				result.Failures = append(result.Failures, dto.ImportRuleFailure{Name: name, Reason: err.Error()})
				continue
			}
			result.Updated++
			result.Rules = append(result.Rules, dto.NewReplaceRuleView(old))
			continue
		}

		r := &domain.ReplaceRule{
			Name:    name,
			Group:   item.Group,
			Enabled: item.Enabled,
			Order:   item.Order,
			Raw:     item.Raw,
		}
		if err := s.rules.Create(ctx, r); err != nil {
			result.Failures = append(result.Failures, dto.ImportRuleFailure{Name: name, Reason: err.Error()})
			continue
		}
		byName[name] = r
		result.Imported++
		result.Rules = append(result.Rules, dto.NewReplaceRuleView(r))
	}
	return result, nil
}

// Export 导出替换规则为 Legado 兼容的 JSON 数组；ids 为空时导出全部。
func (s *ReplaceRuleService) Export(ctx context.Context, ids []int64) ([]byte, error) {
	var list []*domain.ReplaceRule
	var err error

	if len(ids) == 0 {
		list, err = s.rules.List(ctx)
		if err != nil {
			return nil, err
		}
	} else {
		list = make([]*domain.ReplaceRule, 0, len(ids))
		for _, id := range ids {
			r, err := s.rules.Get(ctx, id)
			if err != nil {
				// 单条缺失不应让整个导出失败：用户选中的是旧列表里的 ID。
				continue
			}
			list = append(list, r)
		}
	}

	out := make([]map[string]any, 0, len(list))
	for _, r := range list {
		out = append(out, map[string]any{
			"name":        r.Name,
			"group":       r.Group,
			"enabled":     r.Enabled,
			"sortOrder":   r.Order,
			"replaceRule": r.Raw,
		})
	}
	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("序列化替换规则失败: %w", err)
	}
	return data, nil
}

// rulePayloadItem 是导入时的一条中间结构，抹平 replaceRule / raw 两种写法。
type rulePayloadItem struct {
	Name    string
	Group   string
	Enabled bool
	Order   int
	Raw     string
}

// decodeRulePayload 解析导入文本，返回其中的规则条目。
//
// 与书源导入同理，兼容三种常见形态：JSON 数组、单个 JSON 对象、
// 以及换行分隔的多段文本（从聊天窗口里复制出来的往往是这种）。
func decodeRulePayload(data []byte) ([]rulePayloadItem, error) {
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return nil, fmt.Errorf("%w: 内容为空", domain.ErrParseFailed)
	}

	var rawItems []json.RawMessage
	if err := json.Unmarshal([]byte(trimmed), &rawItems); err == nil {
		return decodeRuleItems(rawItems)
	}

	var single json.RawMessage
	var probe map[string]any
	if err := json.Unmarshal([]byte(trimmed), &probe); err == nil {
		single = json.RawMessage(trimmed)
		return decodeRuleItems([]json.RawMessage{single})
	}

	// 不是合法 JSON：按行切分，逐行尝试解析（复制粘贴场景）。
	items := make([]rulePayloadItem, 0)
	for _, line := range strings.Split(trimmed, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parsed, err := decodeRuleItems([]json.RawMessage{json.RawMessage(line)})
		if err != nil {
			continue
		}
		items = append(items, parsed...)
	}
	if len(items) == 0 {
		return nil, fmt.Errorf("%w: 无法识别的替换规则格式", domain.ErrParseFailed)
	}
	return items, nil
}

func decodeRuleItems(raws []json.RawMessage) ([]rulePayloadItem, error) {
	items := make([]rulePayloadItem, 0, len(raws))
	for _, raw := range raws {
		var m map[string]any
		if err := json.Unmarshal(raw, &m); err != nil {
			continue
		}
		name := stringField(m, "name")
		// 规则原文：官方导出是 replaceRule，本应用导出也是它，
		// 但早期版本用过 raw，一并兼容。
		rules := stringField(m, "replaceRule")
		if rules == "" {
			rules = stringField(m, "raw")
		}
		if rules == "" {
			// 规则本身可能是对象/数组而非字符串，原样序列化回去。
			if v, ok := m["replaceRule"]; ok && v != nil {
				if b, err := json.Marshal(v); err == nil {
					rules = string(b)
				}
			}
		}
		enabled := true
		if v, ok := m["enabled"]; ok {
			enabled = boolField(v)
		}
		items = append(items, rulePayloadItem{
			Name:    name,
			Group:   stringField(m, "group"),
			Enabled: enabled,
			Order:   intField(m, "sortOrder"),
			Raw:     rules,
		})
	}
	return items, nil
}

// boolField 宽容解析布尔：导入文件里常见 1/0、"true"/"false" 混用。
func boolField(v any) bool {
	switch t := v.(type) {
	case bool:
		return t
	case float64:
		return t != 0
	case string:
		return t == "true" || t == "1"
	default:
		return false
	}
}

// intField 宽容解析整数。
func intField(m map[string]any, key string) int {
	v, ok := m[key]
	if !ok {
		return 0
	}
	switch t := v.(type) {
	case float64:
		return int(t)
	case string:
		var n int
		if _, err := fmt.Sscanf(t, "%d", &n); err == nil {
			return n
		}
	}
	return 0
}
