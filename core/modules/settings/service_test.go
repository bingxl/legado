package settings

import (
	"context"
	"errors"
	"strconv"
	"sync"
	"testing"

	"github.com/legado/core/domain"
)

// memStore 是内存版 SettingsStore，测试里替掉 sqlite。
//
// 用 map 而不是开临时库：本模块要验证的是「校验 + 默认值合并」，
// 不关心 SQL；用真库反而把测试和 001_init.sql 绑在一起。
type memStore struct {
	mu   sync.Mutex
	data map[string]string
	// failOn 命中时让 Set 返回错误，用于验证部分写入的行为。
	failOn string
}

func newMemStore() *memStore { return &memStore{data: map[string]string{}} }

func (m *memStore) Get(ctx context.Context, key string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v, ok := m.data[key]
	if !ok {
		return "", domain.ErrNotFound
	}
	return v, nil
}

func (m *memStore) Set(ctx context.Context, key, value string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.failOn != "" && m.failOn == key {
		return errors.New("磁盘写入失败")
	}
	m.data[key] = value
	return nil
}

func (m *memStore) Delete(ctx context.Context, key string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.data, key)
	return nil
}

func TestSchemaWellFormed(t *testing.T) {
	sc := DefaultSchema()
	idx, err := sc.index()
	if err != nil {
		t.Fatalf("Schema 结构不合法: %v", err)
	}
	if len(idx) == 0 {
		t.Fatal("Schema 里一个设置项都没有")
	}
	if sc.Version != SchemaVersion {
		t.Fatalf("Version = %d，期望 %d", sc.Version, SchemaVersion)
	}

	seenPages := map[string]bool{}
	for _, p := range sc.Pages {
		seenPages[p] = true
	}
	for _, sec := range sc.Sections {
		if sec.Title == "" {
			t.Errorf("分组 %s 缺少标题", sec.Key)
		}
		if !seenPages[sec.Page] {
			t.Errorf("分组 %s 的 page=%q 不在 Pages 列表里", sec.Key, sec.Page)
		}
		if len(sec.Items) == 0 {
			t.Errorf("分组 %s 是空的", sec.Key)
		}
		for _, it := range sec.Items {
			if it.Title == "" {
				t.Errorf("%s 缺少标题", it.Key)
			}
			switch it.Kind {
			case KindSlider, KindNumber:
				if it.Max <= it.Min {
					t.Errorf("%s 的区间非法: min=%v max=%v", it.Key, it.Min, it.Max)
				}
				v, ok := it.Default.(float64)
				if !ok {
					t.Fatalf("%s 的默认值应为数字，实际 %T", it.Key, it.Default)
				}
				if v < it.Min || v > it.Max {
					t.Errorf("%s 的默认值 %v 超出 [%v,%v]", it.Key, v, it.Min, it.Max)
				}
			case KindSelect:
				def, ok := it.Default.(string)
				if !ok {
					t.Fatalf("%s 的默认值应为字符串，实际 %T", it.Key, it.Default)
				}
				if !isValidOption(it, def) {
					t.Errorf("%s 的默认值 %q 不在 options 里", it.Key, def)
				}
				if len(it.Options) < 2 {
					t.Errorf("%s 是下拉框但选项少于 2 个", it.Key)
				}
			case KindSwitch:
				if _, ok := it.Default.(bool); !ok {
					t.Errorf("%s 是开关但默认值不是 bool（%T）", it.Key, it.Default)
				}
			case KindText:
				if it.Default == nil {
					t.Errorf("%s 是输入框但没有默认值", it.Key)
				}
			default:
				t.Errorf("%s 使用了未实现的控件类型 %q", it.Key, it.Kind)
			}
		}
	}
}

// defaultReaderConfig 与 Schema 默认值必须一致，否则「第一次打开设置页」
// 和「阅读器实际生效的值」会对不上。
func TestReaderDefaultsMatchSchema(t *testing.T) {
	svc := NewService(newMemStore())
	cfg, err := svc.Reader(context.Background())
	if err != nil {
		t.Fatalf("Reader: %v", err)
	}
	want := defaultReaderConfig()
	if cfg != want {
		t.Fatalf("空库读到的配置 %+v，期望 %+v", cfg, want)
	}

	// 逐项和 Schema 里的 Default 对照。
	values, err := svc.Values(context.Background())
	if err != nil {
		t.Fatalf("Values: %v", err)
	}
	checks := map[string]string{
		KeyFontSize:         formatFloat(want.FontSize),
		KeyLineHeight:       formatFloat(want.LineHeight),
		KeyParagraphSpace:   formatFloat(want.ParagraphSpacing),
		KeyPaddingH:         formatFloat(want.PaddingHorizontal),
		KeyPaddingV:         formatFloat(want.PaddingVertical),
		KeyPageTurn:         want.PageTurn,
		KeyTheme:            want.Theme,
		KeyIndentFirstLine:  strconv.FormatBool(want.IndentFirstLine),
		KeyShowPageNumber:   strconv.FormatBool(want.ShowPageNumber),
		KeyTextJustify:      strconv.FormatBool(want.TextJustify),
		KeyPromptAddToShelf: strconv.FormatBool(want.PromptAddToShelf),
	}
	for key, exp := range checks {
		if values[key] != exp {
			t.Errorf("%s = %q，期望 %q", key, values[key], exp)
		}
	}
}

func TestValuesUsesDefaultsOnEmptyStore(t *testing.T) {
	svc := NewService(newMemStore())
	values, err := svc.Values(context.Background())
	if err != nil {
		t.Fatalf("Values: %v", err)
	}
	if len(values) != len(svc.index) {
		t.Fatalf("返回 %d 项，Schema 有 %d 项", len(values), len(svc.index))
	}
	for key, it := range svc.index {
		if _, ok := values[key]; !ok {
			t.Errorf("%s 没有出现在 Values 里", key)
		}
		if values[key] != defaultString(it) {
			t.Errorf("%s = %q，期望默认值 %q", key, values[key], defaultString(it))
		}
	}
}

func TestUpdateAppliesAndReturnsEffective(t *testing.T) {
	store := newMemStore()
	svc := NewService(store)
	ctx := context.Background()

	got, err := svc.Update(ctx, map[string]string{KeyFontSize: "26"})
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if got[KeyFontSize] != "26" {
		t.Errorf("返回的 fontSize = %q，期望 26", got[KeyFontSize])
	}
	// 未传的键保持默认。
	if got[KeyLineHeight] != "1.8" {
		t.Errorf("未修改的 lineHeight 被改了: %q", got[KeyLineHeight])
	}
	if store.data[KeyFontSize] != "26" {
		t.Errorf("没有真正落库: %v", store.data)
	}

	cfg, err := svc.Reader(ctx)
	if err != nil {
		t.Fatalf("Reader: %v", err)
	}
	if cfg.FontSize != 26 {
		t.Errorf("阅读器字号 = %v，期望 26", cfg.FontSize)
	}
}

func TestUpdateRejectsUnknownKey(t *testing.T) {
	svc := NewService(newMemStore())
	_, err := svc.Update(context.Background(), map[string]string{"reader.nope": "1"})
	if !errors.Is(err, domain.ErrInvalidArgument) {
		t.Fatalf("期望参数非法，实际: %v", err)
	}
}

// 先全部校验再落库：一个非法值不能让别的键写进去。
func TestUpdateIsAllOrNothing(t *testing.T) {
	store := newMemStore()
	svc := NewService(store)
	_, err := svc.Update(context.Background(), map[string]string{
		KeyFontSize: "26",
		KeyPageTurn: "teleport", // 非法选项
	})
	if err == nil {
		t.Fatal("非法选项应当报错")
	}
	if _, ok := store.data[KeyFontSize]; ok {
		t.Fatalf("校验失败时不该有键被写入: %v", store.data)
	}
}

func TestSliderClampsAndAlignsStep(t *testing.T) {
	svc := NewService(newMemStore())
	ctx := context.Background()

	cases := []struct{ in, want string }{
		{"100", "40"},  // 超过上限 → 夹到 40
		{"1", "12"},    // 低于下限 → 夹到 12
		{"23.6", "24"}, // 对齐到 step=1
		{"20.4", "20"}, // 同上
	}
	for _, c := range cases {
		got, err := svc.Update(ctx, map[string]string{KeyFontSize: c.in})
		if err != nil {
			t.Fatalf("Update(%s): %v", c.in, err)
		}
		if got[KeyFontSize] != c.want {
			t.Errorf("fontSize %s → %q，期望 %q", c.in, got[KeyFontSize], c.want)
		}
	}

	// 0.1 步长不能留下浮点尾巴。
	got, err := svc.Update(ctx, map[string]string{KeyLineHeight: "1.85"})
	if err != nil {
		t.Fatalf("Update(lineHeight): %v", err)
	}
	if got[KeyLineHeight] != "1.9" {
		t.Errorf("lineHeight 1.85 → %q，期望 1.9", got[KeyLineHeight])
	}
}

func TestUpdateRejectsBadBool(t *testing.T) {
	svc := NewService(newMemStore())
	_, err := svc.Update(context.Background(), map[string]string{KeyIndentFirstLine: "yes"})
	if !errors.Is(err, domain.ErrInvalidArgument) {
		t.Fatalf("期望参数非法，实际: %v", err)
	}
}

func TestResetRestoresDefaults(t *testing.T) {
	store := newMemStore()
	svc := NewService(store)
	ctx := context.Background()

	if _, err := svc.Update(ctx, map[string]string{KeyFontSize: "30", KeyTheme: "night"}); err != nil {
		t.Fatalf("Update: %v", err)
	}
	// 只重置一项，另一项保留。
	got, err := svc.Reset(ctx, []string{KeyFontSize})
	if err != nil {
		t.Fatalf("Reset: %v", err)
	}
	if got[KeyFontSize] != "20" {
		t.Errorf("重置后 fontSize = %q，期望默认 20", got[KeyFontSize])
	}
	if got[KeyTheme] != "night" {
		t.Errorf("不该被重置的 theme 变成了 %q", got[KeyTheme])
	}

	// 空切片表示全部重置。
	got, err = svc.Reset(ctx, nil)
	if err != nil {
		t.Fatalf("Reset all: %v", err)
	}
	if got[KeyTheme] != "paper" {
		t.Errorf("全部重置后 theme = %q，期望 paper", got[KeyTheme])
	}
	if len(store.data) != 0 {
		t.Errorf("重置后库里还留了: %v", store.data)
	}
}

func TestResetRejectsUnknownKey(t *testing.T) {
	svc := NewService(newMemStore())
	if _, err := svc.Reset(context.Background(), []string{"nope.nope"}); !errors.Is(err, domain.ErrInvalidArgument) {
		t.Fatalf("期望参数非法，实际: %v", err)
	}
}

// 库里存着旧版本写的脏数据时，读出来要退回默认值而不是让界面显示乱码。
func TestValuesSanitizesDirtyStore(t *testing.T) {
	store := newMemStore()
	store.data[KeyFontSize] = "not-a-number"
	store.data[KeyTheme] = "neon"            // 选项已不存在
	store.data[KeyLineHeight] = "999"        // 越界
	store.data[KeyIndentFirstLine] = "maybe" // 非 bool
	svc := NewService(store)

	values, err := svc.Values(context.Background())
	if err != nil {
		t.Fatalf("Values: %v", err)
	}
	if values[KeyFontSize] != "20" {
		t.Errorf("fontSize = %q，期望退回默认 20", values[KeyFontSize])
	}
	if values[KeyTheme] != "paper" {
		t.Errorf("theme = %q，期望退回默认 paper", values[KeyTheme])
	}
	if values[KeyLineHeight] != "3" {
		t.Errorf("lineHeight = %q，期望夹到上限 3", values[KeyLineHeight])
	}
	if values[KeyIndentFirstLine] != "true" {
		t.Errorf("indentFirstLine = %q，期望退回默认 true", values[KeyIndentFirstLine])
	}

	cfg, err := svc.Reader(context.Background())
	if err != nil {
		t.Fatalf("Reader: %v", err)
	}
	if cfg.FontSize != 20 || cfg.Theme != "paper" {
		t.Errorf("阅读器没退回默认值: %+v", cfg)
	}
}

func TestUpdateEmptyPatchIsNoop(t *testing.T) {
	store := newMemStore()
	svc := NewService(store)
	got, err := svc.Update(context.Background(), nil)
	if err != nil {
		t.Fatalf("Update(nil): %v", err)
	}
	if len(got) != len(svc.index) {
		t.Fatalf("空 patch 也应该返回全量有效值，实际 %d 项", len(got))
	}
}

func TestUpdateReportsStoreFailure(t *testing.T) {
	store := newMemStore()
	store.failOn = KeyFontSize
	svc := NewService(store)
	if _, err := svc.Update(context.Background(), map[string]string{KeyFontSize: "22"}); err == nil {
		t.Fatal("存储写入失败时应当返回错误")
	}
}

func TestModuleIdentity(t *testing.T) {
	// 模块名必须稳定：hosts 的拓扑排序与日志都按它识别。
	m := New(newMemStore())
	if m.Name() != "settings" {
		t.Fatalf("Name = %q", m.Name())
	}
	if len(m.DependsOn()) != 0 {
		t.Fatalf("配置模块不该依赖别的模块: %v", m.DependsOn())
	}
}
