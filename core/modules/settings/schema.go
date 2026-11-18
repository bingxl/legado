package settings

import "fmt"

// 配置键名。UI 侧不硬编码字符串，一律从 Schema 里取；
// 这里集中定义是为了让「读写同一个键」在 Go 侧可被编译器检查。
//
// 沿用 `reader.*` 前缀（与 port.SettingReadTheme = "reader.theme" 一致），
// 这样桌面端旧版本已写进 app_settings 的主题偏好在升级后仍然生效。
const (
	KeyFontSize        = "reader.fontSize"
	KeyLineHeight      = "reader.lineHeight"
	KeyParagraphSpace  = "reader.paragraphSpacing"
	KeyIndentFirstLine = "reader.indentFirstLine"
	KeyPaddingH        = "reader.paddingHorizontal"
	KeyPaddingV        = "reader.paddingVertical"
	KeyPageTurn        = "reader.pageTurn"
	KeyTheme           = "reader.theme"
	KeyShowPageNumber  = "reader.showPageNumber"
	KeyTextJustify     = "reader.textJustify"

	KeyPromptAddToShelf = "general.promptAddToShelf"
)

// Kind 是设置项的控件类型。Dart 侧按它决定渲染成开关/滑块/下拉/输入框，
// 新增类型必须先在这里登记，否则前端会落到「只读文本」兜底。
type Kind string

// 支持的控件类型。
const (
	KindSwitch Kind = "switch" // 布尔开关
	KindSlider Kind = "slider" // 数值滑块（min/max/step）
	KindSelect Kind = "select" // 枚举下拉（options）
	KindNumber Kind = "number" // 整数输入框
	KindText   Kind = "text"   // 自由文本
)

// Option 是下拉项。
type Option struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

// Item 是单个设置项的声明。
//
// Default 用 any 而不是 string：默认值本身是强类型的（bool/数字/字符串），
// 让 Dart 侧拿到 `false` 而不是 `"false"`，省掉一层「怎么解析」的猜测。
// 落库时统一转成字符串（app_settings.value 是 TEXT）。
type Item struct {
	Key     string   `json:"key"`
	Kind    Kind     `json:"kind"`
	Title   string   `json:"title"`
	Desc    string   `json:"desc,omitempty"`
	Default any      `json:"default"`
	Options []Option `json:"options,omitempty"`
	// Min/Max/Step 只对 KindSlider 有意义。
	Min  float64 `json:"min,omitempty"`
	Max  float64 `json:"max,omitempty"`
	Step float64 `json:"step,omitempty"`
	// Unit 是滑块右侧的单位后缀（px、倍、%），没有就不显示。
	Unit string `json:"unit,omitempty"`
}

// Section 是一组设置项。Page 决定它显示在哪个页面：
// read（阅读设置）/ theme（主题）/ general（通用）。
type Section struct {
	Key   string `json:"key"`
	Page  string `json:"page"`
	Title string `json:"title"`
	Desc  string `json:"desc,omitempty"`
	Items []Item `json:"items"`
}

// Schema 是设置页的完整声明。
type Schema struct {
	// Version 供前端做缓存失效；改动 item 集合时自增。
	Version int `json:"version"`
	// Pages 是可用的页面 key（按显示顺序），前端据此生成入口列表。
	Pages    []string  `json:"pages"`
	Sections []Section `json:"sections"`
}

// SchemaVersion 与 DefaultSchema 的 Version 保持一致。
const SchemaVersion = 1

// Page 常量：设置页的分页 key。
const (
	PageRead    = "read"
	PageTheme   = "theme"
	PageGeneral = "general"
)

// 页面标题，前端入口列表直接用，避免两边各写一份中文。
var pageTitles = map[string]string{
	PageRead:    "阅读设置",
	PageTheme:   "主题外观",
	PageGeneral: "通用",
}

// PageTitle 返回页面标题。
func PageTitle(page string) string { return pageTitles[page] }

// DefaultSchema 返回设置页声明。
//
// 一条硬约束：**这里出现的每个键都必须有真实消费者**。
// 加一个新开关却没人读，用户改了没反应，比没这个开关更糟——
// 所以宁可按需增长，也不照抄原版 40+ 项做「看起来完整」的空壳。
// 当前消费方：阅读器（排版/翻页/主题）、离开阅读器时的加书架询问。
func DefaultSchema() Schema {
	return Schema{
		Version: SchemaVersion,
		Pages:   []string{PageRead, PageTheme, PageGeneral},
		Sections: []Section{
			{
				Key:   "typography",
				Page:  PageRead,
				Title: "排版",
				Desc:  "改动立即作用于阅读器，并重新分页",
				Items: []Item{
					{
						Key:     KeyFontSize,
						Kind:    KindSlider,
						Title:   "字号",
						Default: 20.0,
						Min:     12,
						Max:     40,
						Step:    1,
						Unit:    "px",
					},
					{
						Key:     KeyLineHeight,
						Kind:    KindSlider,
						Title:   "行距",
						Desc:    "行高倍数，中文正文 1.7~1.9 较透气",
						Default: 1.8,
						Min:     1.0,
						Max:     3.0,
						Step:    0.1,
						Unit:    "倍",
					},
					{
						Key:     KeyParagraphSpace,
						Kind:    KindSlider,
						Title:   "段间距",
						Default: 10.0,
						Min:     0,
						Max:     40,
						Step:    1,
						Unit:    "px",
					},
					{
						Key:     KeyIndentFirstLine,
						Kind:    KindSwitch,
						Title:   "段首缩进",
						Desc:    "两字宽的全角缩进",
						Default: true,
					},
					{
						Key:     KeyPaddingH,
						Kind:    KindSlider,
						Title:   "左右页边距",
						Default: 20.0,
						Min:     0,
						Max:     80,
						Step:    2,
						Unit:    "px",
					},
					{
						Key:     KeyPaddingV,
						Kind:    KindSlider,
						Title:   "上下页边距",
						Default: 12.0,
						Min:     0,
						Max:     80,
						Step:    2,
						Unit:    "px",
					},
					{
						Key:     KeyTextJustify,
						Kind:    KindSwitch,
						Title:   "两端对齐",
						Desc:    "关闭后左对齐，右侧留自然参差",
						Default: true,
					},
					{
						Key:     KeyShowPageNumber,
						Kind:    KindSwitch,
						Title:   "显示页码",
						Desc:    "页脚同时显示章节名",
						Default: true,
					},
				},
			},
			{
				Key:   "paging",
				Page:  PageRead,
				Title: "翻页",
				Items: []Item{
					{
						Key:     KeyPageTurn,
						Kind:    KindSelect,
						Title:   "翻页动画",
						Default: "cover",
						Options: []Option{
							{Value: "cover", Label: "覆盖"},
							{Value: "slide", Label: "滑动"},
							{Value: "simulation", Label: "仿真"},
							{Value: "scroll", Label: "滚动"},
							{Value: "none", Label: "无动画"},
						},
					},
				},
			},
			{
				Key:   "background",
				Page:  PageTheme,
				Title: "背景",
				Desc:  "文字颜色随背景自动切换，夜间模式不会出现黑底黑字",
				Items: []Item{
					{
						Key:     KeyTheme,
						Kind:    KindSelect,
						Title:   "阅读背景",
						Default: "paper",
						Options: []Option{
							{Value: "paper", Label: "纸黄"},
							{Value: "white", Label: "米白"},
							{Value: "green", Label: "浅绿"},
							{Value: "gray", Label: "浅灰"},
							{Value: "night", Label: "夜间"},
						},
					},
				},
			},
			{
				Key:   "behavior",
				Page:  PageGeneral,
				Title: "行为",
				Items: []Item{
					{
						Key:     KeyPromptAddToShelf,
						Kind:    KindSwitch,
						Title:   "退出时询问加入书架",
						Desc:    "从搜索/发现点开的书只管试读，默认不打扰；打开后退出时会问一次",
						Default: false,
					},
				},
			},
		},
	}
}

// index 建立 key → item 的索引，避免每次校验都线性扫描。
func (s Schema) index() (map[string]Item, error) {
	out := make(map[string]Item, len(s.Sections))
	for _, sec := range s.Sections {
		for _, it := range sec.Items {
			if it.Key == "" {
				return nil, fmt.Errorf("设置项缺少 key（分组 %s）", sec.Key)
			}
			if _, dup := out[it.Key]; dup {
				return nil, fmt.Errorf("设置项 key 重复: %s", it.Key)
			}
			out[it.Key] = it
		}
	}
	return out, nil
}
