package rss

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/legado/core/adapters/persistence/sqlite"
	"github.com/legado/core/adapters/rssparse"
	"github.com/legado/core/kernel"
)

const (
	// defaultUA 与 core/app 的订阅同步保持一致：不少站点会对默认 Go UA 返回 403。
	defaultUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
		"(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

	fetchTimeout = 15 * time.Second
	// maxFeedBytes 是单次拉取上限。订阅源偶有把整站导出成 XML 的情况，
	// 不设上限会让进程被一个坏源拖垮。
	maxFeedBytes = 8 << 20

	defaultLimit = 50
	maxLimit     = 500
)

// Service 是 RSS 域的业务实现。只碰 rss_source / rss_article 两张表。
type Service struct {
	db *sqlite.DB
	ua string
	hc *http.Client
}

// NewService 构造服务。ua 为空时使用内置桌面浏览器 UA。
func NewService(db *sqlite.DB, ua string) *Service {
	if strings.TrimSpace(ua) == "" {
		ua = defaultUA
	}
	return &Service{
		db: db,
		ua: ua,
		hc: &http.Client{Timeout: fetchTimeout},
	}
}

// ListSources 列出全部订阅源，按用户排序与 id 稳定排列。
func (s *Service) ListSources(ctx context.Context) ([]Source, error) {
	rows, err := s.db.Query(ctx, `SELECT s.id, s.name, s.url, s.group_name, s.enabled, s.sort_order,
			s.created_at, s.updated_at,
			(SELECT COUNT(1) FROM rss_article a WHERE a.source_id = s.id AND a.read = 0)
		FROM rss_source s
		ORDER BY s.sort_order, s.id`)
	if err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "查询订阅源失败: %v", err)
	}
	defer rows.Close()

	out := make([]Source, 0, 16)
	for rows.Next() {
		var src Source
		if err := rows.Scan(&src.ID, &src.Name, &src.URL, &src.Group, &src.Enabled,
			&src.SortOrder, &src.CreatedAt, &src.UpdatedAt, &src.UnreadCount); err != nil {
			return nil, kernel.Ef(kernel.CodeInternal, "读取订阅源失败: %v", err)
		}
		out = append(out, src)
	}
	if err := rows.Err(); err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "遍历订阅源失败: %v", err)
	}
	return out, nil
}

// SaveSource 新增或更新订阅源（幂等 upsert）；id 为 0 表示新增。
func (s *Service) SaveSource(ctx context.Context, in SourceInput) (Source, error) {
	link := strings.TrimSpace(in.URL)
	if err := validateFeedURL(link); err != nil {
		return Source{}, err
	}
	name := strings.TrimSpace(in.Name)
	if name == "" {
		// 名字是 UI 上唯一能区分的字段，留空会让列表出现一片空白项。
		name = link
	}
	group := strings.TrimSpace(in.Group)

	if in.ID == 0 {
		enabled := true
		if in.Enabled != nil {
			enabled = *in.Enabled
		}
		res, err := s.db.Execute(ctx,
			`INSERT INTO rss_source (name, url, group_name, enabled, sort_order) VALUES (?, ?, ?, ?, ?)`,
			name, link, group, enabled, in.SortOrder)
		if err != nil {
			return Source{}, kernel.Ef(kernel.CodeInternal, "新增订阅源失败: %v", err)
		}
		id, err := res.LastInsertId()
		if err != nil {
			return Source{}, kernel.Ef(kernel.CodeInternal, "获取订阅源 id 失败: %v", err)
		}
		return s.GetSource(ctx, id)
	}

	cur, err := s.GetSource(ctx, in.ID)
	if err != nil {
		return Source{}, err
	}
	enabled := cur.Enabled
	if in.Enabled != nil {
		enabled = *in.Enabled
	}
	// updated_at 由这里维护，避免依赖调用方传时间（时钟以数据库为准）。
	if _, err := s.db.Execute(ctx,
		`UPDATE rss_source SET name = ?, url = ?, group_name = ?, enabled = ?, sort_order = ?,
			updated_at = unixepoch() WHERE id = ?`,
		name, link, group, enabled, in.SortOrder, in.ID); err != nil {
		return Source{}, kernel.Ef(kernel.CodeInternal, "更新订阅源失败: %v", err)
	}
	return s.GetSource(ctx, in.ID)
}

// GetSource 读取单个订阅源。
func (s *Service) GetSource(ctx context.Context, id int64) (Source, error) {
	var src Source
	err := s.db.QueryRow(ctx, `SELECT s.id, s.name, s.url, s.group_name, s.enabled, s.sort_order,
			s.created_at, s.updated_at,
			(SELECT COUNT(1) FROM rss_article a WHERE a.source_id = s.id AND a.read = 0)
		FROM rss_source s WHERE s.id = ?`, id).
		Scan(&src.ID, &src.Name, &src.URL, &src.Group, &src.Enabled,
			&src.SortOrder, &src.CreatedAt, &src.UpdatedAt, &src.UnreadCount)
	if errors.Is(err, sql.ErrNoRows) {
		return Source{}, kernel.Ef(kernel.CodeNotFound, "订阅源不存在: %d", id)
	}
	if err != nil {
		return Source{}, kernel.Ef(kernel.CodeInternal, "查询订阅源失败: %v", err)
	}
	return src, nil
}

// DeleteSource 删除订阅源，并连带删除它的文章。
//
// 表上没有外键（模块表各自管理，不互相约束），所以级联只能在这里做；
// 留下孤儿文章既占空间，也会让未读统计出现无主条目。
func (s *Service) DeleteSource(ctx context.Context, id int64) error {
	return s.db.Do(ctx, func(ctx context.Context) error {
		if _, err := s.db.Execute(ctx, `DELETE FROM rss_article WHERE source_id = ?`, id); err != nil {
			return kernel.Ef(kernel.CodeInternal, "删除订阅文章失败: %v", err)
		}
		res, err := s.db.Execute(ctx, `DELETE FROM rss_source WHERE id = ?`, id)
		if err != nil {
			return kernel.Ef(kernel.CodeInternal, "删除订阅源失败: %v", err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return kernel.Ef(kernel.CodeInternal, "删除订阅源失败: %v", err)
		}
		if n == 0 {
			return kernel.Ef(kernel.CodeNotFound, "订阅源不存在: %d", id)
		}
		return nil
	})
}

// SetEnabled 启停订阅源。停用的源不参与「刷新全部」。
func (s *Service) SetEnabled(ctx context.Context, id int64, enabled bool) error {
	res, err := s.db.Execute(ctx,
		`UPDATE rss_source SET enabled = ?, updated_at = unixepoch() WHERE id = ?`, enabled, id)
	if err != nil {
		return kernel.Ef(kernel.CodeInternal, "更新订阅源状态失败: %v", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return kernel.Ef(kernel.CodeInternal, "更新订阅源状态失败: %v", err)
	}
	if n == 0 {
		return kernel.Ef(kernel.CodeNotFound, "订阅源不存在: %d", id)
	}
	return nil
}

// RefreshSource 拉取单个源。显式调用时即使源已停用也执行 ——
// 用户点「刷新这个源」的意图比开关状态更具体。
func (s *Service) RefreshSource(ctx context.Context, id int64) (*RefreshResult, error) {
	src, err := s.GetSource(ctx, id)
	if err != nil {
		return nil, err
	}
	return s.refreshOne(ctx, src)
}

// RefreshAll 刷新全部启用的源；单个源失败只记入 Errors，不影响其余源。
func (s *Service) RefreshAll(ctx context.Context) (*RefreshResult, error) {
	rows, err := s.db.Query(ctx, `SELECT id, name, url, group_name, enabled, sort_order,
			created_at, updated_at, 0 FROM rss_source WHERE enabled = 1 ORDER BY sort_order, id`)
	if err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "查询启用的订阅源失败: %v", err)
	}
	defer rows.Close()

	var sources []Source
	for rows.Next() {
		var src Source
		if err := rows.Scan(&src.ID, &src.Name, &src.URL, &src.Group, &src.Enabled,
			&src.SortOrder, &src.CreatedAt, &src.UpdatedAt, &src.UnreadCount); err != nil {
			return nil, kernel.Ef(kernel.CodeInternal, "读取订阅源失败: %v", err)
		}
		sources = append(sources, src)
	}
	if err := rows.Err(); err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "遍历订阅源失败: %v", err)
	}

	total := &RefreshResult{Sources: len(sources)}
	for _, src := range sources {
		one, err := s.refreshOne(ctx, src)
		if err != nil {
			total.Errors = append(total.Errors, fmt.Sprintf("%s: %v", src.Name, err))
			continue
		}
		total.Added += one.Added
		total.Updated += one.Updated
		total.Skipped += one.Skipped
	}
	return total, nil
}

// refreshOne 是单源拉取的核心：抓取 → 解析 → 去重入库，整体一个事务。
func (s *Service) refreshOne(ctx context.Context, src Source) (*RefreshResult, error) {
	data, err := s.fetch(ctx, src.URL)
	if err != nil {
		return nil, err
	}
	feed, err := rssparse.Parse(data)
	if err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "解析订阅源 %s 失败: %v", src.Name, err)
	}

	result := &RefreshResult{SourceID: src.ID, Sources: 1}
	err = s.db.Do(ctx, func(ctx context.Context) error {
		for _, it := range feed.Items {
			link := rssparse.ResolveURL(src.URL, it.Link)
			if link == "" {
				// 没有链接就无法去重；宁可跳过，也不要把 N 条空链接折叠成一条。
				result.Skipped++
				continue
			}
			title := strings.TrimSpace(it.Title)
			if title == "" {
				title = link
			}
			added, err := s.upsertArticle(ctx, src.ID, title, link, it)
			if err != nil {
				return err
			}
			if added {
				result.Added++
			} else {
				result.Updated++
			}
		}
		// 刷新成功才更新时间：失败的时间戳会误导用户以为刚同步过。
		_, err := s.db.Execute(ctx, `UPDATE rss_source SET updated_at = unixepoch() WHERE id = ?`, src.ID)
		return err
	})
	if err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "保存订阅文章失败: %v", err)
	}
	return result, nil
}

// upsertArticle 按 (source_id, link) 去重。
//
// 更新时刻意不写 read / favorite：这两个字段是用户状态，
// 源站改一次标题不能把「已读」重置掉。
func (s *Service) upsertArticle(ctx context.Context, sourceID int64, title, link string, it rssparse.Item) (bool, error) {
	var pubDate int64
	if !it.PubDate.IsZero() {
		pubDate = it.PubDate.Unix()
	}

	var id int64
	err := s.db.QueryRow(ctx,
		`SELECT id FROM rss_article WHERE source_id = ? AND link = ?`, sourceID, link).Scan(&id)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		_, err := s.db.Execute(ctx,
			`INSERT INTO rss_article (source_id, title, link, description, content, author, pub_date)
			 VALUES (?, ?, ?, ?, ?, ?, ?)`,
			sourceID, title, link, it.Description, it.Content, it.Author, pubDate)
		return true, err
	case err != nil:
		return false, err
	default:
		_, err := s.db.Execute(ctx,
			`UPDATE rss_article SET title = ?, description = ?, content = ?, author = ?, pub_date = ?
			 WHERE id = ?`,
			title, it.Description, it.Content, it.Author, pubDate, id)
		return false, err
	}
}

// ListArticles 按发布时间倒序列出文章。sourceId 为 0 表示全部源。
func (s *Service) ListArticles(ctx context.Context, sourceID int64, onlyUnread bool, offset, limit int) ([]Article, error) {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 {
		limit = defaultLimit
	}
	if limit > maxLimit {
		limit = maxLimit
	}
	unread := 0
	if onlyUnread {
		unread = 1
	}

	rows, err := s.db.Query(ctx, `SELECT a.id, a.source_id, s.name, a.title, a.link, a.description,
			a.content, a.author, a.pub_date, a.read, a.favorite, a.created_at
		FROM rss_article a
		JOIN rss_source s ON s.id = a.source_id
		WHERE (? = 0 OR a.source_id = ?) AND (? = 0 OR a.read = 0)
		ORDER BY a.pub_date DESC, a.id DESC
		LIMIT ? OFFSET ?`, sourceID, sourceID, unread, limit, offset)
	if err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "查询订阅文章失败: %v", err)
	}
	defer rows.Close()
	return scanArticles(rows)
}

// MarkRead 设置单篇文章的已读状态。
func (s *Service) MarkRead(ctx context.Context, id int64, read bool) error {
	res, err := s.db.Execute(ctx, `UPDATE rss_article SET read = ? WHERE id = ?`, read, id)
	if err != nil {
		return kernel.Ef(kernel.CodeInternal, "更新已读状态失败: %v", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return kernel.Ef(kernel.CodeInternal, "更新已读状态失败: %v", err)
	}
	if n == 0 {
		return kernel.Ef(kernel.CodeNotFound, "订阅文章不存在: %d", id)
	}
	return nil
}

// ToggleFavorite 切换收藏并返回新状态，省掉调用方再查一次。
func (s *Service) ToggleFavorite(ctx context.Context, id int64) (bool, error) {
	res, err := s.db.Execute(ctx,
		`UPDATE rss_article SET favorite = CASE favorite WHEN 0 THEN 1 ELSE 0 END WHERE id = ?`, id)
	if err != nil {
		return false, kernel.Ef(kernel.CodeInternal, "切换收藏失败: %v", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, kernel.Ef(kernel.CodeInternal, "切换收藏失败: %v", err)
	}
	if n == 0 {
		return false, kernel.Ef(kernel.CodeNotFound, "订阅文章不存在: %d", id)
	}
	var favorite bool
	if err := s.db.QueryRow(ctx, `SELECT favorite FROM rss_article WHERE id = ?`, id).Scan(&favorite); err != nil {
		return false, kernel.Ef(kernel.CodeInternal, "读取收藏状态失败: %v", err)
	}
	return favorite, nil
}

// ListFavorites 列出全部收藏文章。
func (s *Service) ListFavorites(ctx context.Context) ([]Article, error) {
	rows, err := s.db.Query(ctx, `SELECT a.id, a.source_id, s.name, a.title, a.link, a.description,
			a.content, a.author, a.pub_date, a.read, a.favorite, a.created_at
		FROM rss_article a
		JOIN rss_source s ON s.id = a.source_id
		WHERE a.favorite = 1
		ORDER BY a.pub_date DESC, a.id DESC`)
	if err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "查询收藏文章失败: %v", err)
	}
	defer rows.Close()
	return scanArticles(rows)
}

// UnreadCount 按源聚合未读数；没有未读的源不会出现在结果里。
func (s *Service) UnreadCount(ctx context.Context) (map[int64]int, error) {
	rows, err := s.db.Query(ctx,
		`SELECT source_id, COUNT(1) FROM rss_article WHERE read = 0 GROUP BY source_id`)
	if err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "统计未读失败: %v", err)
	}
	defer rows.Close()

	out := make(map[int64]int)
	for rows.Next() {
		var sourceID int64
		var n int
		if err := rows.Scan(&sourceID, &n); err != nil {
			return nil, kernel.Ef(kernel.CodeInternal, "读取未读统计失败: %v", err)
		}
		out[sourceID] = n
	}
	if err := rows.Err(); err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "遍历未读统计失败: %v", err)
	}
	return out, nil
}

func scanArticles(rows *sql.Rows) ([]Article, error) {
	out := make([]Article, 0, 32)
	for rows.Next() {
		var a Article
		if err := rows.Scan(&a.ID, &a.SourceID, &a.SourceName, &a.Title, &a.Link,
			&a.Description, &a.Content, &a.Author, &a.PubDate, &a.Read, &a.Favorite, &a.CreatedAt); err != nil {
			return nil, kernel.Ef(kernel.CodeInternal, "读取订阅文章失败: %v", err)
		}
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "遍历订阅文章失败: %v", err)
	}
	return out, nil
}

// fetch 抓取订阅源字节。错误带码，便于 UI 区分超时与普通失败。
func (s *Service) fetch(ctx context.Context, link string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, link, nil)
	if err != nil {
		return nil, kernel.Ef(kernel.CodeInvalid, "订阅地址无效: %v", err)
	}
	req.Header.Set("User-Agent", s.ua)
	req.Header.Set("Accept", "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.9, */*;q=0.8")

	resp, err := s.hc.Do(req)
	if err != nil {
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			return nil, kernel.Ef(kernel.CodeNetTimeout, "拉取订阅超时: %s", link)
		}
		return nil, kernel.Ef(kernel.CodeInternal, "拉取订阅失败: %v", err)
	}
	defer resp.Body.Close() //nolint:errcheck // 只读响应，关闭错误无意义

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, kernel.Ef(kernel.CodeInternal, "拉取订阅失败: %s 返回 HTTP %d", link, resp.StatusCode)
	}
	// 多读 1 字节用于判断是否超限，避免把整份超大响应读进内存。
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxFeedBytes+1))
	if err != nil {
		return nil, kernel.Ef(kernel.CodeInternal, "读取订阅内容失败: %v", err)
	}
	if len(data) > maxFeedBytes {
		return nil, kernel.Ef(kernel.CodeInternal, "订阅内容超过 %d 字节上限", maxFeedBytes)
	}
	return data, nil
}

// validateFeedURL 只接受 http(s)：本地文件、file:// 等协议会让「添加订阅」
// 变成任意文件读取入口。
func validateFeedURL(raw string) error {
	if raw == "" {
		return kernel.E(kernel.CodeInvalid, "订阅地址不能为空")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return kernel.Ef(kernel.CodeInvalid, "订阅地址无效: %v", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return kernel.Ef(kernel.CodeInvalid, "订阅地址必须是 http(s): %s", raw)
	}
	if u.Host == "" {
		return kernel.Ef(kernel.CodeInvalid, "订阅地址缺少主机名: %s", raw)
	}
	return nil
}
