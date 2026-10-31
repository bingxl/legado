package app

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
)

// 订阅同步是一次普通的 HTTP GET，与书源引擎无关，
// 因此这里直接用标准库，不往 SourceFetcher 上再加一个「随便抓个 URL」的方法。
const (
	subscriptionTimeout = 30 * time.Second
	// subscriptionUA 与书源抓取保持一致，避免个别站点对默认 Go UA 返回 403。
	subscriptionUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

// ListSubscriptions 列出全部书源订阅。
func (s *SourceService) ListSubscriptions(ctx context.Context) ([]dto.SubscriptionView, error) {
	list, err := s.subs.List(ctx)
	if err != nil {
		return nil, err
	}
	return dto.NewSubscriptionViews(list), nil
}

// GetSubscription 获取单个订阅。
func (s *SourceService) GetSubscription(ctx context.Context, id int64) (dto.SubscriptionView, error) {
	sub, err := s.subs.Get(ctx, id)
	if err != nil {
		return dto.SubscriptionView{}, err
	}
	return dto.NewSubscriptionView(sub), nil
}

// SaveSubscription 新增或更新订阅；id 为 0 表示新增。
func (s *SourceService) SaveSubscription(ctx context.Context, id int64, name, url string, enabled bool, order int) (dto.SubscriptionView, error) {
	url = strings.TrimSpace(url)
	if url == "" {
		return dto.SubscriptionView{}, fmt.Errorf("%w: 订阅地址不能为空", domain.ErrInvalidArgument)
	}
	if name == "" {
		name = url
	}

	if id == 0 {
		sub := &domain.SourceSubscription{
			Name:    name,
			URL:     url,
			Enabled: enabled,
			Order:   order,
		}
		if err := s.subs.Create(ctx, sub); err != nil {
			return dto.SubscriptionView{}, err
		}
		return dto.NewSubscriptionView(sub), nil
	}

	sub, err := s.subs.Get(ctx, id)
	if err != nil {
		return dto.SubscriptionView{}, err
	}
	sub.Name = name
	sub.URL = url
	sub.Enabled = enabled
	sub.Order = order
	if err := s.subs.Update(ctx, sub); err != nil {
		return dto.SubscriptionView{}, err
	}
	return dto.NewSubscriptionView(sub), nil
}

// DeleteSubscription 删除订阅。删除订阅不会连带删除它导入过的书源——
// 用户退订通常只是不想再更新，已有的书源还要继续用。
func (s *SourceService) DeleteSubscription(ctx context.Context, id int64) error {
	return s.subs.Delete(ctx, id)
}

// SetSubscriptionEnabled 启停订阅。停用的订阅不参与「全部刷新」。
func (s *SourceService) SetSubscriptionEnabled(ctx context.Context, id int64, enabled bool) error {
	sub, err := s.subs.Get(ctx, id)
	if err != nil {
		return err
	}
	sub.Enabled = enabled
	return s.subs.Update(ctx, sub)
}

// SyncSubscription 拉取某个订阅的远程书源并入库。
//
// 返回值复用书源导入结果：一次订阅刷新本质上就是「从一个 URL 导入书源」，
// 让前端看到的新增/更新/失败条数与导入页保持一致的语义。
func (s *SourceService) SyncSubscription(ctx context.Context, id int64) (*dto.SourceImportResult, error) {
	sub, err := s.subs.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	data, err := httpGet(ctx, sub.URL)
	if err != nil {
		return nil, err
	}
	// 订阅刷新必然是覆盖语义：远程就是唯一事实来源，
	// 同名书源不更新的话，订阅就永远修不了坏源。
	result, err := s.Import(ctx, data, true)
	if err != nil {
		return nil, err
	}
	sub.LastSyncAt = time.Now()
	// 同步时间写不回去不影响本次结果（书源已经入库），只记日志级别的错误，
	// 这里选择忽略：下次同步会再写一次。
	_ = s.subs.Update(ctx, sub)
	return result, nil
}

// SyncAllSubscriptions 刷新全部启用的订阅，返回每个订阅的结果。
//
// 逐条同步而非并发：订阅源通常十几个，并发带来的收益有限，
// 却会让进度事件乱序、失败归因困难。
func (s *SourceService) SyncAllSubscriptions(ctx context.Context) ([]dto.SubscriptionSyncResult, error) {
	list, err := s.subs.List(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]dto.SubscriptionSyncResult, 0, len(list))
	for _, sub := range list {
		if !sub.Enabled {
			continue
		}
		item := dto.SubscriptionSyncResult{
			SubscriptionID:   sub.ID,
			SubscriptionName: sub.Name,
		}
		result, err := s.SyncSubscription(ctx, sub.ID)
		if err != nil {
			item.Error = err.Error()
			out = append(out, item)
			continue
		}
		item.Imported = result.Imported
		item.Updated = result.Updated
		item.Failed = len(result.Failures)
		out = append(out, item)
	}
	return out, nil
}

// httpGet 取回 URL 内容。超时是硬性的：订阅地址失效时，
// 没有超时会让 UI 一直转圈到 TCP 层放弃（默认可能几十秒）。
func httpGet(ctx context.Context, url string) ([]byte, error) {
	if url == "" {
		return nil, fmt.Errorf("%w: 订阅地址为空", domain.ErrInvalidArgument)
	}
	reqCtx, cancel := context.WithTimeout(ctx, subscriptionTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("%w: 订阅地址不合法: %v", domain.ErrInvalidArgument, err)
	}
	req.Header.Set("User-Agent", subscriptionUA)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: 拉取订阅失败: %v", domain.ErrRemoteFailed, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%w: 订阅返回 HTTP %d", domain.ErrRemoteFailed, resp.StatusCode)
	}
	// 订阅文件通常几十 KB，但恶意地址可能返回巨大响应，限制在 32MB 以内。
	data, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return nil, fmt.Errorf("%w: 读取订阅内容失败: %v", domain.ErrRemoteFailed, err)
	}
	return data, nil
}
