package app

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/legado/core/app/dto"
	"github.com/legado/core/domain"
	"github.com/legado/core/port"
)

// audioDownloadJob 是单本书的下载任务，一本书同时只允许一个。
type audioDownloadJob struct {
	cancel context.CancelFunc
	total  int
}

func (s *AudioService) audioDir(bookID int64) string {
	return filepath.Join(s.root, "cache", "audio", strconv.FormatInt(bookID, 10))
}

// cachedPath 找一章已完整落盘的音频；.part 是未完成的临时文件，不算缓存。
func (s *AudioService) cachedPath(bookID int64, index int) string {
	dir := s.audioDir(bookID)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	prefix := strconv.Itoa(index) + "."
	for _, e := range entries {
		name := e.Name()
		if !e.IsDir() && strings.HasPrefix(name, prefix) &&
			!strings.HasSuffix(name, ".part") {
			return filepath.Join(dir, name)
		}
	}
	return ""
}

// CachedAudio 列出某本书已下载的章节，供播放页显示「已缓存」。
func (s *AudioService) CachedAudio(_ context.Context, bookID int64) ([]dto.AudioCacheView, error) {
	entries, err := os.ReadDir(s.audioDir(bookID))
	if err != nil {
		if os.IsNotExist(err) {
			return []dto.AudioCacheView{}, nil
		}
		return nil, fmt.Errorf("读取音频缓存失败: %w", err)
	}
	out := make([]dto.AudioCacheView, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || strings.HasSuffix(e.Name(), ".part") {
			continue
		}
		dot := strings.IndexByte(e.Name(), '.')
		if dot <= 0 {
			continue
		}
		index, err := strconv.Atoi(e.Name()[:dot])
		if err != nil {
			continue
		}
		info, err := e.Info()
		if err != nil || info.Size() == 0 {
			continue
		}
		out = append(out, dto.AudioCacheView{
			Index: index,
			Size:  info.Size(),
			Path:  filepath.Join(s.audioDir(bookID), e.Name()),
		})
	}
	return out, nil
}

// DeleteAudioCache 删除指定章节的离线音频。
func (s *AudioService) DeleteAudioCache(_ context.Context, bookID int64, indexes []int) error {
	dir := s.audioDir(bookID)
	want := make(map[int]bool, len(indexes))
	for _, i := range indexes {
		want[i] = true
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("读取音频缓存失败: %w", err)
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		dot := strings.IndexByte(e.Name(), '.')
		if dot <= 0 {
			continue
		}
		i, err := strconv.Atoi(e.Name()[:dot])
		if err != nil || !want[i] {
			continue
		}
		if err := os.Remove(filepath.Join(dir, e.Name())); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("删除第 %d 章音频缓存失败: %w", i, err)
		}
	}
	return nil
}

// DownloadAudio 后台下载 [fromIndex, toIndex] 的音频，立即返回任务回执。
//
// 原版 CacheActivity 明确排除音频书（`!it.isAudio()`），只在播放器里做
// ExoPlayer 的流式 LRU 缓存；桌面端改为「显式下载整章」的离线能力，
// 命中缓存的章节由 /stream/ 从本地文件提供，断网也能听。
func (s *AudioService) DownloadAudio(ctx context.Context, bookID int64, fromIndex, toIndex int) (*dto.AudioDownloadView, error) {
	book, _, err := s.chapterFor(ctx, bookID, fromIndex)
	if err != nil {
		return nil, err
	}
	chapters, err := s.chapters.List(ctx, bookID)
	if err != nil {
		return nil, fmt.Errorf("读取目录失败: %w", err)
	}
	if fromIndex < 0 || toIndex < fromIndex || toIndex >= len(chapters) {
		return nil, fmt.Errorf("%w: 下载章节范围不合法", domain.ErrInvalidArgument)
	}
	batch := append([]*domain.BookChapter(nil), chapters[fromIndex:toIndex+1]...)

	s.mu.Lock()
	if old := s.jobs[bookID]; old != nil {
		old.cancel()
	}
	jobCtx, cancel := context.WithCancel(context.Background())
	s.jobs[bookID] = &audioDownloadJob{cancel: cancel, total: len(batch)}
	s.mu.Unlock()

	go s.runDownload(jobCtx, bookID, book, batch)
	return &dto.AudioDownloadView{BookID: bookID, Total: len(batch)}, nil
}

// CancelDownload 取消某本书正在进行的下载。
func (s *AudioService) CancelDownload(_ context.Context, bookID int64) error {
	s.mu.Lock()
	job := s.jobs[bookID]
	s.mu.Unlock()
	if job == nil {
		return nil
	}
	job.cancel()
	return nil
}

// StopAll 由组合根在退出时调用，避免后台下载挂住进程。
func (s *AudioService) StopAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, job := range s.jobs {
		job.cancel()
	}
}

func (s *AudioService) runDownload(ctx context.Context, bookID int64, book *domain.Book, batch []*domain.BookChapter) {
	defer func() {
		s.mu.Lock()
		delete(s.jobs, bookID)
		s.mu.Unlock()
	}()
	total := len(batch)
	done := 0
	for _, ch := range batch {
		select {
		case <-ctx.Done():
			s.emitAudio(bookID, done, total, ch.Index, "canceled", "")
			return
		default:
		}
		if p := s.cachedPath(bookID, ch.Index); p != "" {
			done++
			s.emitAudio(bookID, done, total, ch.Index, "running", "")
			continue
		}
		res, err := s.resolveResource(ctx, book, ch)
		if err != nil {
			s.emitAudio(bookID, done, total, ch.Index, "error", err.Error())
			return
		}
		if err := s.downloadOne(ctx, bookID, ch.Index, res); err != nil {
			if ctx.Err() != nil {
				s.emitAudio(bookID, done, total, ch.Index, "canceled", "")
			} else {
				s.emitAudio(bookID, done, total, ch.Index, "error", err.Error())
			}
			return
		}
		done++
		s.emitAudio(bookID, done, total, ch.Index, "running", "")
	}
	s.emitAudio(bookID, done, total, -1, "done", "")
}

// downloadOne 全量拉取一章音频并原子落盘：先写 .part，成功才改名，
// 中途失败/取消不会留下会被误当成缓存的半截文件。
func (s *AudioService) downloadOne(ctx context.Context, bookID int64, index int, res *port.AudioResource) error {
	dir := s.audioDir(bookID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("创建音频缓存目录失败: %w", err)
	}
	tmp := filepath.Join(dir, fmt.Sprintf("%d.part", index))
	defer os.Remove(tmp) //nolint:errcheck

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, res.URL, nil)
	if err != nil {
		return err
	}
	for k, v := range res.Headers {
		if strings.EqualFold(k, "Host") || strings.EqualFold(k, "Content-Length") {
			continue
		}
		req.Header.Set(k, v)
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("连接音频源失败: %w", err)
	}
	defer resp.Body.Close() //nolint:errcheck
	if resp.StatusCode >= 400 {
		return fmt.Errorf("音频源返回 %s", resp.Status)
	}

	f, err := os.Create(tmp)
	if err != nil {
		return fmt.Errorf("创建缓存文件失败: %w", err)
	}
	n, copyErr := io.Copy(f, resp.Body)
	closeErr := f.Close()
	if copyErr != nil {
		return fmt.Errorf("下载音频中断: %w", copyErr)
	}
	if closeErr != nil {
		return closeErr
	}
	if n == 0 {
		return fmt.Errorf("音频源返回了空内容")
	}
	// 换源/换规则后同一章可能残留旧扩展名，先清掉再落新文件。
	for _, old := range s.filesForIndex(bookID, index) {
		_ = os.Remove(old)
	}
	final := filepath.Join(dir, strconv.Itoa(index)+audioExt(res.URL))
	if err := os.Rename(tmp, final); err != nil {
		return fmt.Errorf("保存音频缓存失败: %w", err)
	}
	return nil
}

func (s *AudioService) filesForIndex(bookID int64, index int) []string {
	dir := s.audioDir(bookID)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	prefix := strconv.Itoa(index) + "."
	var out []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasPrefix(e.Name(), prefix) {
			out = append(out, filepath.Join(dir, e.Name()))
		}
	}
	return out
}

func (s *AudioService) emitAudio(bookID int64, done, total, index int, state, errMsg string) {
	if s.events == nil {
		return
	}
	_ = s.events.Emit(context.Background(), port.EventAudioCacheProgress, dto.AudioCacheProgress{
		BookID: bookID,
		Done:   done,
		Total:  total,
		Index:  index,
		State:  state,
		Error:  errMsg,
	})
}
