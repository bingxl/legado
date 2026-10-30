package app

import (
	"context"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// 缓存任务的并行度。
//
// 取 3 是权衡后的结果：书源普遍对高频请求限速甚至封 IP，单线程缓存一整本
// 几千章的书要按小时算；再往上加又会明显提高被源站拒绝的概率。
const cacheWorkers = 3

// 单章的超时。抓取一章（含漫画的几十张图）理应在一分钟内结束，
// 卡住时必须放弃，否则整个任务会停在某一章上不动。
const cacheChapterTimeout = 90 * time.Second

// 等待任务真正退出的上限，用于「删除缓存前先停掉正在写的任务」。
const cacheStopTimeout = 5 * time.Second

// CacheService 负责章节内容的手动缓存与缓存管理。
//
// 设计要点：
//  1. 缓存是**手动触发**的：不在阅读时顺手写盘，用户看到的磁盘占用
//     完全等于自己点过的那些操作；
//  2. 任务是后台goroutine + 进度事件，绑定方法立即返回，
//     几千章的书不会把前端调用挂死；
//  3. 同一本书同时只允许一个任务，重复点击直接拒绝而不是排队；
//  4. 漫画的图片落盘，文本的正文入库（见 domain.CachedChapter）。
type CacheService struct {
	root     string
	books    port.BookRepository
	chapters port.ChapterRepository
	cache    port.ChapterCacheRepository
	content  *ContentProvider
	images   port.ImageDownloader
	events   port.EventBus

	mu     sync.Mutex
	jobs   map[int64]*cacheJob
	closed bool
}

// CacheDeps 聚合缓存服务的依赖。
type CacheDeps struct {
	// Root 是应用数据目录；图片缓存写到 <Root>/cache/chapter/ 下。
	Root     string
	Books    port.BookRepository
	Chapters port.ChapterRepository
	Cache    port.ChapterCacheRepository
	Content  *ContentProvider
	Images   port.ImageDownloader
	Events   port.EventBus
}

// NewCacheService 构造缓存服务。
func NewCacheService(d CacheDeps) *CacheService {
	return &CacheService{
		root:     d.Root,
		books:    d.Books,
		chapters: d.Chapters,
		cache:    d.Cache,
		content:  d.Content,
		images:   d.Images,
		events:   d.Events,
		jobs:     make(map[int64]*cacheJob),
	}
}

// cacheJob 是运行中的缓存任务。
//
// 除 done 通道外，所有字段都在 CacheService.mu 保护下读写。
type cacheJob struct {
	bookID   int64
	bookName string
	scope    string
	total    int
	done     int
	failed   int
	state    string
	current  string
	lastErr  string
	started  time.Time
	finished time.Time
	cancel   context.CancelFunc
	doneCh   chan struct{}
}

// snapshot 生成任务快照。调用方必须持有 CacheService.mu。
func (j *cacheJob) snapshot() dto.CacheJob {
	var finished *time.Time
	if !j.finished.IsZero() {
		t := j.finished
		finished = &t
	}
	msg := j.current
	if j.lastErr != "" {
		msg = j.lastErr
	}
	return dto.CacheJob{
		BookID:     j.bookID,
		BookName:   j.bookName,
		Scope:      j.scope,
		State:      j.state,
		Total:      j.total,
		Done:       j.done,
		Failed:     j.failed,
		Message:    msg,
		StartedAt:  j.started,
		FinishedAt: finished,
	}
}

// Start 启动一次缓存任务。
//
// scope 取 dto.CacheScopeAll / Remaining / Missing / Chapters；
// 仅 scope == Chapters 时使用 indexes。
func (s *CacheService) Start(ctx context.Context, bookID int64, scope string, indexes []int) (dto.CacheJob, error) {
	if bookID == 0 {
		return dto.CacheJob{}, fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	if s.cache == nil || s.content == nil {
		return dto.CacheJob{}, fmt.Errorf("%w: 未配置缓存能力", domain.ErrNotConfigured)
	}
	book, err := s.books.Get(ctx, bookID)
	if err != nil {
		return dto.CacheJob{}, err
	}
	if book.IsLocal() {
		return dto.CacheJob{}, fmt.Errorf("%w: 本地书本身就是本地文件，无需缓存", domain.ErrInvalidArgument)
	}
	chapters, err := s.chapters.List(ctx, bookID)
	if err != nil {
		return dto.CacheJob{}, fmt.Errorf("读取目录失败: %w", err)
	}
	if len(chapters) == 0 {
		return dto.CacheJob{}, fmt.Errorf("%w: 这本书还没有目录", domain.ErrInvalidArgument)
	}

	targets, err := s.pickTargets(ctx, book, chapters, scope, indexes)
	if err != nil {
		return dto.CacheJob{}, err
	}
	if len(targets) == 0 {
		return dto.CacheJob{}, fmt.Errorf("%w: 没有需要缓存的章节", domain.ErrInvalidArgument)
	}
	return s.startJob(book, scope, targets)
}

// pickTargets 按范围挑出待缓存的章节序号。
func (s *CacheService) pickTargets(ctx context.Context, book *domain.Book, chapters []*domain.BookChapter, scope string, indexes []int) ([]int, error) {
	// 分卷标题不是正文，缓存它只会得到一堆失败。
	readable := make(map[int]*domain.BookChapter, len(chapters))
	ordered := make([]int, 0, len(chapters))
	for _, c := range chapters {
		if c.IsVolume {
			continue
		}
		readable[c.Index] = c
		ordered = append(ordered, c.Index)
	}
	sort.Ints(ordered)

	switch scope {
	case dto.CacheScopeAll:
		return ordered, nil

	case dto.CacheScopeRemaining:
		start := book.DurChapterIndex
		if start < 0 {
			start = 0
		}
		out := make([]int, 0, len(ordered))
		for _, idx := range ordered {
			if idx >= start {
				out = append(out, idx)
			}
		}
		if len(out) == 0 {
			// 进度已到末尾（或越界）时退化为整本，比直接报「没有需要缓存的章节」有用。
			return ordered, nil
		}
		return out, nil

	case dto.CacheScopeMissing:
		cached, err := s.cache.Indexes(ctx, book.ID)
		if err != nil {
			return nil, fmt.Errorf("读取已有缓存失败: %w", err)
		}
		has := make(map[int]struct{}, len(cached))
		for _, idx := range cached {
			has[idx] = struct{}{}
		}
		out := make([]int, 0, len(ordered))
		for _, idx := range ordered {
			if _, ok := has[idx]; !ok {
				out = append(out, idx)
			}
		}
		return out, nil

	case dto.CacheScopeChapters:
		if len(indexes) == 0 {
			return nil, fmt.Errorf("%w: 未指定要缓存的章节", domain.ErrInvalidArgument)
		}
		seen := make(map[int]struct{}, len(indexes))
		out := make([]int, 0, len(indexes))
		for _, idx := range indexes {
			if _, ok := readable[idx]; !ok {
				continue
			}
			if _, dup := seen[idx]; dup {
				continue
			}
			seen[idx] = struct{}{}
			out = append(out, idx)
		}
		sort.Ints(out)
		return out, nil
	}
	return nil, fmt.Errorf("%w: 未知的缓存范围 %q", domain.ErrInvalidArgument, scope)
}

// startJob 登记任务并启动后台协程。
func (s *CacheService) startJob(book *domain.Book, scope string, indexes []int) (dto.CacheJob, error) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return dto.CacheJob{}, fmt.Errorf("%w: 应用正在退出", domain.ErrNotConfigured)
	}
	if old, ok := s.jobs[book.ID]; ok && old.state == dto.CacheStateRunning {
		s.mu.Unlock()
		return dto.CacheJob{}, fmt.Errorf("%w: 《%s》正在缓存中", domain.ErrInvalidArgument, book.Name)
	}

	// 任务上下文与请求无关：绑定方法返回后请求 ctx 就被取消，
	// 而缓存要一直跑到结束，因此用 Background 派生、由 Cancel 显式取消。
	ctx, cancel := context.WithCancel(context.Background())
	job := &cacheJob{
		bookID:   book.ID,
		bookName: book.Name,
		scope:    scope,
		total:    len(indexes),
		state:    dto.CacheStateRunning,
		started:  time.Now(),
		cancel:   cancel,
		doneCh:   make(chan struct{}),
	}
	s.jobs[book.ID] = job
	snap := job.snapshot()
	s.mu.Unlock()

	s.emit(job, dto.CacheProgress{State: dto.CacheStateRunning})
	go s.run(job, book, indexes, ctx)
	return snap, nil
}

// run 是任务主体：固定数量的 worker 消费章节队列。
func (s *CacheService) run(job *cacheJob, book *domain.Book, indexes []int, ctx context.Context) {
	queue := make(chan int)
	var wg sync.WaitGroup
	for i := 0; i < cacheWorkers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for idx := range queue {
				if ctx.Err() != nil {
					return
				}
				s.cacheOne(ctx, job, book, idx)
			}
		}()
	}

	for _, idx := range indexes {
		select {
		case queue <- idx:
		case <-ctx.Done():
			// 取消时必须能从这里退出，否则 worker 已返回、生产者永远阻塞。
		}
		if ctx.Err() != nil {
			break
		}
	}
	close(queue)
	wg.Wait()

	if ctx.Err() != nil {
		s.finish(job, dto.CacheStateCanceled, "已取消")
		return
	}
	if _, failed := s.jobCounts(job); failed > 0 {
		s.finish(job, dto.CacheStateDone, fmt.Sprintf("缓存完成，%d 章失败", failed))
		return
	}
	s.finish(job, dto.CacheStateDone, "缓存完成")
}

// jobCounts 在锁内读取任务的完成/失败数。
func (s *CacheService) jobCounts(job *cacheJob) (done, failed int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return job.done, job.failed
}

// cacheOne 抓取并落盘单章。
func (s *CacheService) cacheOne(ctx context.Context, job *cacheJob, book *domain.Book, index int) {
	cctx, cancel := context.WithTimeout(ctx, cacheChapterTimeout)
	defer cancel()

	chapter, err := s.chapters.Get(cctx, book.ID, index)
	if err != nil {
		s.advance(job, "", err)
		return
	}
	content, err := s.content.ChapterFresh(cctx, book.ID, index)
	if err != nil {
		s.advance(job, chapter.Title, err)
		return
	}
	cached, err := s.persist(cctx, book, chapter, content)
	if err != nil {
		s.advance(job, chapter.Title, err)
		return
	}
	if err := s.cache.Put(cctx, cached); err != nil {
		s.advance(job, chapter.Title, err)
		return
	}
	s.advance(job, chapter.Title, nil)
}

// persist 把抓到的内容写成缓存实体：文本入库，图片落盘。
func (s *CacheService) persist(ctx context.Context, book *domain.Book, chapter *domain.BookChapter, content *port.ChapterContent) (*domain.CachedChapter, error) {
	c := &domain.CachedChapter{
		BookID:    book.ID,
		Index:     chapter.Index,
		Title:     firstNonEmpty(content.Title, chapter.Title),
		URL:       chapter.URL,
		CreatedAt: time.Now(),
	}

	if len(content.Images) == 0 {
		c.HTML = content.HTML
		c.Size = int64(len(c.HTML))
		return c, nil
	}

	if s.images == nil {
		return nil, fmt.Errorf("%w: 未配置图片下载器", domain.ErrNotConfigured)
	}

	dir, urlBase := s.chapterDir(book.ID, chapter.Index)
	// 先清空旧目录：重缓存同一章时，上一版多出来的图片不能留下来。
	if err := os.RemoveAll(dir); err != nil {
		return nil, fmt.Errorf("清理旧缓存目录失败: %w", err)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("创建缓存目录失败: %w", err)
	}

	urls := make([]string, 0, len(content.Images))
	var total int64
	for i, src := range content.Images {
		if !isRemoteURL(src) {
			// 本地地址（本地漫画解压产物）原样沿用，不必再复制一份。
			urls = append(urls, src)
			continue
		}
		data, ext, err := s.images.Download(ctx, src, book.Origin)
		if err != nil {
			_ = os.RemoveAll(dir)
			return nil, fmt.Errorf("第 %d 张图片下载失败: %w", i+1, err)
		}
		name := fmt.Sprintf("%03d%s", i+1, ext)
		if err := os.WriteFile(filepath.Join(dir, name), data, 0o644); err != nil {
			_ = os.RemoveAll(dir)
			return nil, fmt.Errorf("写入图片失败: %w", err)
		}
		total += int64(len(data))
		urls = append(urls, urlBase+"/"+name)
	}
	if len(urls) == 0 {
		_ = os.RemoveAll(dir)
		return nil, fmt.Errorf("该章没有可用图片")
	}
	c.Images = urls
	c.Size = total
	return c, nil
}

// advance 记录一章的处理结果并推送进度。
func (s *CacheService) advance(job *cacheJob, title string, err error) {
	s.mu.Lock()
	if err != nil {
		job.failed++
		job.lastErr = fmt.Sprintf("%s：%v", title, err)
	} else {
		job.done++
	}
	if title != "" {
		job.current = title
	}
	payload := dto.CacheProgress{
		State:   dto.CacheStateRunning,
		Total:   job.total,
		Done:    job.done,
		Failed:  job.failed,
		Current: job.current,
		Message: job.lastErr,
	}
	jobID := job.bookID
	bookName := job.bookName
	s.mu.Unlock()

	s.emitID(jobID, bookName, payload)
}

// finish 结束任务。
func (s *CacheService) finish(job *cacheJob, state, msg string) {
	s.mu.Lock()
	job.state = state
	job.finished = time.Now()
	snap := job.snapshot()
	jobID, bookName := job.bookID, job.bookName
	current := job.current
	close(job.doneCh)
	s.mu.Unlock()

	s.emitID(jobID, bookName, dto.CacheProgress{
		State:   state,
		Total:   snap.Total,
		Done:    snap.Done,
		Failed:  snap.Failed,
		Current: current,
		Message: msg,
	})
}

// emit 用任务自身的信息发一条进度事件。
func (s *CacheService) emit(job *cacheJob, p dto.CacheProgress) {
	s.emitID(job.bookID, job.bookName, p)
}

// emitID 推送缓存进度事件；事件总线不可用时静默跳过。
func (s *CacheService) emitID(bookID int64, bookName string, p dto.CacheProgress) {
	if s.events == nil {
		return
	}
	p.BookID = bookID
	p.BookName = bookName
	_ = s.events.Emit(context.Background(), port.EventCacheProgress, p)
}

// Cancel 请求取消某本书的缓存任务；没有运行中的任务时视为成功。
func (s *CacheService) Cancel(bookID int64) error {
	s.mu.Lock()
	job, ok := s.jobs[bookID]
	s.mu.Unlock()
	if !ok || job.state != dto.CacheStateRunning {
		return nil
	}
	job.cancel()
	return nil
}

// Jobs 返回全部任务快照（含已结束的，供界面显示「已完成」）。
func (s *CacheService) Jobs() []dto.CacheJob {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]dto.CacheJob, 0, len(s.jobs))
	for _, job := range s.jobs {
		out = append(out, job.snapshot())
	}
	sort.Slice(out, func(i, j int) bool { return out[i].StartedAt.After(out[j].StartedAt) })
	return out
}

// Stats 返回全局缓存统计。
func (s *CacheService) Stats(ctx context.Context) (dto.CacheStats, error) {
	stats, err := s.cache.BookStats(ctx)
	if err != nil {
		return dto.CacheStats{}, err
	}
	out := dto.CacheStats{Books: len(stats)}
	for _, st := range stats {
		out.Chapters += st.Chapters
		out.Size += st.Size
	}
	s.mu.Lock()
	for _, job := range s.jobs {
		if job.state == dto.CacheStateRunning {
			out.Running++
		}
	}
	s.mu.Unlock()
	return out, nil
}

// Books 返回有缓存的书（按最近缓存时间倒序），用于缓存管理页。
func (s *CacheService) Books(ctx context.Context) ([]dto.CacheBookView, error) {
	stats, err := s.cache.BookStats(ctx)
	if err != nil {
		return nil, err
	}
	books, err := s.books.List(ctx, 0)
	if err != nil {
		return nil, fmt.Errorf("查询书架失败: %w", err)
	}
	byID := make(map[int64]*domain.Book, len(books))
	for _, b := range books {
		byID[b.ID] = b
	}

	out := make([]dto.CacheBookView, 0, len(stats))
	for _, st := range stats {
		book, ok := byID[st.BookID]
		if !ok {
			// 缓存还在但书已被删除（正常情况下级联删除会清掉，这里只做兜底）。
			continue
		}
		view := dto.CacheBookView{
			BookID:         st.BookID,
			Name:           book.Name,
			Author:         book.Author,
			Cover:          book.CoverURL,
			Kind:           string(book.Kind),
			Format:         string(book.Format),
			FormatLabel:    book.Format.String(),
			TotalChapters:  book.TotalChapters,
			CachedChapters: st.Chapters,
			Size:           st.Size,
		}
		if !st.UpdatedAt.IsZero() {
			t := st.UpdatedAt
			view.UpdatedAt = &t
		}
		out = append(out, view)
	}

	// 任务信息在锁内一次性取出，避免逐条加锁。
	s.mu.Lock()
	for i := range out {
		if job, ok := s.jobs[out[i].BookID]; ok {
			snap := job.snapshot()
			out[i].Job = &snap
		}
	}
	s.mu.Unlock()

	sort.Slice(out, func(i, j int) bool {
		li, lj := out[i].UpdatedAt, out[j].UpdatedAt
		if li == nil || lj == nil {
			return li != nil
		}
		return li.After(*lj)
	})
	return out, nil
}

// Chapters 返回某本书已缓存的章节明细。
func (s *CacheService) Chapters(ctx context.Context, bookID int64) ([]dto.CachedChapterView, error) {
	if bookID == 0 {
		return nil, fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	list, err := s.cache.List(ctx, bookID)
	if err != nil {
		return nil, err
	}
	out := make([]dto.CachedChapterView, 0, len(list))
	for _, c := range list {
		out = append(out, dto.CachedChapterView{
			Index:     c.Index,
			Title:     c.Title,
			Size:      c.Size,
			UpdatedAt: c.CreatedAt,
		})
	}
	return out, nil
}

// Status 返回单本书的缓存概况。
func (s *CacheService) Status(ctx context.Context, bookID int64) (dto.CacheBookStatus, error) {
	if bookID == 0 {
		return dto.CacheBookStatus{}, fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	book, err := s.books.Get(ctx, bookID)
	if err != nil {
		return dto.CacheBookStatus{}, err
	}
	list, err := s.cache.List(ctx, bookID)
	if err != nil {
		return dto.CacheBookStatus{}, err
	}
	var size int64
	for _, c := range list {
		size += c.Size
	}
	out := dto.CacheBookStatus{
		BookID:         bookID,
		CachedChapters: len(list),
		TotalChapters:  book.TotalChapters,
		Size:           size,
	}
	s.mu.Lock()
	if job, ok := s.jobs[bookID]; ok {
		snap := job.snapshot()
		out.Job = &snap
	}
	s.mu.Unlock()
	return out, nil
}

// Delete 删除某本书指定章节的缓存（含磁盘上的图片）。
func (s *CacheService) Delete(ctx context.Context, bookID int64, indexes []int) error {
	if bookID == 0 {
		return fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	if len(indexes) == 0 {
		return fmt.Errorf("%w: 未指定要删除的章节", domain.ErrInvalidArgument)
	}
	if s.running(bookID) {
		return fmt.Errorf("%w: 该书正在缓存中，请先取消再删除", domain.ErrInvalidArgument)
	}
	if err := s.cache.Delete(ctx, bookID, indexes); err != nil {
		return err
	}
	for _, idx := range indexes {
		dir, _ := s.chapterDir(bookID, idx)
		_ = os.RemoveAll(dir)
	}
	return nil
}

// PurgeBook 清空某本书的全部缓存（含磁盘图片），并停掉正在跑的任务。
func (s *CacheService) PurgeBook(ctx context.Context, bookID int64) error {
	if bookID == 0 {
		return nil
	}
	s.stopJob(bookID)
	if err := s.cache.DeleteByBook(ctx, bookID); err != nil {
		return err
	}
	dir, _ := s.chapterDir(bookID, 0)
	_ = os.RemoveAll(filepath.Dir(dir)) // <root>/cache/chapter/<bookID>
	return nil
}

// Clear 清空所有缓存与缓存任务。
func (s *CacheService) Clear(ctx context.Context) error {
	s.mu.Lock()
	ids := make([]int64, 0, len(s.jobs))
	for id := range s.jobs {
		ids = append(ids, id)
	}
	s.mu.Unlock()
	for _, id := range ids {
		s.stopJob(id)
	}
	if err := s.cache.DeleteAll(ctx); err != nil {
		return err
	}
	_ = os.RemoveAll(filepath.Join(s.root, "cache", "chapter"))
	return nil
}

// StopAll 停止所有任务，供应用退出时调用。
func (s *CacheService) StopAll() {
	s.mu.Lock()
	s.closed = true
	ids := make([]int64, 0, len(s.jobs))
	for id, job := range s.jobs {
		if job.state == dto.CacheStateRunning {
			ids = append(ids, id)
		}
	}
	s.mu.Unlock()
	for _, id := range ids {
		s.stopJob(id)
	}
}

// stopJob 取消任务并等待它真正退出，避免「删除后又被写回来」。
func (s *CacheService) stopJob(bookID int64) {
	s.mu.Lock()
	job, ok := s.jobs[bookID]
	s.mu.Unlock()
	if !ok {
		return
	}
	if job.state == dto.CacheStateRunning {
		job.cancel()
	}
	select {
	case <-job.doneCh:
	case <-time.After(cacheStopTimeout):
	}
}

// running 报告某本书是否有正在运行的任务。
func (s *CacheService) running(bookID int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	job, ok := s.jobs[bookID]
	return ok && job.state == dto.CacheStateRunning
}

// chapterDir 返回某章图片缓存的磁盘目录与对应的可访问 URL 前缀。
func (s *CacheService) chapterDir(bookID int64, index int) (string, string) {
	rel := path.Join("cache", "chapter", strconv.FormatInt(bookID, 10), strconv.Itoa(index))
	return filepath.Join(s.root, filepath.FromSlash(rel)), "/local/" + rel
}

// isRemoteURL 判断是否为 http(s) 地址。
func isRemoteURL(u string) bool {
	return strings.HasPrefix(u, "http://") || strings.HasPrefix(u, "https://")
}
