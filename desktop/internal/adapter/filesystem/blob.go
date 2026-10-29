// Package filesystem 提供基于本地文件系统与 xdg 目录规范的实现。
package filesystem

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/adrg/xdg"
	"github.com/legado/desktop/internal/port"
)

// BlobStore 实现 port.BlobStore，把资源写入应用数据目录。
type BlobStore struct {
	root string
}

// NewBlobStore 在 root 目录下管理二进制资源；root 为空时使用 xdg 数据目录。
func NewBlobStore(root string) (*BlobStore, error) {
	if root == "" {
		root = filepath.Join(xdg.DataHome, "legado-desktop")
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, fmt.Errorf("创建数据目录失败: %w", err)
	}
	return &BlobStore{root: root}, nil
}

var _ port.BlobStore = (*BlobStore)(nil)

// Save 保存资源并返回其绝对路径。
//
// name 会做清洗：剔除路径分隔符，防止目录穿越。
func (s *BlobStore) Save(ctx context.Context, category, name string, r io.Reader) (string, error) {
	if category == "" || name == "" {
		return "", fmt.Errorf("分类与文件名不能为空")
	}
	dir := filepath.Join(s.root, cleanPath(category))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("创建资源目录失败: %w", err)
	}
	path := filepath.Join(dir, cleanPath(name))

	f, err := os.Create(path)
	if err != nil {
		return "", fmt.Errorf("创建资源文件失败: %w", err)
	}
	defer f.Close()

	if _, err := io.Copy(f, r); err != nil {
		return "", fmt.Errorf("写入资源失败: %w", err)
	}
	return path, nil
}

// Remove 删除资源。
func (s *BlobStore) Remove(ctx context.Context, category, name string) error {
	return os.Remove(filepath.Join(s.root, cleanPath(category), cleanPath(name)))
}

// Root 返回资源根目录。
func (s *BlobStore) Root() string { return s.root }

// cleanPath 剔除分隔符与上级目录引用，杜绝目录穿越。
func cleanPath(name string) string {
	name = strings.ReplaceAll(name, "..", "")
	name = strings.ReplaceAll(name, "/", "_")
	name = strings.ReplaceAll(name, "\\", "_")
	return strings.TrimSpace(name)
}
