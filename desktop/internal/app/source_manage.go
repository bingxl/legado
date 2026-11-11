package app

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
)

// 本文件实现书源管理界面（对应 Legado 原生的 BookSourceActivity）里
// 「批量操作 / 排序 / 分组 / 源变量」这几组能力。
//
// 与单条 CRUD（source.go）分开的原因是关注点不同：那边的语义是
// 「编辑一个书源」，这边全是列表页上的批量动作，一次动几十上百条，
// 都要求事务内完成。

// ── 分组 ────────────────────────────────────────────────────

// ListGroups 列出全部分组及组内书源数量。
func (s *SourceService) ListGroups(ctx context.Context) ([]dto.SourceGroupView, error) {
	groups, err := s.sources.Groups(ctx)
	if err != nil {
		return nil, err
	}
	return dto.NewSourceGroupViews(groups), nil
}

// AddGroupToNoGroup 把所有「没有分组」的书源归入指定分组。
//
// 这是原生分组管理里的「新增分组」：分组不是一个独立实体，只是书源上的
// 一个字段，所以「建一个空分组」在语义上等价于「把无分组源收拢进来」。
func (s *SourceService) AddGroupToNoGroup(ctx context.Context, group string) (int, error) {
	group = strings.TrimSpace(group)
	if group == "" {
		return 0, fmt.Errorf("%w: 分组名不能为空", domain.ErrInvalidArgument)
	}
	list, err := s.sources.List(ctx, "")
	if err != nil {
		return 0, err
	}
	changed := 0
	err = s.inTx(ctx, func(ctx context.Context) error {
		for _, src := range list {
			if len(domain.SplitGroups(src.Group)) > 0 {
				continue
			}
			if err := s.applyGroup(ctx, src, group); err != nil {
				return err
			}
			changed++
		}
		return nil
	})
	return changed, err
}

// RenameGroup 重命名分组；newName 为空表示把这些书源的分组清空。
func (s *SourceService) RenameGroup(ctx context.Context, oldName, newName string) error {
	oldName = strings.TrimSpace(oldName)
	newName = strings.TrimSpace(newName)
	if oldName == "" {
		return fmt.Errorf("%w: 分组名不能为空", domain.ErrInvalidArgument)
	}
	list, err := s.sources.List(ctx, "")
	if err != nil {
		return err
	}
	return s.inTx(ctx, func(ctx context.Context) error {
		for _, src := range list {
			if !domain.HasGroup(src.Group, oldName) {
				continue
			}
			next := domain.RenameGroup(src.Group, oldName, newName)
			if err := s.applyGroup(ctx, src, next); err != nil {
				return err
			}
		}
		return nil
	})
}

// DeleteGroup 删除分组（只清书源上的分组字段，不删书源）。
func (s *SourceService) DeleteGroup(ctx context.Context, name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("%w: 分组名不能为空", domain.ErrInvalidArgument)
	}
	return s.RenameGroup(ctx, name, "")
}

// AddToGroup 把选中书源加入分组。
func (s *SourceService) AddToGroup(ctx context.Context, ids []int64, group string) error {
	group = strings.TrimSpace(group)
	if group == "" {
		return fmt.Errorf("%w: 分组名不能为空", domain.ErrInvalidArgument)
	}
	list, err := s.loadSources(ctx, ids)
	if err != nil {
		return err
	}
	return s.inTx(ctx, func(ctx context.Context) error {
		for _, src := range list {
			if domain.HasGroup(src.Group, group) {
				continue
			}
			if err := s.applyGroup(ctx, src, domain.AddGroup(src.Group, group)); err != nil {
				return err
			}
		}
		return nil
	})
}

// RemoveFromGroup 把选中书源从分组中移除。
func (s *SourceService) RemoveFromGroup(ctx context.Context, ids []int64, group string) error {
	group = strings.TrimSpace(group)
	if group == "" {
		return fmt.Errorf("%w: 分组名不能为空", domain.ErrInvalidArgument)
	}
	list, err := s.loadSources(ctx, ids)
	if err != nil {
		return err
	}
	return s.inTx(ctx, func(ctx context.Context) error {
		for _, src := range list {
			if !domain.HasGroup(src.Group, group) {
				continue
			}
			if err := s.applyGroup(ctx, src, domain.RemoveGroup(src.Group, group)); err != nil {
				return err
			}
		}
		return nil
	})
}

// applyGroup 只改分组，并同步 Raw 里的 bookSourceGroup。
//
// 分组在两处存在：book_sources.group_name（列，供查询/分组菜单）与 Raw 里的
// bookSourceGroup（导出给其他 Legado 客户端时用）。只改一处会导致
// 「桌面端看着在 A 组，导出到手机却在 B 组」。
func (s *SourceService) applyGroup(ctx context.Context, src *domain.BookSource, group string) error {
	if src.Group == group {
		return nil
	}
	src.Group = group
	raw, err := domain.PatchSourceRaw(src.Raw, map[string]any{"bookSourceGroup": nullableString(group)})
	if err != nil {
		return err
	}
	src.Raw = raw
	return s.sources.Update(ctx, src)
}

// ── 批量启停 / 删除 ─────────────────────────────────────────

// SetEnabledBatch 批量启停书源。
func (s *SourceService) SetEnabledBatch(ctx context.Context, ids []int64, enabled bool) error {
	list, err := s.loadSources(ctx, ids)
	if err != nil {
		return err
	}
	return s.inTx(ctx, func(ctx context.Context) error {
		for _, src := range list {
			if src.Enabled == enabled {
				continue
			}
			src.Enabled = enabled
			if err := s.sources.Update(ctx, src); err != nil {
				return err
			}
		}
		return nil
	})
}

// SetEnabledExploreBatch 批量开/关「发现」。
//
// 与启用状态不同，enabledExplore 只存在 Raw 里（原生也是如此），
// 所以这里必须改写书源 JSON。
func (s *SourceService) SetEnabledExploreBatch(ctx context.Context, ids []int64, enabled bool) error {
	list, err := s.loadSources(ctx, ids)
	if err != nil {
		return err
	}
	return s.inTx(ctx, func(ctx context.Context) error {
		for _, src := range list {
			if src.Meta().EnabledExplore == enabled {
				continue
			}
			raw, err := domain.PatchSourceRaw(src.Raw, map[string]any{"enabledExplore": enabled})
			if err != nil {
				return err
			}
			src.Raw = raw
			if err := s.sources.Update(ctx, src); err != nil {
				return err
			}
		}
		return nil
	})
}

// DeleteBatch 批量删除书源。
func (s *SourceService) DeleteBatch(ctx context.Context, ids []int64) error {
	return s.inTx(ctx, func(ctx context.Context) error {
		for _, id := range ids {
			if err := s.sources.Delete(ctx, id); err != nil {
				// 已经被别的窗口删掉的不算失败：批量删除要幂等。
				if errors.Is(err, domain.ErrNotFound) {
					continue
				}
				return err
			}
		}
		return nil
	})
}

// ── 排序 ────────────────────────────────────────────────────

// MoveTop 把选中书源置顶。
//
// 与原生一致：按当前顺序取最小 Order 再往前排，保持选中项之间的相对顺序。
func (s *SourceService) MoveTop(ctx context.Context, ids []int64) error {
	list, err := s.sources.List(ctx, "")
	if err != nil {
		return err
	}
	picked := pickOrdered(list, ids)
	if len(picked) == 0 {
		return nil
	}
	minOrder := list[0].Order
	for _, src := range list {
		if src.Order < minOrder {
			minOrder = src.Order
		}
	}
	orders := make(map[int64]int, len(picked))
	for i, src := range picked {
		orders[src.ID] = minOrder - len(picked) + i
	}
	return s.sources.UpdateOrders(ctx, orders)
}

// MoveBottom 把选中书源置底。
func (s *SourceService) MoveBottom(ctx context.Context, ids []int64) error {
	list, err := s.sources.List(ctx, "")
	if err != nil {
		return err
	}
	picked := pickOrdered(list, ids)
	if len(picked) == 0 {
		return nil
	}
	maxOrder := list[0].Order
	for _, src := range list {
		if src.Order > maxOrder {
			maxOrder = src.Order
		}
	}
	orders := make(map[int64]int, len(picked))
	for i, src := range picked {
		orders[src.ID] = maxOrder + 1 + i
	}
	return s.sources.UpdateOrders(ctx, orders)
}

// Reorder 按给定顺序重排书源。
//
// ids 是用户拖拽后的完整顺序（当前列表可见的那部分）。未出现在 ids 里的
// 书源保持原有相对顺序，统一追加在后——这样即使界面处于「分组筛选」状态，
// 拖拽也不会打乱看不见的书源之间的次序。
func (s *SourceService) Reorder(ctx context.Context, ids []int64) error {
	if len(ids) == 0 {
		return nil
	}
	list, err := s.sources.List(ctx, "")
	if err != nil {
		return err
	}
	byID := make(map[int64]*domain.BookSource, len(list))
	for _, src := range list {
		byID[src.ID] = src
	}

	orders := make(map[int64]int, len(list))
	next := 0
	for _, id := range ids {
		if _, ok := byID[id]; !ok {
			continue
		}
		orders[id] = next
		next++
	}
	for _, src := range list {
		if _, done := orders[src.ID]; done {
			continue
		}
		orders[src.ID] = next
		next++
	}
	return s.sources.UpdateOrders(ctx, orders)
}

// ── 源变量 ──────────────────────────────────────────────────

// GetVariable 读取书源变量。
func (s *SourceService) GetVariable(ctx context.Context, id int64) (dto.SourceVariableView, error) {
	src, err := s.sources.Get(ctx, id)
	if err != nil {
		return dto.SourceVariableView{}, err
	}
	out := dto.SourceVariableView{SourceID: src.ID, Name: src.Name, URL: src.URL, Comment: src.Meta().VariableComment}
	if s.vars != nil {
		v, err := s.vars.Get(ctx, src.URL)
		if err != nil {
			return out, err
		}
		out.Variable = v
	}
	return out, nil
}

// SetVariable 写入书源变量；传空串等于清除。
func (s *SourceService) SetVariable(ctx context.Context, id int64, variable string) error {
	src, err := s.sources.Get(ctx, id)
	if err != nil {
		return err
	}
	if s.vars == nil {
		return fmt.Errorf("%w: 未配置书源变量存储", domain.ErrNotConfigured)
	}
	if strings.TrimSpace(variable) == "" {
		return s.vars.Delete(ctx, src.URL)
	}
	return s.vars.Put(ctx, src.URL, variable)
}

// ── 会话 ────────────────────────────────────────────────────

// ClearCookie 清除书源站点的 Cookie（原生编辑页的「清除 Cookie」菜单）。
//
// 场景：书源的登录态脏了（站点改版、会话过期后残留了半套 Cookie），
// 表现为「明明登录了却一直提示未登录」，这时必须先清干净再重新登录。
func (s *SourceService) ClearCookie(ctx context.Context, id int64) error {
	src, err := s.sources.Get(ctx, id)
	if err != nil {
		return err
	}
	if s.session == nil {
		return fmt.Errorf("%w: 未配置书源会话", domain.ErrNotConfigured)
	}
	return s.session.ClearCookie(src.URL)
}

// ── 内部辅助 ────────────────────────────────────────────────

// loadSources 按 id 批量取书源，顺带填充源变量（抓取/调试要用）。
func (s *SourceService) loadSources(ctx context.Context, ids []int64) ([]*domain.BookSource, error) {
	if len(ids) == 0 {
		return nil, fmt.Errorf("%w: 未选择书源", domain.ErrInvalidArgument)
	}
	out := make([]*domain.BookSource, 0, len(ids))
	for _, id := range ids {
		src, err := s.loadSource(ctx, id)
		if err != nil {
			if errors.Is(err, domain.ErrNotFound) {
				continue
			}
			return nil, err
		}
		out = append(out, src)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%w: 未找到书源", domain.ErrNotFound)
	}
	return out, nil
}

// loadSource 取单个书源并填充源变量。
func (s *SourceService) loadSource(ctx context.Context, id int64) (*domain.BookSource, error) {
	src, err := s.sources.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	s.attachVariable(ctx, src)
	return src, nil
}

// attachVariable 把 source_variables 里的变量挂到实体上。
//
// 失败不阻断：源变量只是书源 JS 的可选输入，读不到就当没设过，
// 不该让整次搜索/校验失败。
func (s *SourceService) attachVariable(ctx context.Context, src *domain.BookSource) {
	if s.vars == nil || src == nil {
		return
	}
	if v, err := s.vars.Get(ctx, src.URL); err == nil {
		src.Variable = v
	}
}

// pickOrdered 按 list 的现有顺序挑出 ids 命中的书源。
func pickOrdered(list []*domain.BookSource, ids []int64) []*domain.BookSource {
	want := make(map[int64]struct{}, len(ids))
	for _, id := range ids {
		want[id] = struct{}{}
	}
	out := make([]*domain.BookSource, 0, len(ids))
	for _, src := range list {
		if _, ok := want[src.ID]; ok {
			out = append(out, src)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Order < out[j].Order })
	return out
}

// inTx 在事务内执行；未注入工作单元时退化为顺序执行（单测场景）。
func (s *SourceService) inTx(ctx context.Context, fn func(context.Context) error) error {
	if s.uow == nil {
		return fn(ctx)
	}
	return s.uow.Do(ctx, fn)
}

// nullableString 把空串写成 JSON null，与 Legado 导出格式一致
// （bookSourceGroup 为空时原生写 null 而不是 ""）。
func nullableString(s string) any {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}
