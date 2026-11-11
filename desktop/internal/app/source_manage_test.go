package app

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// 书源管理页（批量启停 / 分组 / 排序 / 源变量 / 清 Cookie）的服务层测试。
//
// 这些动作一次改几十条，出错的表现往往很隐蔽：
//   - 只改了列没改 Raw → 导出到其他 Legado 客户端后分组/发现开关对不上；
//   - 置顶/置底打乱选中项之间的相对顺序 → 用户觉得「点了置顶反而乱了」；
//   - 拖拽排序把筛选状态下看不见的书源挤到前面 → 取消筛选后整个列表变了。

// memSources 是内存版书源仓库，够用来验证「改了什么、落库成什么」。
type memSources struct {
	port.BookSourceRepository
	items  []*domain.BookSource
	orders map[int64]int // 最近一次 UpdateOrders 的入参
}

func (m *memSources) Get(_ context.Context, id int64) (*domain.BookSource, error) {
	for _, it := range m.items {
		if it.ID == id {
			cp := *it
			return &cp, nil
		}
	}
	return nil, domain.ErrNotFound
}

func (m *memSources) List(context.Context, string) ([]*domain.BookSource, error) {
	out := make([]*domain.BookSource, 0, len(m.items))
	for _, it := range m.items {
		cp := *it
		out = append(out, &cp)
	}
	return out, nil
}

func (m *memSources) Update(_ context.Context, src *domain.BookSource) error {
	for _, it := range m.items {
		if it.ID == src.ID {
			it.Name, it.Group, it.Enabled, it.Raw = src.Name, src.Group, src.Enabled, src.Raw
			return nil
		}
	}
	return domain.ErrNotFound
}

func (m *memSources) Delete(_ context.Context, id int64) error {
	for i, it := range m.items {
		if it.ID == id {
			m.items = append(m.items[:i], m.items[i+1:]...)
			return nil
		}
	}
	return domain.ErrNotFound
}

func (m *memSources) UpdateOrders(_ context.Context, orders map[int64]int) error {
	m.orders = orders
	for _, it := range m.items {
		if v, ok := orders[it.ID]; ok {
			it.Order = v
		}
	}
	return nil
}

func (m *memSources) sortedByOrder() []*domain.BookSource {
	out := append([]*domain.BookSource(nil), m.items...)
	for i := 0; i < len(out); i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j].Order < out[i].Order {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}

func (m *memSources) names() string {
	var b strings.Builder
	for _, it := range m.sortedByOrder() {
		b.WriteString(it.Name)
		b.WriteString(",")
	}
	return b.String()
}

type memVars struct {
	port.SourceVariableRepository
	data map[string]string
}

func (m *memVars) Get(_ context.Context, url string) (string, error) { return m.data[url], nil }
func (m *memVars) Put(_ context.Context, url, v string) error       { m.data[url] = v; return nil }
func (m *memVars) Delete(_ context.Context, url string) error       { delete(m.data, url); return nil }

type memSession struct{ cleared []string }

func (m *memSession) ClearCookie(url string) error {
	m.cleared = append(m.cleared, url)
	return nil
}

// seed 造三条书源：顺序 a(0) / b(1) / c(2)，a 无分组，b 在「小说」，c 在「小说,推荐」。
func seed() (*SourceService, *memSources, *memVars, *memSession) {
	repo := &memSources{items: []*domain.BookSource{
		{ID: 1, Name: "a", URL: "https://a.example", Order: 0, Enabled: true,
			Raw: `{"bookSourceUrl":"https://a.example","bookSourceName":"a","bookSourceGroup":null,"respondTime":3330}`},
		{ID: 2, Name: "b", URL: "https://b.example", Order: 1, Enabled: true, Group: "小说",
			Raw: `{"bookSourceUrl":"https://b.example","bookSourceName":"b","bookSourceGroup":"小说"}`},
		{ID: 3, Name: "c", URL: "https://c.example", Order: 2, Enabled: false, Group: "小说,推荐",
			Raw: `{"bookSourceUrl":"https://c.example","bookSourceName":"c","bookSourceGroup":"小说,推荐","enabledExplore":true}`},
	}}
	vars := &memVars{data: map[string]string{}}
	sess := &memSession{}
	svc := NewSourceService(SourceDeps{Sources: repo, Vars: vars, Session: sess})
	return svc, repo, vars, sess
}

func rawOf(t *testing.T, s string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		t.Fatalf("Raw 不是合法 JSON: %v (%s)", err, s)
	}
	return m
}

func TestAddToGroupWritesBothColumnAndRaw(t *testing.T) {
	svc, repo, _, _ := seed()
	if err := svc.AddToGroup(context.Background(), []int64{1}, "玄幻"); err != nil {
		t.Fatalf("AddToGroup: %v", err)
	}
	// 列：分组菜单/筛选靠它
	if repo.items[0].Group != "玄幻" {
		t.Errorf("group_name = %q, 期望 玄幻", repo.items[0].Group)
	}
	// Raw：导出给其他 Legado 客户端靠它
	if got := rawOf(t, repo.items[0].Raw)["bookSourceGroup"]; got != "玄幻" {
		t.Errorf("Raw.bookSourceGroup = %v, 期望 玄幻", got)
	}
	// 未参与的书源不能被动到
	if repo.items[1].Group != "小说" || repo.items[2].Group != "小说,推荐" {
		t.Errorf("未选中的书源被改动了: %q %q", repo.items[1].Group, repo.items[2].Group)
	}
}

func TestAddToGroupKeepsExistingGroups(t *testing.T) {
	svc, repo, _, _ := seed()
	if err := svc.AddToGroup(context.Background(), []int64{3}, "玄幻"); err != nil {
		t.Fatalf("AddToGroup: %v", err)
	}
	if repo.items[2].Group != "小说,推荐,玄幻" {
		t.Errorf("多分组追加结果 = %q", repo.items[2].Group)
	}
}

func TestAddToGroupIsIdempotent(t *testing.T) {
	svc, repo, _, _ := seed()
	for i := 0; i < 2; i++ {
		if err := svc.AddToGroup(context.Background(), []int64{2}, "小说"); err != nil {
			t.Fatalf("AddToGroup: %v", err)
		}
	}
	if repo.items[1].Group != "小说" {
		t.Errorf("重复加入同一分组后 = %q", repo.items[1].Group)
	}
}

func TestRemoveFromGroup(t *testing.T) {
	svc, repo, _, _ := seed()
	if err := svc.RemoveFromGroup(context.Background(), []int64{3}, "小说"); err != nil {
		t.Fatalf("RemoveFromGroup: %v", err)
	}
	if repo.items[2].Group != "推荐" {
		t.Errorf("移除后 = %q, 期望 推荐", repo.items[2].Group)
	}
	if got := rawOf(t, repo.items[2].Raw)["bookSourceGroup"]; got != "推荐" {
		t.Errorf("Raw.bookSourceGroup = %v, 期望 推荐", got)
	}
}

func TestGroupNameRequired(t *testing.T) {
	svc, _, _, _ := seed()
	if err := svc.AddToGroup(context.Background(), []int64{1}, "  "); err == nil {
		t.Fatal("空分组名应当报错")
	}
	if _, err := svc.AddGroupToNoGroup(context.Background(), ""); err == nil {
		t.Fatal("空分组名应当报错")
	}
}

func TestAddGroupToNoGroupOnlyTouchesUngrouped(t *testing.T) {
	svc, repo, _, _ := seed()
	n, err := svc.AddGroupToNoGroup(context.Background(), "新建组")
	if err != nil {
		t.Fatalf("AddGroupToNoGroup: %v", err)
	}
	if n != 1 {
		t.Errorf("收拢条数 = %d, 期望 1（只有 a 没有分组）", n)
	}
	if repo.items[0].Group != "新建组" {
		t.Errorf("a 的分组 = %q", repo.items[0].Group)
	}
	if repo.items[1].Group != "小说" || repo.items[2].Group != "小说,推荐" {
		t.Error("有分组的书源不该被收拢")
	}
}

func TestRenameGroup(t *testing.T) {
	svc, repo, _, _ := seed()
	if err := svc.RenameGroup(context.Background(), "小说", "文学"); err != nil {
		t.Fatalf("RenameGroup: %v", err)
	}
	if repo.items[1].Group != "文学" {
		t.Errorf("b = %q, 期望 文学", repo.items[1].Group)
	}
	// 多分组的情况只换掉目标分组，其余保留
	if repo.items[2].Group != "文学,推荐" {
		t.Errorf("c = %q, 期望 文学,推荐", repo.items[2].Group)
	}
}

func TestDeleteGroupKeepsSources(t *testing.T) {
	svc, repo, _, _ := seed()
	if err := svc.DeleteGroup(context.Background(), "小说"); err != nil {
		t.Fatalf("DeleteGroup: %v", err)
	}
	if len(repo.items) != 3 {
		t.Fatalf("删分组不该删书源，剩余 %d 条", len(repo.items))
	}
	if repo.items[1].Group != "" {
		t.Errorf("b 的分组 = %q, 期望清空", repo.items[1].Group)
	}
	if repo.items[2].Group != "推荐" {
		t.Errorf("c 的分组 = %q, 期望只剩 推荐", repo.items[2].Group)
	}
}

func TestSetEnabledBatch(t *testing.T) {
	svc, repo, _, _ := seed()
	if err := svc.SetEnabledBatch(context.Background(), []int64{1, 3}, false); err != nil {
		t.Fatalf("SetEnabledBatch: %v", err)
	}
	if repo.items[0].Enabled {
		t.Error("a 应当被禁用")
	}
	if repo.items[1].Enabled != true {
		t.Error("未选中的 b 不该变")
	}
	if repo.items[2].Enabled {
		t.Error("c 应当被禁用")
	}
}

func TestSetEnabledExploreBatchWritesRaw(t *testing.T) {
	svc, repo, _, _ := seed()
	if err := svc.SetEnabledExploreBatch(context.Background(), []int64{3}, false); err != nil {
		t.Fatalf("SetEnabledExploreBatch: %v", err)
	}
	if got := rawOf(t, repo.items[2].Raw)["enabledExplore"]; got != false {
		t.Errorf("Raw.enabledExplore = %v, 期望 false", got)
	}
	// 其他字段不能被卷掉
	if got := rawOf(t, repo.items[2].Raw)["bookSourceGroup"]; got != "小说,推荐" {
		t.Errorf("改写 Raw 时把分组弄丢了: %v", got)
	}
}

func TestDeleteBatchToleratesMissing(t *testing.T) {
	svc, repo, _, _ := seed()
	// 99 已被别的窗口删掉：批量删除要幂等，不能因此整批失败
	if err := svc.DeleteBatch(context.Background(), []int64{1, 99, 3}); err != nil {
		t.Fatalf("DeleteBatch: %v", err)
	}
	if len(repo.items) != 1 || repo.items[0].ID != 2 {
		t.Errorf("删除后剩余 %d 条", len(repo.items))
	}
}

func TestMoveTopKeepsSelectionOrder(t *testing.T) {
	svc, repo, _, _ := seed()
	if err := svc.MoveTop(context.Background(), []int64{3, 1}); err != nil {
		t.Fatalf("MoveTop: %v", err)
	}
	// 选中项按原列表顺序（a 在 c 前面）置顶，而不是按 ids 的传入顺序
	if got := repo.names(); got != "a,c,b," {
		t.Errorf("顺序 = %s, 期望 a,c,b", got)
	}
	if len(repo.orders) != 2 {
		t.Errorf("只应更新选中项的 order, 实际 %d 条", len(repo.orders))
	}
}

func TestMoveBottomPutsSelectionLast(t *testing.T) {
	svc, repo, _, _ := seed()
	if err := svc.MoveBottom(context.Background(), []int64{2}); err != nil {
		t.Fatalf("MoveBottom: %v", err)
	}
	if got := repo.names(); got != "a,c,b," {
		t.Errorf("顺序 = %s, 期望 a,c,b", got)
	}
}

// 拖拽排序的边界：ids 只包含当前筛选下可见的那部分，
// 看不见的书源必须保持原有相对顺序，统一接在后面。
func TestReorderKeepsUnseenSourcesInOrder(t *testing.T) {
	svc, repo, _, _ := seed()
	if err := svc.Reorder(context.Background(), []int64{3, 1}); err != nil {
		t.Fatalf("Reorder: %v", err)
	}
	if got := repo.names(); got != "c,a,b," {
		t.Errorf("顺序 = %s, 期望 c,a,b", got)
	}
	if len(repo.orders) != 3 {
		t.Errorf("全部书源都要有新的 order, 实际 %d 条", len(repo.orders))
	}
}

func TestReorderIgnoresUnknownIDs(t *testing.T) {
	svc, repo, _, _ := seed()
	if err := svc.Reorder(context.Background(), []int64{99, 2}); err != nil {
		t.Fatalf("Reorder: %v", err)
	}
	if got := repo.names(); got != "b,a,c," {
		t.Errorf("顺序 = %s, 期望 b,a,c", got)
	}
}

func TestVariableRoundTrip(t *testing.T) {
	svc, _, _, _ := seed()
	ctx := context.Background()
	if err := svc.SetVariable(ctx, 1, `{"token":"abc"}`); err != nil {
		t.Fatalf("SetVariable: %v", err)
	}
	v, err := svc.GetVariable(ctx, 1)
	if err != nil {
		t.Fatalf("GetVariable: %v", err)
	}
	if v.Variable != `{"token":"abc"}` {
		t.Errorf("变量 = %q", v.Variable)
	}
	// 按书源 URL 存：换了 ID 也还是同一份变量
	if err := svc.SetVariable(ctx, 1, "   "); err != nil {
		t.Fatalf("清空变量: %v", err)
	}
	v, _ = svc.GetVariable(ctx, 1)
	if v.Variable != "" {
		t.Errorf("清空后 = %q", v.Variable)
	}
}

func TestClearCookieUsesSourceURL(t *testing.T) {
	svc, _, _, sess := seed()
	if err := svc.ClearCookie(context.Background(), 2); err != nil {
		t.Fatalf("ClearCookie: %v", err)
	}
	if len(sess.cleared) != 1 || sess.cleared[0] != "https://b.example" {
		t.Errorf("清 Cookie 的站点 = %v", sess.cleared)
	}
}

func TestMissingDepsReportNotConfigured(t *testing.T) {
	// 组装时不传 Vars/Session（安卓端早期构建可能没有），
	// 要给出「未配置」而不是空指针崩溃。
	repo := &memSources{items: []*domain.BookSource{{ID: 1, URL: "https://x.example"}}}
	svc := NewSourceService(SourceDeps{Sources: repo})
	if err := svc.SetVariable(context.Background(), 1, "v"); !errors.Is(err, domain.ErrNotConfigured) {
		t.Errorf("SetVariable 错误 = %v, 期望 ErrNotConfigured", err)
	}
	if err := svc.ClearCookie(context.Background(), 1); !errors.Is(err, domain.ErrNotConfigured) {
		t.Errorf("ClearCookie 错误 = %v, 期望 ErrNotConfigured", err)
	}
}
