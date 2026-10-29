package api

import (
	"context"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
)

// LibraryAPI 暴露书籍导入导出能力。
type LibraryAPI struct {
	svc libraryService
}

// libraryService 是导入导出服务的能力契约。
type libraryService interface {
	ImportLocalFiles(ctx context.Context, paths []string, groupID int64) (*dto.ImportResult, error)
	ExportBook(ctx context.Context, bookID int64, format domain.BookFormat, destPath string) (*dto.ExportResult, error)
}

// NewLibraryAPI 创建导入导出绑定服务。
func NewLibraryAPI(svc libraryService) *LibraryAPI {
	return &LibraryAPI{svc: svc}
}

// ImportFiles 导入本地书籍文件到指定分组。
//
// paths 由前端通过文件选择对话框获取后传入（见 SystemAPI.OpenFiles）。
// 返回部分成功语义的结果：个别文件失败不中断整体。
func (a *LibraryAPI) ImportFiles(paths []string, groupID int64) (*dto.ImportResult, error) {
	if len(paths) == 0 {
		return nil, errBadRequest("未选择任何文件")
	}
	return a.svc.ImportLocalFiles(newCtx(), paths, groupID)
}

// ExportBook 导出书籍。
//
// format 取值：epub | txt；destPath 为空时由后端决定默认位置。
func (a *LibraryAPI) ExportBook(bookID int64, format string, destPath string) (*dto.ExportResult, error) {
	if bookID == 0 {
		return nil, errBadRequest("缺少书籍 ID")
	}
	f, err := parseFormat(format)
	if err != nil {
		return nil, err
	}
	return a.svc.ExportBook(newCtx(), bookID, f, destPath)
}

// parseFormat 校验并转换格式字符串。
// 这是绑定层分内之事：把前端的字符串收敛为领域枚举。
func parseFormat(s string) (domain.BookFormat, error) {
	switch domain.BookFormat(s) {
	case domain.BookFormatEPUB, domain.BookFormatTXT:
		return domain.BookFormat(s), nil
	case "":
		return "", errBadRequest("未指定导出格式")
	default:
		return "", errBadRequest("暂不支持导出格式: " + s)
	}
}
