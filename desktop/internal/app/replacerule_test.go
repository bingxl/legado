package app

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// stubRuleRepo 是内存版替换规则仓储，只覆盖本次用到的能力。
type stubRuleRepo struct {
	mu    sync.Mutex
	items map[int64]*domain.ReplaceRule
	next  int64
}

var _ port.ReplaceRuleRepository = (*stubRuleRepo)(nil)

func newStubRuleRepo() *stubRuleRepo {
	return &stubRuleRepo{items: map[int64]*domain.ReplaceRule{}, next: 1}
}

func (r *stubRuleRepo) Create(_ context.Context, v *domain.ReplaceRule) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	v.ID = r.next
	r.next++
	r.items[v.ID] = v
	return nil
}

func (r *stubRuleRepo) Update(_ context.Context, v *domain.ReplaceRule) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.items[v.ID]; !ok {
		return domain.ErrNotFound
	}
	r.items[v.ID] = v
	return nil
}

func (r *stubRuleRepo) Delete(_ context.Context, id int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.items[id]; !ok {
		return domain.ErrNotFound
	}
	delete(r.items, id)
	return nil
}

func (r *stubRuleRepo) Get(_ context.Context, id int64) (*domain.ReplaceRule, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	v, ok := r.items[id]
	if !ok {
		return nil, domain.ErrNotFound
	}
	return v, nil
}

func (r *stubRuleRepo) List(context.Context) ([]*domain.ReplaceRule, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*domain.ReplaceRule, 0, len(r.items))
	for _, v := range r.items {
		out = append(out, v)
	}
	return out, nil
}

func (r *stubRuleRepo) ListEnabled(context.Context) ([]*domain.ReplaceRule, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*domain.ReplaceRule, 0, len(r.items))
	for _, v := range r.items {
		if v.Enabled {
			out = append(out, v)
		}
	}
	return out, nil
}

// 官方导出的替换规则用 replaceRule 字段承载规则数组，
// 本应用早期版本用过 raw。两种都要能导入，否则用户拿来的文件会全军覆没。
func TestImportReplaceRuleAcceptsBothFieldNames(t *testing.T) {
	repo := newStubRuleRepo()
	svc := NewReplaceRuleService(repo)

	payload := `[
		{"name":"官方格式","group":"净化","enabled":true,"sortOrder":1,"replaceRule":"[{\"regex\":\"广告\",\"replacement\":\"\"}]"},
		{"name":"旧格式","group":"","enabled":false,"sortOrder":0,"raw":"[]"}
	]`
	res, err := svc.Import(context.Background(), []byte(payload), false)
	if err != nil {
		t.Fatalf("导入失败: %v", err)
	}
	if res.Imported != 2 {
		t.Fatalf("期望新增 2 条，实际 %d（失败 %d）", res.Imported, len(res.Failures))
	}
	for _, r := range res.Rules {
		if r.Raw == "" {
			t.Fatalf("规则原文为空: %+v", r)
		}
	}
	// 旧格式那条显式 enabled=false，不能被默认成启用
	for _, r := range res.Rules {
		if r.Name == "旧格式" && r.Enabled {
			t.Fatalf("显式 enabled=false 的规则被当成启用: %+v", r)
		}
	}
}

// 同名规则在 overwrite=false 时跳过、true 时覆盖：
// 前者保护用户已有的修改，后者保证订阅/重新导入能修坏数据。
func TestImportReplaceRuleDedupeByName(t *testing.T) {
	repo := newStubRuleRepo()
	svc := NewReplaceRuleService(repo)

	first := `[{"name":"净化","replaceRule":"[]"}]`
	if _, err := svc.Import(context.Background(), []byte(first), false); err != nil {
		t.Fatalf("首次导入失败: %v", err)
	}

	res, err := svc.Import(context.Background(), []byte(first), false)
	if err != nil {
		t.Fatalf("二次导入失败: %v", err)
	}
	if res.Skipped != 1 || res.Imported != 0 {
		t.Fatalf("期望跳过 1 条，实际 skipped=%d imported=%d", res.Skipped, res.Imported)
	}

	updated := `[{"name":"净化","replaceRule":"[{\"regex\":\"x\"}]"}]`
	res, err = svc.Import(context.Background(), []byte(updated), true)
	if err != nil {
		t.Fatalf("覆盖导入失败: %v", err)
	}
	if res.Updated != 1 {
		t.Fatalf("期望更新 1 条，实际 %d", res.Updated)
	}
	list, err := svc.List(context.Background())
	if err != nil {
		t.Fatalf("List 失败: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("覆盖后仍应只有 1 条，实际 %d", len(list))
	}
	if list[0].Raw != `[{"regex":"x"}]` {
		t.Fatalf("规则原文未更新: %q", list[0].Raw)
	}
}

// 从聊天窗口复制出来的往往是逐行 JSON，不是数组。
func TestImportReplaceRuleAcceptsLineSeparated(t *testing.T) {
	repo := newStubRuleRepo()
	svc := NewReplaceRuleService(repo)

	payload := "{\"name\":\"A\",\"replaceRule\":\"[]\"}\n{\"name\":\"B\",\"replaceRule\":\"[]\"}\n"
	res, err := svc.Import(context.Background(), []byte(payload), false)
	if err != nil {
		t.Fatalf("逐行导入失败: %v", err)
	}
	if res.Imported != 2 {
		t.Fatalf("期望新增 2 条，实际 %d（失败 %d）", res.Imported, len(res.Failures))
	}
}

// 空内容必须报错而不是静默成功：否则用户点了导入、什么都没发生，
// 会以为功能坏了。
func TestImportReplaceRuleRejectsEmpty(t *testing.T) {
	svc := NewReplaceRuleService(newStubRuleRepo())
	for _, payload := range []string{"", "   ", "[]"} {
		if _, err := svc.Import(context.Background(), []byte(payload), false); err == nil {
			t.Fatalf("空载荷 %q 应当报错", payload)
		}
	}
}

// 保存时空原文兜成 []：空串既不是对象也不是数组，
// 阅读器解析时会直接失败，不如在入库前挡住。
func TestSaveReplaceRuleNormalizesEmptyRaw(t *testing.T) {
	svc := NewReplaceRuleService(newStubRuleRepo())
	v, err := svc.Save(context.Background(), 0, "净化", "", "", true, 0)
	if err != nil {
		t.Fatalf("保存失败: %v", err)
	}
	if v.Raw != "[]" {
		t.Fatalf("空原文应兜成 []，实际 %q", v.Raw)
	}

	if _, err := svc.Save(context.Background(), 0, "  ", "", "[]", true, 0); err == nil {
		t.Fatal("空名称应当被拒绝")
	}
}

// 导出必须是数组且带官方字段名，才能被 Legado 原版直接导入。
func TestExportReplaceRuleUsesOfficialFields(t *testing.T) {
	repo := newStubRuleRepo()
	svc := NewReplaceRuleService(repo)
	if _, err := svc.Save(context.Background(), 0, "净化", "g", `[{"regex":"x"}]`, true, 3); err != nil {
		t.Fatalf("保存失败: %v", err)
	}

	data, err := svc.Export(context.Background(), nil)
	if err != nil {
		t.Fatalf("导出失败: %v", err)
	}
	var out []map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("导出内容不是 JSON 数组: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("期望 1 条，实际 %d", len(out))
	}
	if _, ok := out[0]["replaceRule"]; !ok {
		t.Fatalf("缺少 replaceRule 字段: %+v", out[0])
	}
	if out[0]["sortOrder"] != float64(3) {
		t.Fatalf("sortOrder 应为 3，实际 %v", out[0]["sortOrder"])
	}
}
