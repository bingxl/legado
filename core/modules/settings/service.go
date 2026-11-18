package settings

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/legado/core/domain"
	"github.com/legado/core/port"
)

// Service 是配置读写与校验的唯一入口。
//
// 校验放在这一层而不是前端：桌面、安卓、CLI 三个入口写的是同一份库，
// 前端各自夹一遍区间迟早会漂。这里退化成「Schema 说什么就怎么夹」，
// 前端只负责画控件。
type Service struct {
	store  port.SettingsStore
	schema Schema
	// index 是 key → Item 的索引；构造时算一次，之后只读。
	index map[string]Item
}

// NewService 构造服务。store 为 nil 时直接 panic —— 配置模块没有存储
// 就什么也做不了，早失败比运行时到处判空好。
func NewService(store port.SettingsStore) *Service {
	if store == nil {
		panic("settings: store 不能为空")
	}
	sc := DefaultSchema()
	idx, err := sc.index()
	if err != nil {
		// Schema 是编译期常量表，重复 key 属于写错了代码，不是运行时状况。
		panic("settings: " + err.Error())
	}
	return &Service{store: store, schema: sc, index: idx}
}

// Schema 返回设置页声明。
func (s *Service) Schema() Schema { return s.schema }

// Values 返回全部设置项的**有效值**（已落库的覆盖默认值）。
//
// 返回 string 而不是 any：前端要显示"当前值"，而下拉项/滑块的当前值
// 本质上是一段可以回填给 input 的文本；类型信息在 Schema 的 Kind 里。
func (s *Service) Values(ctx context.Context) (map[string]string, error) {
	out := make(map[string]string, len(s.index))
	for key, it := range s.index {
		raw, err := s.store.Get(ctx, key)
		if err != nil {
			// 没存过（ErrNotFound）就用默认值；库损坏等异常也退回默认值——
			// 设置页读不出来时最该保证的是"其它功能不受影响"。
			out[key] = defaultString(it)
			continue
		}
		// 库里可能是旧版本写的非法值（比如选项被删了），读出来同样要归一化，
		// 否则前端会显示一个下拉里不存在的选中项。
		if normalized, err := normalize(it, raw); err == nil {
			out[key] = normalized
		} else {
			out[key] = defaultString(it)
		}
	}
	return out, nil
}

// Update 批量写入设置（增量，未传的键保持不变）。
//
// 先全部校验再落库：避免"前三个写进去了、第四个非法"这种半套状态。
// 返回写入后的全量有效值，前端可以直接拿去刷新界面，不用再查一次。
func (s *Service) Update(ctx context.Context, patch map[string]string) (map[string]string, error) {
	if len(patch) == 0 {
		return s.Values(ctx)
	}
	normalized := make(map[string]string, len(patch))
	for key, raw := range patch {
		it, ok := s.index[key]
		if !ok {
			return nil, fmt.Errorf("%w: 未知的配置项 %q", domain.ErrInvalidArgument, key)
		}
		value, err := normalize(it, raw)
		if err != nil {
			return nil, fmt.Errorf("%w: %s", domain.ErrInvalidArgument, err.Error())
		}
		normalized[key] = value
	}
	for key, value := range normalized {
		if err := s.store.Set(ctx, key, value); err != nil {
			return nil, fmt.Errorf("保存配置 %s 失败: %w", key, err)
		}
	}
	return s.Values(ctx)
}

// Reset 把指定键恢复默认值（删除库里的记录）。
//
// keys 为空表示全部重置——设置页的「恢复默认」按钮走这条路径。
func (s *Service) Reset(ctx context.Context, keys []string) (map[string]string, error) {
	if len(keys) == 0 {
		for key := range s.index {
			keys = append(keys, key)
		}
	}
	for _, key := range keys {
		if _, ok := s.index[key]; !ok {
			return nil, fmt.Errorf("%w: 未知的配置项 %q", domain.ErrInvalidArgument, key)
		}
		if err := s.store.Delete(ctx, key); err != nil {
			return nil, fmt.Errorf("重置配置 %s 失败: %w", key, err)
		}
	}
	return s.Values(ctx)
}

// ReaderConfig 是阅读器需要的强类型配置。
//
// 单开一个方法而不是让 Dart 自己从 Values 里解析：
// 阅读器是热路径（每次打开书都要用到），解析失败必须静默退回默认值，
// 这套"容错 + 夹区间"的逻辑放在 Go 里只需要维护一份。
type ReaderConfig struct {
	FontSize          float64 `json:"fontSize"`
	LineHeight        float64 `json:"lineHeight"`
	ParagraphSpacing  float64 `json:"paragraphSpacing"`
	IndentFirstLine   bool    `json:"indentFirstLine"`
	PaddingHorizontal float64 `json:"paddingHorizontal"`
	PaddingVertical   float64 `json:"paddingVertical"`
	PageTurn          string  `json:"pageTurn"`
	Theme             string  `json:"theme"`
	ShowPageNumber    bool    `json:"showPageNumber"`
	TextJustify       bool    `json:"textJustify"`
	// PromptAddToShelf 不是阅读器自己的设置，但「离开阅读器时要不要问」
	// 只有阅读器需要，顺手一起返回，省一次往返。
	PromptAddToShelf bool `json:"promptAddToShelf"`
}

// Reader 读取阅读器配置；任何异常都退回默认值，绝不让打开书失败。
func (s *Service) Reader(ctx context.Context) (ReaderConfig, error) {
	values, err := s.Values(ctx)
	if err != nil {
		return defaultReaderConfig(), err
	}
	cfg := defaultReaderConfig()
	if v, ok := parseFloat(values[KeyFontSize]); ok {
		cfg.FontSize = clampItem(s.index[KeyFontSize], v)
	}
	if v, ok := parseFloat(values[KeyLineHeight]); ok {
		cfg.LineHeight = clampItem(s.index[KeyLineHeight], v)
	}
	if v, ok := parseFloat(values[KeyParagraphSpace]); ok {
		cfg.ParagraphSpacing = clampItem(s.index[KeyParagraphSpace], v)
	}
	if v, ok := parseFloat(values[KeyPaddingH]); ok {
		cfg.PaddingHorizontal = clampItem(s.index[KeyPaddingH], v)
	}
	if v, ok := parseFloat(values[KeyPaddingV]); ok {
		cfg.PaddingVertical = clampItem(s.index[KeyPaddingV], v)
	}
	cfg.IndentFirstLine = parseBoolOr(values[KeyIndentFirstLine], cfg.IndentFirstLine)
	cfg.ShowPageNumber = parseBoolOr(values[KeyShowPageNumber], cfg.ShowPageNumber)
	cfg.TextJustify = parseBoolOr(values[KeyTextJustify], cfg.TextJustify)
	cfg.PromptAddToShelf = parseBoolOr(values[KeyPromptAddToShelf], cfg.PromptAddToShelf)
	if v := values[KeyPageTurn]; isValidOption(s.index[KeyPageTurn], v) {
		cfg.PageTurn = v
	}
	if v := values[KeyTheme]; isValidOption(s.index[KeyTheme], v) {
		cfg.Theme = v
	}
	return cfg, nil
}

// defaultReaderConfig 与 DefaultSchema 里的默认值保持一致；
// 两者漂了会被 schema_test 抓到。
func defaultReaderConfig() ReaderConfig {
	return ReaderConfig{
		FontSize:          20,
		LineHeight:        1.8,
		ParagraphSpacing:  10,
		IndentFirstLine:   true,
		PaddingHorizontal: 20,
		PaddingVertical:   12,
		PageTurn:          "cover",
		Theme:             "paper",
		ShowPageNumber:    true,
		TextJustify:       true,
		PromptAddToShelf:  false,
	}
}

// ---- 校验与归一化 ----

// normalize 按 Item 声明校验并归一化一个原始字符串。
func normalize(it Item, raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	switch it.Kind {
	case KindSwitch:
		v, err := strconv.ParseBool(raw)
		if err != nil {
			return "", fmt.Errorf("%s 需要 true/false，收到 %q", it.Title, raw)
		}
		return strconv.FormatBool(v), nil

	case KindSlider:
		v, err := strconv.ParseFloat(raw, 64)
		if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
			return "", fmt.Errorf("%s 需要数字，收到 %q", it.Title, raw)
		}
		// 越界不报错而是夹住：滑块拖到边上时不该弹错误提示。
		return formatFloat(clampItem(it, v)), nil

	case KindNumber:
		v, err := strconv.ParseFloat(raw, 64)
		if err != nil || math.IsNaN(v) {
			return "", fmt.Errorf("%s 需要整数，收到 %q", it.Title, raw)
		}
		return strconv.FormatInt(int64(math.Round(clampItem(it, v))), 10), nil

	case KindSelect:
		if !isValidOption(it, raw) {
			return "", fmt.Errorf("%s 不支持取值 %q", it.Title, raw)
		}
		return raw, nil

	case KindText:
		if len(raw) > 500 {
			return "", fmt.Errorf("%s 超长（最多 500 字节）", it.Title)
		}
		return raw, nil

	default:
		return "", fmt.Errorf("%s 的控件类型 %q 未实现", it.Title, it.Kind)
	}
}

// clampItem 把数值夹到 [Min, Max] 并对齐 Step。
func clampItem(it Item, v float64) float64 {
	if it.Max > it.Min {
		v = math.Min(it.Max, math.Max(it.Min, v))
	}
	if it.Step > 0 && it.Max > it.Min {
		// 对齐到 step 网格：先减去最小值再取整，避免 0.1 这类步长累积误差。
		steps := math.Round((v - it.Min) / it.Step)
		v = it.Min + steps*it.Step
		v = math.Min(it.Max, math.Max(it.Min, v))
		// 0.1 步长做乘加会引入浮点尾巴（1.0+9*0.1 = 1.9000000000000001），
		// 直接落库后 UI 会把它原样显示出来，所以在 6 位小数上收一下。
		v = math.Round(v*1e6) / 1e6
	}
	return v
}

// formatFloat 用最短表示输出，避免把 1.8 写成 1.8000000000000003。
func formatFloat(v float64) string { return strconv.FormatFloat(v, 'f', -1, 64) }

func isValidOption(it Item, value string) bool {
	for _, opt := range it.Options {
		if opt.Value == value {
			return true
		}
	}
	return false
}

func parseFloat(raw string) (float64, bool) {
	v, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, false
	}
	return v, true
}

func parseBoolOr(raw string, fallback bool) bool {
	v, err := strconv.ParseBool(strings.TrimSpace(raw))
	if err != nil {
		return fallback
	}
	return v
}

// defaultString 把 Item.Default 转成落库用的字符串形态。
func defaultString(it Item) string {
	switch v := it.Default.(type) {
	case bool:
		return strconv.FormatBool(v)
	case float64:
		return formatFloat(v)
	case int:
		return strconv.Itoa(v)
	case string:
		return v
	case nil:
		return ""
	default:
		return fmt.Sprint(v)
	}
}
