package app

// 本文件实现「从 WebDAV 选择书籍 → 下载到本地 → 解析入架」。
//
// 与备份下载（webdav.go 的 DownloadBackup）刻意分开：备份是「存一份」，
// 导入是「成为书架上一本书」。两者的目标目录、进度语义、失败处理都不同，
// 混在一个方法里会让两边的偶发失败互相牵连。

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// bookImporter 是导入能力的契约，由 LibraryService 实现。
type bookImporter interface {
	ImportLocalFiles(ctx context.Context, paths []string, groupID int64) (*dto.ImportResult, error)
}

const (
	// webdavScanMaxDepth 限制递归深度，避免误选服务器根目录时把整棵盘扫一遍。
	webdavScanMaxDepth = 8
	// webdavScanMaxFiles 是单次扫描的文件数上限。
	webdavScanMaxFiles = 2000
	// webdavDownloadTimeout 是单个文件的下载超时。大 EPUB / 漫画包在慢速网络上
	// 可能要好几分钟，比备份的 30s 宽松得多。
	webdavDownloadTimeout = 30 * time.Minute
	// webdavProgressInterval 是字节进度的推送间隔：每 400ms 一条，
	// 既能显示"在动"，又不会把事件通道刷满。
	webdavProgressInterval = 400 * time.Millisecond
)

// webdavImportJob 是一次导入任务的运行时状态。
type webdavImportJob struct {
	mu     sync.Mutex
	view   dto.WebDAVImportJob
	cancel context.CancelFunc
	done   chan struct{}
}

func newWebdavImportJob(cancel context.CancelFunc) *webdavImportJob {
	return &webdavImportJob{
		view: dto.WebDAVImportJob{
			State:    dto.WebDAVImportRunning,
			Phase:    "scan",
			Message:  "正在统计文件…",
			Imported: make([]dto.BookBrief, 0, 8),
			Failures: make([]dto.ImportFailure, 0),
		},
		cancel: cancel,
		done:   make(chan struct{}),
	}
}

// update 在写锁内修改状态。回调内不要做 IO。
func (j *webdavImportJob) update(fn func(*dto.WebDAVImportJob)) {
	j.mu.Lock()
	defer j.mu.Unlock()
	fn(&j.view)
}

// snapshot 返回深拷贝，避免调用方与后台协程共享切片底层数组。
func (j *webdavImportJob) snapshot() dto.WebDAVImportJob {
	j.mu.Lock()
	defer j.mu.Unlock()
	v := j.view
	v.Imported = append(make([]dto.BookBrief, 0, len(j.view.Imported)), j.view.Imported...)
	v.Failures = append(make([]dto.ImportFailure, 0, len(j.view.Failures)), j.view.Failures...)
	return v
}

func (j *webdavImportJob) running() bool {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.view.State == dto.WebDAVImportRunning
}

// ── 对外能力 ────────────────────────────────────────────────────────────

// ScanBooks 递归列出远端路径下所有可导入的书籍文件。
//
// relPath 为空表示 WebDAV 工作根目录。返回的 Path 是**相对工作根目录**的路径，
// 前端原样回传给 StartBookImport 即可。
func (s *WebDAVService) ScanBooks(ctx context.Context, relPath string) ([]dto.RemoteBookView, error) {
	cfg, err := s.load(ctx)
	if err != nil {
		return nil, err
	}
	client, err := s.factory.New(*cfg)
	if err != nil {
		return nil, err
	}
	books, err := s.walkBooks(ctx, client, s.remoteRoot(cfg), relPath)
	if err != nil {
		return nil, err
	}
	// 递归是「目录优先」的顺序，对外统一按路径排序，前端展示与批量返回才稳定。
	sort.Slice(books, func(i, j int) bool { return books[i].Path < books[j].Path })
	return books, nil
}

// StartBookImport 启动后台导入任务。
//
// relPaths 可以是文件也可以是目录（目录会被递归展开）。方法立即返回任务快照，
// 真正的扫描与传输在后台进行，进度经 EventWebDAVImportProgress 推送。
func (s *WebDAVService) StartBookImport(ctx context.Context, relPaths []string, groupID int64) (dto.WebDAVImportJob, error) {
	if s.importer == nil || s.importRoot == "" {
		return dto.WebDAVImportJob{}, fmt.Errorf("%w: 当前构建未启用 WebDAV 导入", domain.ErrNotConfigured)
	}
	targets, err := normalizeRelPaths(relPaths)
	if err != nil {
		return dto.WebDAVImportJob{}, err
	}

	cfg, err := s.load(ctx)
	if err != nil {
		return dto.WebDAVImportJob{}, err
	}

	s.jobMu.Lock()
	if s.job != nil && s.job.running() {
		snapshot := s.job.snapshot()
		s.jobMu.Unlock()
		return snapshot, fmt.Errorf("%w: 已有一个导入任务在进行，请先等它结束或取消", domain.ErrInvalidArgument)
	}
	// 绑定方法返回后请求 ctx 会被取消，后台任务必须用独立的 ctx。
	jobCtx, cancel := context.WithCancel(context.Background())
	job := newWebdavImportJob(cancel)
	s.job = job
	s.jobMu.Unlock()

	go s.runImport(jobCtx, job, *cfg, targets, groupID)
	return job.snapshot(), nil
}

// ImportStatus 返回当前（或最近一次）导入任务的状态。从未导入过时返回 idle。
func (s *WebDAVService) ImportStatus() dto.WebDAVImportJob {
	s.jobMu.Lock()
	job := s.job
	s.jobMu.Unlock()
	if job == nil {
		return dto.WebDAVImportJob{
			State:    dto.WebDAVImportIdle,
			Imported: make([]dto.BookBrief, 0),
			Failures: make([]dto.ImportFailure, 0),
		}
	}
	return job.snapshot()
}

// CancelBookImport 取消正在进行的导入任务。
//
// 半成品文件以 .part 后缀存在并在取消时删除，已下载完成的书会保留
// （它们已经入库，删掉反而让书架出现坏记录）。
func (s *WebDAVService) CancelBookImport() error {
	s.jobMu.Lock()
	job := s.job
	s.jobMu.Unlock()
	if job == nil || !job.running() {
		return nil
	}
	job.cancel()
	// 等一下让状态落到 canceled，前端点完取消就能看到结果。
	select {
	case <-job.done:
	case <-time.After(5 * time.Second):
	}
	return nil
}

// StopImport 在应用退出时被调用，确保后台下载不拖住进程。
func (s *WebDAVService) StopImport() {
	_ = s.CancelBookImport()
}

// ── 后台任务 ────────────────────────────────────────────────────────────

func (s *WebDAVService) runImport(ctx context.Context, job *webdavImportJob, cfg domain.WebDAVConfig, rels []string, groupID int64) {
	defer close(job.done)

	client, err := s.factory.New(cfg)
	if err != nil {
		s.finishFailed(job, err)
		return
	}

	books, err := s.collectBooks(ctx, client, s.remoteRoot(&cfg), rels)
	if err != nil {
		if ctx.Err() != nil {
			s.finishCanceled(job)
			return
		}
		s.finishFailed(job, err)
		return
	}
	if len(books) == 0 {
		s.finishFailed(job, fmt.Errorf("所选位置里没有可导入的书籍文件（支持 txt / epub / pdf / zip / cbz）"))
		return
	}

	var totalBytes int64
	for _, b := range books {
		totalBytes += b.Size
	}
	job.update(func(v *dto.WebDAVImportJob) {
		v.Total = len(books)
		v.TotalBytes = totalBytes
		v.Phase = "download"
		v.Message = fmt.Sprintf("共 %d 个文件，开始下载", len(books))
	})
	s.publish(job)

	var lastEmit time.Time
	for _, b := range books {
		if ctx.Err() != nil {
			s.finishCanceled(job)
			return
		}
		job.update(func(v *dto.WebDAVImportJob) {
			v.Current = b.Name
			v.Phase = "download"
			v.Message = "下载 " + b.Name
		})
		s.publish(job)

		local, err := s.fetchBook(ctx, client, s.remoteRoot(&cfg), b, func(n int64) {
			// 字节进度节流：大文件每读 256KB 回调一次，直接推送会打爆事件通道。
			if time.Since(lastEmit) < webdavProgressInterval {
				return
			}
			lastEmit = time.Now()
			job.update(func(v *dto.WebDAVImportJob) {
				v.Bytes += n
				v.Phase = "download"
			})
			s.publish(job)
		})
		if err != nil {
			if ctx.Err() != nil {
				s.finishCanceled(job)
				return
			}
			s.recordFailure(job, b, err)
			continue
		}

		job.update(func(v *dto.WebDAVImportJob) {
			v.Phase = "import"
			v.Message = "解析 " + b.Name
		})
		s.publish(job)

		res, err := s.importer.ImportLocalFiles(ctx, []string{local}, groupID)
		switch {
		case err != nil:
			s.recordFailure(job, b, err)
		case res != nil && len(res.Failed) > 0:
			s.recordFailure(job, b, errors.New(res.Failed[0].Reason))
		default:
			job.update(func(v *dto.WebDAVImportJob) {
				v.Done++
				if res != nil && len(res.Imported) > 0 {
					v.Imported = append(v.Imported, res.Imported...)
				}
			})
		}
		s.publish(job)
	}

	s.finishSucceeded(job)
}

// collectBooks 展开多个远端路径（文件或目录）为去重后的书籍列表。
func (s *WebDAVService) collectBooks(ctx context.Context, client port.WebDAVClient, root string, rels []string) ([]dto.RemoteBookView, error) {
	seen := make(map[string]struct{}, len(rels))
	out := make([]dto.RemoteBookView, 0, len(rels))

	for _, rel := range rels {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		// 先判断是目录还是文件：目录走递归展开，文件直接判定扩展名。
		entry, err := client.Stat(ctx, joinRemote(root, rel))
		if err != nil {
			return nil, err
		}
		if entry.IsDir {
			books, err := s.walkBooks(ctx, client, root, rel)
			if err != nil {
				return nil, err
			}
			for _, b := range books {
				if _, ok := seen[b.Path]; ok {
					continue
				}
				seen[b.Path] = struct{}{}
				out = append(out, b)
			}
			continue
		}
		b, ok := remoteBookOf(root, *entry)
		if !ok {
			continue
		}
		if _, dup := seen[b.Path]; dup {
			continue
		}
		seen[b.Path] = struct{}{}
		out = append(out, b)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out, nil
}

// walkBooks 递归扫描目录下的书籍文件。
func (s *WebDAVService) walkBooks(ctx context.Context, client port.WebDAVClient, root, rel string) ([]dto.RemoteBookView, error) {
	out := make([]dto.RemoteBookView, 0, 16)
	var walk func(rel string, depth int) error

	walk = func(rel string, depth int) error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if depth > webdavScanMaxDepth {
			return nil
		}
		entries, err := client.List(ctx, joinRemote(root, rel))
		if err != nil {
			return err
		}
		sort.Slice(entries, func(i, j int) bool {
			if entries[i].IsDir != entries[j].IsDir {
				return entries[i].IsDir
			}
			return entries[i].Name < entries[j].Name
		})
		for _, e := range entries {
			// 跳过隐藏项：.DS_Store、@eaDir 之类既不是书也没必要递归。
			if strings.HasPrefix(e.Name, ".") {
				continue
			}
			if e.IsDir {
				if err := walk(path.Join(rel, e.Name), depth+1); err != nil {
					return err
				}
				continue
			}
			if b, ok := remoteBookOf(root, e); ok {
				out = append(out, b)
				if len(out) >= webdavScanMaxFiles {
					return nil
				}
			}
		}
		return nil
	}

	if err := walk(rel, 0); err != nil {
		return nil, err
	}
	return out, nil
}

// fetchBook 把一本远端书下载到本地，返回本地绝对路径。
//
// 已存在且不比远端旧的副本直接复用：书没变就不用再传一遍，
// 重复导入同一目录时才不会每次都重下几百兆。
func (s *WebDAVService) fetchBook(ctx context.Context, client port.WebDAVClient, root string, b dto.RemoteBookView, onBytes func(int64)) (string, error) {
	local, err := s.localPathOf(b.Path)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		return "", fmt.Errorf("创建本地目录失败: %w", err)
	}

	if info, err := os.Stat(local); err == nil && info.Size() == b.Size && b.Size > 0 {
		upToDate := true
		if b.ModTime != nil {
			upToDate = !b.ModTime.After(info.ModTime())
		}
		if upToDate {
			// 没有真正传输，但进度条的总字节要算上，否则百分比会越走越偏。
			if onBytes != nil && b.Size > 0 {
				onBytes(b.Size)
			}
			return local, nil
		}
	}

	cctx, cancel := context.WithTimeout(ctx, webdavDownloadTimeout)
	defer cancel()

	rc, err := client.Download(cctx, joinRemote(root, b.Path))
	if err != nil {
		return "", err
	}
	defer rc.Close() //nolint:errcheck

	// 先写 .part 再改名：中途失败或取消不会留下一个「看起来完整」的半截书。
	tmp := local + ".part"
	f, err := os.Create(tmp)
	if err != nil {
		return "", fmt.Errorf("创建本地文件失败: %w", err)
	}
	_, cerr := copyWithProgress(cctx, f, rc, onBytes)
	closeErr := f.Close()
	if cerr != nil {
		os.Remove(tmp) //nolint:errcheck
		return "", fmt.Errorf("下载中断: %w", cerr)
	}
	if closeErr != nil {
		os.Remove(tmp) //nolint:errcheck
		return "", fmt.Errorf("写入本地文件失败: %w", closeErr)
	}
	if err := os.Rename(tmp, local); err != nil {
		os.Remove(tmp) //nolint:errcheck
		return "", fmt.Errorf("保存文件失败: %w", err)
	}
	return local, nil
}

// localPathOf 把远端相对路径映射到本地落点。
//
// 逐段 sanitize 并拒绝 .. ，防止远端构造出 ./../../ 之类的路径写到数据目录之外。
func (s *WebDAVService) localPathOf(rel string) (string, error) {
	clean, err := safeRelPath(rel)
	if err != nil {
		return "", err
	}
	return filepath.Join(s.importRoot, filepath.FromSlash(clean)), nil
}

// ── 状态收尾 ────────────────────────────────────────────────────────────

func (s *WebDAVService) recordFailure(job *webdavImportJob, b dto.RemoteBookView, err error) {
	job.update(func(v *dto.WebDAVImportJob) {
		v.Failed++
		v.Failures = append(v.Failures, dto.ImportFailure{Path: b.Path, Reason: err.Error()})
	})
	s.publish(job)
}

func (s *WebDAVService) finishSucceeded(job *webdavImportJob) {
	job.update(func(v *dto.WebDAVImportJob) {
		v.State = dto.WebDAVImportDone
		v.Phase = "done"
		v.Current = ""
		v.Message = fmt.Sprintf("导入完成：成功 %d，失败 %d", v.Done, v.Failed)
	})
	s.publish(job)
}

func (s *WebDAVService) finishCanceled(job *webdavImportJob) {
	job.update(func(v *dto.WebDAVImportJob) {
		v.State = dto.WebDAVImportCanceled
		v.Phase = "done"
		v.Current = ""
		v.Message = fmt.Sprintf("已取消：成功 %d，失败 %d", v.Done, v.Failed)
	})
	s.publish(job)
}

func (s *WebDAVService) finishFailed(job *webdavImportJob, err error) {
	job.update(func(v *dto.WebDAVImportJob) {
		v.State = dto.WebDAVImportFailed
		v.Phase = "error"
		v.Current = ""
		v.Message = err.Error()
	})
	s.publish(job)
}

// publish 把任务快照转成进度事件推给前端。
func (s *WebDAVService) publish(job *webdavImportJob) {
	if s.events == nil {
		return
	}
	v := job.snapshot()
	_ = s.events.Emit(context.Background(), port.EventWebDAVImportProgress, dto.WebDAVImportProgress{
		State:      v.State,
		Phase:      v.Phase,
		Total:      v.Total,
		Done:       v.Done,
		Failed:     v.Failed,
		Current:    v.Current,
		Bytes:      v.Bytes,
		TotalBytes: v.TotalBytes,
		Message:    v.Message,
	})
}

// ── 纯函数 ──────────────────────────────────────────────────────────────

// remoteBookOf 判断条目是否为可导入的书籍并转成视图。
func remoteBookOf(root string, e port.WebDAVEntry) (dto.RemoteBookView, bool) {
	if e.IsDir {
		return dto.RemoteBookView{}, false
	}
	format := domain.ParseBookFormat(strings.ToLower(path.Ext(e.Name)))
	if format == domain.BookFormatUnknown {
		return dto.RemoteBookView{}, false
	}
	var mod *time.Time
	if !e.ModTime.IsZero() {
		t := e.ModTime
		mod = &t
	}
	return dto.RemoteBookView{
		Path:    relOf(root, e.Path),
		Name:    e.Name,
		Size:    e.Size,
		Format:  format.String(),
		ModTime: mod,
	}, true
}

// relOf 去掉工作根目录前缀，得到相对路径。
func relOf(root, full string) string {
	root = strings.TrimSuffix(root, "/")
	rel := strings.TrimPrefix(full, root)
	return strings.TrimPrefix(rel, "/")
}

// normalizeRelPaths 清洗并去重前端传来的路径。
func normalizeRelPaths(in []string) ([]string, error) {
	out := make([]string, 0, len(in))
	seen := make(map[string]struct{}, len(in))
	for _, p := range in {
		clean, err := safeRelPath(p)
		if err != nil {
			return nil, err
		}
		if _, ok := seen[clean]; ok {
			continue
		}
		seen[clean] = struct{}{}
		out = append(out, clean)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%w: 请先选择要导入的文件或目录", domain.ErrInvalidArgument)
	}
	return out, nil
}

// safeRelPath 把远端路径规整成可安全拼接的相对路径。
func safeRelPath(rel string) (string, error) {
	rel = strings.TrimSpace(strings.ReplaceAll(rel, "\\", "/"))
	rel = strings.Trim(rel, "/")
	if rel == "" {
		return "", fmt.Errorf("%w: 远端路径为空", domain.ErrInvalidArgument)
	}
	parts := make([]string, 0, 4)
	for _, seg := range strings.Split(rel, "/") {
		switch seg {
		case "", ".":
			continue
		case "..":
			return "", fmt.Errorf("%w: 远端路径不合法", domain.ErrInvalidArgument)
		}
		parts = append(parts, sanitizeFileName(seg))
	}
	if len(parts) == 0 {
		return "", fmt.Errorf("%w: 远端路径不合法", domain.ErrInvalidArgument)
	}
	return strings.Join(parts, "/"), nil
}

// copyWithProgress 边复制边汇报字节数，并在每次循环检查取消。
func copyWithProgress(ctx context.Context, dst io.Writer, src io.Reader, onBytes func(int64)) (int64, error) {
	buf := make([]byte, 256*1024)
	var total int64
	for {
		if err := ctx.Err(); err != nil {
			return total, err
		}
		n, err := src.Read(buf)
		if n > 0 {
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return total, werr
			}
			total += int64(n)
			if onBytes != nil {
				onBytes(int64(n))
			}
		}
		if errors.Is(err, io.EOF) {
			return total, nil
		}
		if err != nil {
			return total, err
		}
	}
}
