package app

import (
	"context"
	"testing"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// stubGroupRepo 只实现 List，其余方法留空（被调用即 panic，便于尽早发现）。
type stubGroupRepo struct {
	port.BookGroupRepository
	list []*domain.BookGroup
}

func (s stubGroupRepo) List(context.Context) ([]*domain.BookGroup, error) { return s.list, nil }

// 迁移脚本种的内置「全部」分组不应该出现在侧栏：界面上已有 groupID=0 的「全部」，
// 两者同时出现会让用户看到两个「全部」。
func TestListGroupsSkipsBuiltIn(t *testing.T) {
	repo := stubGroupRepo{list: []*domain.BookGroup{
		{ID: 1, Name: "全部", BuiltIn: true},
		{ID: 2, Name: "轻小说"},
		{ID: 3, Name: "本地"},
	}}
	svc := NewBookshelfService(nil, repo, nil, nil)

	groups, err := svc.ListGroups(context.Background())
	if err != nil {
		t.Fatalf("ListGroups 出错: %v", err)
	}
	if len(groups) != 2 {
		t.Fatalf("期望 2 个分组，实际 %d 个: %+v", len(groups), groups)
	}
	for _, g := range groups {
		if g.BuiltIn {
			t.Fatalf("内置分组不应下发: %+v", g)
		}
	}
	if groups[0].Name != "轻小说" || groups[1].Name != "本地" {
		t.Fatalf("分组顺序/内容不符: %+v", groups)
	}
}
