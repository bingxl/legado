package app

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// stubFileFlagBooks 只实现 List/Get，其余方法留空（被调用即 panic，便于尽早发现）。
type stubFileFlagBooks struct {
	port.BookRepository
	list  []*domain.Book
	byID  map[int64]*domain.Book
	first *domain.Book
}

func (s *stubFileFlagBooks) List(context.Context, int64) ([]*domain.Book, error) { return s.list, nil }

func (s *stubFileFlagBooks) Get(_ context.Context, id int64) (*domain.Book, error) {
	if b, ok := s.byID[id]; ok {
		return b, nil
	}
	return nil, domain.ErrNotFound
}

// 本地书源文件被移走后，ListBooks/GetBook 应把它标注为 fileMissing，
// 让前端在书架/详情/阅读器给出明确提示，而不是反复弹 OS 原始报错。
func TestLocalBookFileMissingFlag(t *testing.T) {
	dir := t.TempDir()
	okPath := filepath.Join(dir, "exists.txt")
	if err := os.WriteFile(okPath, []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	gonePath := filepath.Join(dir, "gone.txt") // 故意不创建

	books := []*domain.Book{
		{ID: 1, Name: "在的", Kind: domain.BookKindLocal, Format: domain.BookFormatTXT, BookURL: okPath},
		{ID: 2, Name: "丢的", Kind: domain.BookKindLocal, Format: domain.BookFormatTXT, BookURL: gonePath},
		{ID: 3, Name: "网络书", Kind: domain.BookKindWeb, BookURL: "https://example.com/b/3"},
	}
	byID := map[int64]*domain.Book{}
	for _, b := range books {
		byID[b.ID] = b
	}
	svc := NewBookshelfService(&stubFileFlagBooks{list: books, byID: byID}, nil, nil, nil)

	briefs, err := svc.ListBooks(context.Background(), 0)
	if err != nil {
		t.Fatalf("ListBooks 出错: %v", err)
	}
	if briefs[0].FileMissing {
		t.Error("文件还在的本地书不应标注缺失")
	}
	if !briefs[1].FileMissing {
		t.Error("文件被移走的本地书应标注缺失")
	}
	if briefs[2].FileMissing {
		t.Error("网络书永远不应标注缺失")
	}

	detail, err := svc.GetBook(context.Background(), 2)
	if err != nil {
		t.Fatalf("GetBook 出错: %v", err)
	}
	if !detail.FileMissing {
		t.Error("详情页也应标注缺失")
	}
}
