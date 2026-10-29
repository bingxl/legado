package app

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// LibraryService 负责本地书籍的导入与导出。
//
// 导入采用「部分成功」语义：批量导入时个别文件失败不中断整体流程，
// 失败原因收集在 ImportResult.Failed 中，由前端一次性呈现。
type LibraryService struct {
	books     port.BookRepository
	chapters  port.ChapterRepository
	parsers   port.LocalBookParserRegistry
	exporters map[domain.BookFormat]port.BookExporter
	blobs     port.BlobStore
	events    port.EventBus
	settings  port.SettingsStore
	content   *ContentProvider
	uow       port.UnitOfWork
}

// LibraryDeps 聚合 LibraryService 的全部依赖，避免构造函数参数过长。
type LibraryDeps struct {
	Books     port.BookRepository
	Chapters  port.ChapterRepository
	Parsers   port.LocalBookParserRegistry
	Exporters map[domain.BookFormat]port.BookExporter
	Blobs     port.BlobStore
	Events    port.EventBus
	Settings  port.SettingsStore
	Content   *ContentProvider
	UoW       port.UnitOfWork
}

// NewLibraryService 构造导入导出服务。
func NewLibraryService(d LibraryDeps) *LibraryService {
	if d.Exporters == nil {
		d.Exporters = map[domain.BookFormat]port.BookExporter{}
	}
	return &LibraryService{
		books:     d.Books,
		chapters:  d.Chapters,
		parsers:   d.Parsers,
		exporters: d.Exporters,
		blobs:     d.Blobs,
		events:    d.Events,
		settings:  d.Settings,
		content:   d.Content,
		uow:       d.UoW,
	}
}

// ImportLocalFiles 导入一批本地书籍文件到指定分组。
//
// 已导入过的同一路径会执行更新（刷新元数据与目录），而非产生重复条目。
func (s *LibraryService) ImportLocalFiles(ctx context.Context, paths []string, groupID int64) (*dto.ImportResult, error) {
	if len(paths) == 0 {
		return &dto.ImportResult{}, fmt.Errorf("%w: 未选择任何文件", domain.ErrInvalidArgument)
	}

	result := &dto.ImportResult{
		Imported: make([]dto.BookBrief, 0, len(paths)),
		Failed:   make([]dto.ImportFailure, 0),
	}

	for i, p := range paths {
		s.emitProgress(ctx, len(paths), i+1, filepath.Base(p))

		book, err := s.importOne(ctx, p, groupID)
		if err != nil {
			result.Failed = append(result.Failed, dto.ImportFailure{Path: p, Reason: err.Error()})
			continue
		}
		result.Imported = append(result.Imported, dto.NewBookBrief(book))
	}

	return result, nil
}

// importOne 导入单个文件，返回已入库的书籍。
func (s *LibraryService) importOne(ctx context.Context, path string, groupID int64) (*domain.Book, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("解析路径失败: %w", err)
	}
	if _, err := os.Stat(abs); err != nil {
		return nil, fmt.Errorf("%w: 文件不可访问", domain.ErrInvalidArgument)
	}

	format := domain.ParseBookFormat(strings.ToLower(filepath.Ext(abs)))
	if format == domain.BookFormatUnknown {
		return nil, fmt.Errorf("%w: 不支持的文件类型", domain.ErrUnsupportedFormat)
	}
	if s.parsers == nil {
		return nil, fmt.Errorf("%w: 未配置本地书解析器", domain.ErrNotConfigured)
	}
	parser, err := s.parsers.Resolve(format)
	if err != nil {
		return nil, err
	}

	parsed, err := parser.Parse(ctx, abs)
	if err != nil {
		return nil, fmt.Errorf("%w: %s", domain.ErrParseFailed, err.Error())
	}

	book := &domain.Book{
		Name:          firstNonEmpty(parsed.Meta.Title, strings.TrimSuffix(filepath.Base(abs), filepath.Ext(abs))),
		Author:        parsed.Meta.Author,
		Intro:         parsed.Meta.Intro,
		Kind:          domain.BookKindLocal,
		Format:        format,
		Origin:        "local",
		BookURL:       abs,
		GroupID:       groupID,
		TotalChapters: len(parsed.Chapters),
	}

	// 保存封面（若有）；失败仅忽略，不阻断导入主流程。
	if parsed.Cover != nil {
		s.saveCover(ctx, book, parsed.Cover, parsed.CoverExt)
	}

	// 同一路径重复导入时执行更新，保持幂等。
	existing, err := s.books.FindByURL(ctx, "local", abs)
	if err == nil {
		book.ID = existing.ID
		book.GroupID = existing.GroupID
		book.DurChapterIndex = existing.DurChapterIndex
		book.DurChapterTitle = existing.DurChapterTitle
		book.DurChapterPos = existing.DurChapterPos
		book.CreatedAt = existing.CreatedAt
		if err := s.books.Update(ctx, book); err != nil {
			return nil, err
		}
	} else {
		if err := s.books.Create(ctx, book); err != nil {
			return nil, err
		}
	}

	if err := s.uow.Do(ctx, func(ctx context.Context) error {
		return s.chapters.ReplaceAll(ctx, book.ID, parsed.Chapters)
	}); err != nil {
		return nil, err
	}
	return book, nil
}

// saveCover 保存封面资源并回填地址。
//
// 封面属于锦上添花的信息：保存失败不应阻断导入，因此这里只丢弃错误。
func (s *LibraryService) saveCover(ctx context.Context, book *domain.Book, cover io.ReadCloser, ext string) {
	defer cover.Close() //nolint:errcheck
	if s.blobs == nil {
		return
	}
	if ext == "" {
		ext = ".jpg"
	}
	path, err := s.blobs.Save(ctx, port.BlobCategoryCover, coverName(book, ext), cover)
	if err == nil {
		book.CoverURL = path
	}
}

// coverName 生成封面文件名。书籍尚未入库（ID 为 0）时用文件名兜底。
func coverName(b *domain.Book, ext string) string {
	base := fmt.Sprintf("%d", b.ID)
	if b.ID == 0 {
		base = strings.TrimSuffix(filepath.Base(b.BookURL), filepath.Ext(b.BookURL))
	}
	return base + ext
}

// ExportBook 将书籍导出为指定格式的文件。
//
// destPath 为空时导出到「上次导出目录/书名.扩展名」。
func (s *LibraryService) ExportBook(ctx context.Context, bookID int64, format domain.BookFormat, destPath string) (*dto.ExportResult, error) {
	exporter, ok := s.exporters[format]
	if !ok {
		return nil, fmt.Errorf("%w: 暂不支持导出 %s 格式", domain.ErrUnsupportedFormat, format.String())
	}
	book, chapters, err := s.content.BookAndChapters(ctx, bookID)
	if err != nil {
		return nil, err
	}
	if len(chapters) == 0 {
		return nil, fmt.Errorf("%w: 该书没有可导出的章节", domain.ErrInvalidArgument)
	}

	if destPath == "" {
		destPath = filepath.Join(s.lastDir(ctx, port.SettingLastExportDir),
			sanitizeFileName(book.Name)+exporter.Extension())
	}
	if err := os.MkdirAll(filepath.Dir(destPath), 0o755); err != nil {
		return nil, fmt.Errorf("创建导出目录失败: %w", err)
	}

	f, err := os.Create(destPath)
	if err != nil {
		return nil, fmt.Errorf("创建导出文件失败: %w", err)
	}
	defer f.Close()

	if err := exporter.Export(ctx, f, book, chapters, s.content.FetchContent(ctx, book)); err != nil {
		return nil, fmt.Errorf("导出失败: %w", err)
	}

	info, _ := f.Stat()
	var size int64
	if info != nil {
		size = info.Size()
	}
	if s.settings != nil {
		_ = s.settings.Set(ctx, port.SettingLastExportDir, filepath.Dir(destPath))
	}
	return &dto.ExportResult{Path: destPath, Format: string(format), Size: size}, nil
}

// lastDir 读取上次使用的目录，失败时回退到用户主目录。
func (s *LibraryService) lastDir(ctx context.Context, key string) string {
	if s.settings == nil {
		return "."
	}
	if dir, err := s.settings.Get(ctx, key); err == nil && dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "."
	}
	return home
}

// emitProgress 推送导入进度事件；事件总线不可用时静默跳过，
// 进度推送属于增强能力，不应影响主流程。
func (s *LibraryService) emitProgress(ctx context.Context, total, done int, current string) {
	if s.events == nil {
		return
	}
	_ = s.events.Emit(ctx, port.EventImportProgress, dto.ImportProgress{
		Total:   total,
		Done:    done,
		Current: current,
	})
}

// firstNonEmpty 返回首个非空字符串。
func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

// sanitizeFileName 剔除文件名中的非法字符。
func sanitizeFileName(name string) string {
	replacer := strings.NewReplacer("/", "_", "\\", "_", ":", "_", "*", "_", "?", "_", `"`, "_", "<", "_", ">", "_", "|", "_")
	out := replacer.Replace(strings.TrimSpace(name))
	if out == "" {
		return "untitled"
	}
	return out
}
