package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/legado/desktop/internal/app/dictdata"
	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// 扩展包安装（M4）。
//
// 设计上有三条硬约束，都写在设计方案 §4.2 里：
//
//  1. **不挂在请求 ctx 上**：绑定方法返回后请求 ctx 就被取消，下载会在
//     几秒后被无声掐断。所有后台任务都用 context.WithCancel(Background) 派生。
//  2. **单包互斥**：同一个包不允许并发安装，否则两个 goroutine 争着写同一个
//     `.part`，谁都不会报错，产物却是两段文件的拼接。
//  3. **失败不动旧文件**：下载到 `.part`，转换到 `.db.tmp`，校验通过才 rename。
//     任一环节失败，用户手里还是原来那个能用的词库。

// dictJob 是一次正在进行的安装。
type dictJob struct {
	packID string
	cancel context.CancelFunc
	done   chan struct{}
}

// seq 是进度事件的单调序号。
//
// 事件是异步投递的，迟到很常见；前端按 seq 丢弃过期事件，
// 否则「已完成」会被迟到的一条「下载中」打回去。
func (s *DictService) nextSeq() int64 { return s.seq.Add(1) }

// Install 在后台安装扩展包，立即返回。
//
// sourceID 为空或 auto 时按配置顺序自动换源；否则只试那一个源。
func (s *DictService) Install(ctx context.Context, packID, sourceID, customURL string) error {
	return s.startInstall(ctx, packID, sourceID, customURL, false)
}

// RetryInstall 换源重试，保留 `.part` 已下载的字节。
//
// 之所以单独一个方法而不是让 Install 复用：跨源续传是安全的（各源转发
// 同一份字节），但只有**用户主动换源**时才该保留 `.part`——
// 哈希不符时保留半截文件继续追加，只会把一个坏文件补成另一个坏文件。
func (s *DictService) RetryInstall(ctx context.Context, packID, sourceID, customURL string) error {
	return s.startInstall(ctx, packID, sourceID, customURL, true)
}

func (s *DictService) startInstall(_ context.Context, packID, sourceID, customURL string, keepPart bool) error {
	pack, ok := dictdata.ExtPack(packID)
	if !ok {
		return fmt.Errorf("未知的词库包 %q", packID)
	}
	if s.build == nil {
		return fmt.Errorf("词库转换器未装配")
	}

	s.jobsMu.Lock()
	if _, running := s.jobs[packID]; running {
		s.jobsMu.Unlock()
		return fmt.Errorf("「%s」正在安装中，请先取消", pack.Name)
	}
	if !keepPart {
		// 新装（非续传）一律清掉旧的半截文件：它可能属于另一个版本。
		os.Remove(s.partPath(packID)) //nolint:errcheck
	}
	jobCtx, cancel := context.WithCancel(context.Background())
	job := &dictJob{packID: packID, cancel: cancel, done: make(chan struct{})}
	s.jobs[packID] = job
	s.jobsMu.Unlock()

	go func() {
		defer func() {
			cancel()
			s.jobsMu.Lock()
			delete(s.jobs, packID)
			s.jobsMu.Unlock()
			close(job.done)
		}()
		s.runInstall(jobCtx, pack, sourceID, customURL)
	}()
	return nil
}

// CancelInstall 取消安装并删掉半截文件。
func (s *DictService) CancelInstall(packID string) error {
	s.jobsMu.Lock()
	job, ok := s.jobs[packID]
	s.jobsMu.Unlock()
	if !ok {
		return fmt.Errorf("「%s」没有正在进行的安装", packID)
	}
	job.cancel()
	// 等 goroutine 真正退出：它可能正在写 .part，先删文件会留下已打开的空文件。
	<-job.done
	os.Remove(s.partPath(packID)) //nolint:errcheck
	return nil
}

// WaitInstall 等待某次安装结束（测试与内部串行化用）。
func (s *DictService) WaitInstall(packID string) {
	s.jobsMu.Lock()
	job, ok := s.jobs[packID]
	s.jobsMu.Unlock()
	if ok {
		<-job.done
	}
}

// Remove 删除扩展包；内置核心拒绝删除。
func (s *DictService) Remove(_ context.Context, packID string) error {
	if packID == "en-zh-core" {
		return fmt.Errorf("内置核心词库随应用分发，不能删除")
	}
	pack, ok := dictdata.ExtPack(packID)
	if !ok {
		return fmt.Errorf("未知的词库包 %q", packID)
	}
	if s.isInstalling(packID) {
		return fmt.Errorf("「%s」正在安装中，请先取消", pack.Name)
	}

	dir := filepath.Join(s.root, "dict")
	target := filepath.Join(dir, pack.FileName)

	s.mu.Lock()
	if repo, ok := s.opened[pack.FileName]; ok {
		repo.Close() //nolint:errcheck
		delete(s.opened, pack.FileName)
	}
	s.mu.Unlock()

	if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("删除词库失败: %w", err)
	}
	os.Remove(target + ".tmp")    //nolint:errcheck
	os.Remove(s.partPath(packID)) //nolint:errcheck
	return nil
}

// ImportLocal 用用户自备的上游文件安装扩展包。
//
// 这条路径的意义不是"多一种选择"：它是所有镜像同时挂掉时唯一还能用的
// 扩展方式，也是用户想用更新版本数据时的唯一入口。
func (s *DictService) ImportLocal(_ context.Context, packID, path string) error {
	pack, ok := dictdata.ExtPack(packID)
	if !ok {
		return fmt.Errorf("未知的词库包 %q", packID)
	}
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("打不开导入文件: %w", err)
	}
	if info.IsDir() {
		return fmt.Errorf("导入的是目录，需要选择文件")
	}
	if s.build == nil {
		return fmt.Errorf("词库转换器未装配")
	}

	s.jobsMu.Lock()
	if _, running := s.jobs[packID]; running {
		s.jobsMu.Unlock()
		return fmt.Errorf("「%s」正在安装中，请先取消", pack.Name)
	}
	jobCtx, cancel := context.WithCancel(context.Background())
	job := &dictJob{packID: packID, cancel: cancel, done: make(chan struct{})}
	s.jobs[packID] = job
	s.jobsMu.Unlock()

	go func() {
		defer func() {
			cancel()
			s.jobsMu.Lock()
			delete(s.jobs, packID)
			s.jobsMu.Unlock()
			close(job.done)
		}()
		s.convertAndCommit(jobCtx, pack, path, 0, "", "")
	}()
	return nil
}

// partPath 是下载中的临时文件路径。
//
// 用包 ID 而不是目标文件名：目标文件名带扩展名（.db），
// 让 .part 与 .db 看起来像"同一个文件的两种状态"会在排障时误导人。
func (s *DictService) partPath(packID string) string {
	return filepath.Join(s.root, "dict", packID+".part")
}

func (s *DictService) isInstalling(packID string) bool {
	s.jobsMu.Lock()
	defer s.jobsMu.Unlock()
	_, ok := s.jobs[packID]
	return ok
}

// ── 安装主流程 ─────────────────────────────────────────────────

// runInstall 依次尝试各源下载，成功后转换并落位。
func (s *DictService) runInstall(ctx context.Context, pack dictdata.Pack, sourceID, customURL string) {
	cfg := s.loadSourceSettings(ctx)
	sources := s.installOrder(cfg, pack, sourceID, customURL)
	if len(sources) == 0 {
		s.fail(pack.ID, ctx, "没有可用的下载源：请在设置里换一个源，或直接导入本地文件")
		return
	}

	part := s.partPath(pack.ID)
	switchedFrom := ""
	for i, src := range sources {
		if err := ctx.Err(); err != nil {
			s.emitProgress(ctx, dto.DictInstallProgress{
				PackID: pack.ID, Phase: dto.DictPhaseCanceled, Message: "已取消",
			})
			return
		}
		target, err := assembleURL(src.dictSource, pack.Source, src.customURL)
		if err != nil {
			switchedFrom = src.Name
			continue
		}
		err = s.download(ctx, pack, src, target, part, switchedFrom)
		if err == nil {
			// 下载完成：校验体积与哈希。
			if verr := s.verify(pack, part, ctx, src); verr != nil {
				err = verr
			} else {
				s.convertAndCommit(ctx, pack, part, pack.Source.Size, src.ID, src.Name)
				return
			}
		}
		if errors.Is(err, context.Canceled) {
			s.emitProgress(ctx, dto.DictInstallProgress{
				PackID: pack.ID, Phase: dto.DictPhaseCanceled, Message: "已取消",
			})
			return
		}
		// 失败：手动模式直接停，自动模式换下一个源。
		last := i == len(sources)-1
		if cfg.Mode != "auto" || last {
			s.fail(pack.ID, ctx, err.Error()+"。可以换个源重试，或导入本地文件")
			return
		}
		// 哈希不符时不能续传：半截文件已经是坏的，继续追加只会坏得更彻底。
		if !s.keepPartOn(err) {
			os.Remove(part) //nolint:errcheck
		}
		switchedFrom = src.Name
	}
}

// keepPartOn 判断这次失败后能否保留 .part 继续续传。
//
// 只有"网络层失败"能续传：字节流没走完，前缀仍是好的。
// 校验失败（大小/哈希不对）说明这份字节本身就是错的，必须重下。
func (s *DictService) keepPartOn(err error) bool {
	var ve *verifyError
	return !errors.As(err, &ve)
}

// verifyError 标记「文件内容不对」这一类失败（相对于网络失败）。
type verifyError struct{ msg string }

func (e *verifyError) Error() string { return e.msg }

func verifyErrf(format string, args ...any) error {
	return &verifyError{msg: fmt.Sprintf(format, args...)}
}

// verify 校验下载到的源文件。
//
// 哈希来自**内置清单**而不是网络：如果哈希也从网上下，恶意镜像可以同时
// 替换包和哈希，校验等于没做（设计方案 §4.2.4）。
func (s *DictService) verify(pack dictdata.Pack, part string, ctx context.Context, src resolvedSource) error {
	s.emitProgress(ctx, dto.DictInstallProgress{
		PackID: pack.ID, Phase: dto.DictPhaseVerify,
		Done: 0, Total: 100,
		SourceID: src.ID, SourceName: src.Name,
		Message: "校验文件完整性",
	})

	info, err := os.Stat(part)
	if err != nil {
		return fmt.Errorf("找不到下载的文件: %w", err)
	}
	if pack.Source.Size > 0 && info.Size() != pack.Source.Size {
		return verifyErrf("文件体积不符（得到 %s，应为 %s），源可能返回了错误页",
			formatMB(info.Size()), formatMB(pack.Source.Size))
	}
	if pack.Source.SHA256 != "" {
		sum, err := fileSHA256(part)
		if err != nil {
			return err
		}
		if !strings.EqualFold(sum, pack.Source.SHA256) {
			return verifyErrf("文件校验不通过（sha256 不符），请换一个源重试")
		}
	}
	s.emitProgress(ctx, dto.DictInstallProgress{
		PackID: pack.ID, Phase: dto.DictPhaseVerify,
		Done: 100, Total: 100,
		SourceID: src.ID, SourceName: src.Name,
		Message: "校验通过",
	})
	return nil
}

// download 把源文件下到 part，支持断点续传。
func (s *DictService) download(ctx context.Context, pack dictdata.Pack, src resolvedSource, target, part string, switchedFrom string) error {
	if err := os.MkdirAll(filepath.Dir(part), 0o755); err != nil {
		return fmt.Errorf("创建词典目录: %w", err)
	}
	offset := int64(0)
	if info, err := os.Stat(part); err == nil {
		offset = info.Size()
	}
	// 已下完（上次卡在校验或转换这一步）就不用再请求。
	if pack.Source.Size > 0 && offset == pack.Source.Size {
		return nil
	}
	// 半截文件比目标还大，只能重来。
	if pack.Source.Size > 0 && offset > pack.Source.Size {
		offset = 0
		if err := os.Remove(part); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}

	reqCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, target, nil)
	if err != nil {
		return fmt.Errorf("地址无效: %w", err)
	}
	req.Header.Set("User-Agent", dictUserAgent)
	if offset > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", offset))
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("连接 %s 失败: %w", src.Name, err)
	}
	defer resp.Body.Close() //nolint:errcheck

	// 续传请求被无视（服务器回了 200 整包）时，必须从头写，
	// 否则会在已有前缀后面再拼一整份，产出一个"文件套文件"的怪物。
	if offset > 0 && resp.StatusCode == http.StatusOK {
		offset = 0
	}
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusPartialContent {
		return fmt.Errorf("%s 返回 %d", src.Name, resp.StatusCode)
	}

	flags := os.O_CREATE | os.O_WRONLY
	if offset > 0 {
		flags |= os.O_APPEND
	} else {
		flags |= os.O_TRUNC
	}
	f, err := os.OpenFile(part, flags, 0o644)
	if err != nil {
		return fmt.Errorf("写入临时文件失败: %w", err)
	}
	defer f.Close() //nolint:errcheck

	total := pack.Source.Size
	if total <= 0 {
		total = offset + resp.ContentLength
	}
	written := offset
	lastEmit := time.Now()
	buf := make([]byte, 64*1024)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := f.Write(buf[:n]); werr != nil {
				return fmt.Errorf("写入失败（磁盘可能已满）: %w", werr)
			}
			written += int64(n)
			// 每 150 ms 报一次：太密会把事件通道刷爆，太疏进度条像卡住。
			if time.Since(lastEmit) > 150*time.Millisecond {
				lastEmit = time.Now()
				s.emitProgress(ctx, dto.DictInstallProgress{
					PackID: pack.ID, Phase: dto.DictPhaseDownload,
					Done: written, Total: total, Bytes: written, TotalBytes: total,
					SourceID: src.ID, SourceName: src.Name, SwitchedFrom: switchedFrom,
				})
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return fmt.Errorf("下载中断: %w", readErr)
		}
		if err := ctx.Err(); err != nil {
			return err
		}
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if total > 0 && written != total {
		return fmt.Errorf("下载不完整（%s / %s）", formatMB(written), formatMB(total))
	}
	s.emitProgress(ctx, dto.DictInstallProgress{
		PackID: pack.ID, Phase: dto.DictPhaseDownload,
		Done: written, Total: total, Bytes: written, TotalBytes: total,
		SourceID: src.ID, SourceName: src.Name, SwitchedFrom: switchedFrom,
	})
	return nil
}

// convertAndCommit 把源文件转换成本地词库并原子落位。
//
// downloadedBytes 为 0 表示本地导入（没有下载阶段）。
func (s *DictService) convertAndCommit(ctx context.Context, pack dictdata.Pack, srcPath string, downloadedBytes int64, sourceID, sourceName string) {
	dir := filepath.Join(s.root, "dict")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		s.fail(pack.ID, ctx, err.Error())
		return
	}
	tmp := filepath.Join(dir, pack.FileName+".tmp")

	s.emitProgress(ctx, dto.DictInstallProgress{
		PackID: pack.ID, Phase: dto.DictPhaseConvert,
		SourceID: sourceID, SourceName: sourceName,
		Message: "正在转换词库，这一步不联网",
	})
	entries, err := s.build(ctx, pack.Kind, srcPath, tmp, pack.Tier, func(done, total int64) {
		s.emitProgress(ctx, dto.DictInstallProgress{
			PackID: pack.ID, Phase: dto.DictPhaseConvert,
			Done: done, Total: total,
			SourceID: sourceID, SourceName: sourceName,
		})
	})
	if err != nil {
		os.Remove(tmp) //nolint:errcheck
		if errors.Is(err, context.Canceled) {
			s.emitProgress(ctx, dto.DictInstallProgress{
				PackID: pack.ID, Phase: dto.DictPhaseCanceled, Message: "已取消",
			})
			return
		}
		s.fail(pack.ID, ctx, "转换失败："+err.Error())
		return
	}

	// 转换完还要能打开才算数：schema 对不上时 rename 过去只会让下次查词报错，
	// 而那时用户已经看不到安装过程了，排查成本高得多。
	if err := s.checkDB(tmp, pack.Kind); err != nil {
		os.Remove(tmp) //nolint:errcheck
		s.fail(pack.ID, ctx, "生成的词库不可用："+err.Error())
		return
	}

	final := filepath.Join(dir, pack.FileName)
	s.mu.Lock()
	if repo, ok := s.opened[pack.FileName]; ok {
		repo.Close() //nolint:errcheck
		delete(s.opened, pack.FileName)
	}
	s.mu.Unlock()

	if err := os.Rename(tmp, final); err != nil {
		os.Remove(tmp) //nolint:errcheck
		s.fail(pack.ID, ctx, "落盘失败："+err.Error())
		return
	}
	// 下载的源文件没用了，留着只会白占 60 MB。
	if downloadedBytes > 0 {
		os.Remove(s.partPath(pack.ID)) //nolint:errcheck
	}

	s.emitProgress(ctx, dto.DictInstallProgress{
		PackID: pack.ID, Phase: dto.DictPhaseDone,
		SourceID: sourceID, SourceName: sourceName, Entries: entries,
		Message: fmt.Sprintf("已安装 %s（%d 词条）", pack.Name, entries),
	})
}

// checkDB 打开刚生成的词库并做一次真实查询，确认 schema 可用。
//
// 查询语句必须按包类型选：汉英库只有 zh 表，用英文库的 word 表去探
// 只会得到「no such table: word」——这曾经让汉英包永远装不上，
// 而且失败信息只在界面上闪一下就没了，日志里一句都没有。
func (s *DictService) checkDB(path, kind string) error {
	if s.openRepo == nil {
		return nil
	}
	repo, err := s.openRepo(path)
	if err != nil {
		return err
	}
	defer repo.Close() //nolint:errcheck

	ctx := context.Background()
	if kind == "cedict" {
		if _, err := repo.LookupZh(ctx, "苹果"); err != nil {
			return err
		}
		return nil
	}
	if _, err := repo.PrefixWords(ctx, "a", 1); err != nil {
		return err
	}
	return nil
}

// ── 源顺序 ─────────────────────────────────────────────────────

// resolvedSource 是一个已经确定要用（或尝试）的源。
type resolvedSource struct {
	dictSource
	customURL string
}

// installOrder 决定这次安装依次尝试哪些源。
//
// 跳过「能力不满足」的源而不是让它在 100% 时 403：jsDelivr 对 63 MB 的包
// 一定失败，把它排在前面只是白白浪费用户几分钟。
func (s *DictService) installOrder(cfg dictSourceSettings, pack dictdata.Pack, sourceID, customURL string) []resolvedSource {
	var out []resolvedSource
	add := func(src dictSource, custom string) {
		if src.ID != DictSourceIDCustom && capacityReason(src, pack.Source) != "" {
			return
		}
		out = append(out, resolvedSource{dictSource: src, customURL: custom})
	}

	if sourceID != "" && sourceID != DictSourceIDAuto {
		if sourceID == DictSourceIDCustom {
			add(dictSource{ID: DictSourceIDCustom, Name: "自定义", Kind: "custom"}, customURL)
		} else if src, ok := builtinSource(sourceID); ok {
			add(src, "")
		}
		// 手动模式选中自定义源时不需要回落：用户明确指定了地址。
		return out
	}
	if cfg.Mode != "auto" {
		// manual 且未指定源：用配置里的选中项。
		if cfg.SourceID == DictSourceIDCustom {
			add(dictSource{ID: DictSourceIDCustom, Name: "自定义", Kind: "custom"}, firstNonEmpty(customURL, cfg.CustomURL))
		} else if src, ok := builtinSource(cfg.SourceID); ok {
			add(src, "")
		}
		return out
	}
	for _, id := range cfg.Order {
		if src, ok := builtinSource(id); ok {
			add(src, "")
		}
	}
	// 顺序里没覆盖到的内置源补在最后：老配置缺项时不至于只剩一个源。
	for _, src := range builtinSources() {
		if !containsIDs(cfg.Order, src.ID) {
			add(src, "")
		}
	}
	return out
}

func containsIDs(list []string, id string) bool {
	for _, s := range list {
		if s == id {
			return true
		}
	}
	return false
}

// ── 进度事件 ───────────────────────────────────────────────────

// emitProgress 填充序号后广播。
//
// 一律用 Background：绑定方法返回后请求 ctx 已被取消，
// 用它会连「已完成」这条事件都发不出去。
func (s *DictService) emitProgress(_ context.Context, p dto.DictInstallProgress) {
	if s.events == nil {
		return
	}
	p.Seq = s.nextSeq()
	_ = s.events.Emit(context.Background(), port.EventDictInstallProgress, p)
}

// fail 记录失败事件**并写日志**。
//
// 后台任务的失败只有一条瞬间消失的界面提示，事后无从排查：
// 「汉英包一直装不上」最初就是这样——事件发出去没人看，日志里一句都没有。
func (s *DictService) fail(packID string, ctx context.Context, msg string) {
	slog.Error("词典安装失败", "pack", packID, "err", msg)
	s.emitProgress(ctx, dto.DictInstallProgress{
		PackID: packID, Phase: dto.DictPhaseFailed, Message: msg,
	})
}

// ── 文件工具 ───────────────────────────────────────────────────

// fileSHA256 计算文件摘要。
func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close() //nolint:errcheck
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// 编译期断言：DictService 满足包管理端口（M4 之后不再是空壳）。
var _ port.DictPackageInstaller = (*DictService)(nil)

// ErrDictNoPackage 用于「未装扩展包」这类可自愈状态。
var ErrDictNoPackage = domain.ErrNotConfigured
