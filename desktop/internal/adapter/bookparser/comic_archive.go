package bookparser

import (
	"archive/zip"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/bodgit/sevenzip"
	"github.com/nwaples/rardecode/v2"

	"github.com/legado/desktop/internal/domain"
)

// 本文件把 zip / rar / 7z 统一成同一套只读视图，供 ComicParser 使用。
//
// 三个库的能力并不一致，这是抽象成「先列名、再按名集合解压」两步的原因：
//   - archive/zip 与 sevenzip 支持按名随机读取；
//   - rardecode 只能顺序 Next()，solid 压缩下尤其不能跳读，因此解压时要重新扫一遍。
//
// 全部为纯 Go 实现，无需 cgo——这对三平台交叉编译是硬要求。

// maxEntryBytes 单个图片条目的解压上限，防止压缩炸弹。
const maxEntryBytes = 64 << 20

// comicArchive 是漫画压缩包的统一只读视图。
type comicArchive interface {
	// images 返回包内所有图片条目名（'/' 分隔、已过滤系统垃圾文件）
	images() []string
	// extract 解压名字在 names 中的条目，目标路径由 dest 决定；返回成功解压的数量
	extract(names map[string]bool, dest func(name string) string) (int, error)
	close() error
}

// openComicArchive 按扩展名 + 魔数打开压缩包。
func openComicArchive(p string) (comicArchive, error) {
	switch detectArchiveKind(p) {
	case archiveKindZip:
		rc, err := zip.OpenReader(p)
		if err != nil {
			return nil, fmt.Errorf("%w: 无法打开 zip: %s", domain.ErrParseFailed, err.Error())
		}
		return &zipComicArchive{rc}, nil
	case archiveKindRar:
		// rardecode 的 ReadCloser 是流式的，先试读一次确认可打开
		rc, err := rardecode.OpenReader(p)
		if err != nil {
			return nil, fmt.Errorf("%w: 无法打开 rar: %s", domain.ErrParseFailed, err.Error())
		}
		_ = rc.Close()
		return &rarComicArchive{path: p}, nil
	case archiveKindSevenZip:
		rc, err := sevenzip.OpenReader(p)
		if err != nil {
			return nil, fmt.Errorf("%w: 无法打开 7z: %s", domain.ErrParseFailed, err.Error())
		}
		return &sevenZipComicArchive{rc}, nil
	}
	return nil, fmt.Errorf("%w: 不支持的压缩格式: %s", domain.ErrParseFailed, filepath.Ext(p))
}

type archiveKind int

const (
	archiveKindUnknown archiveKind = iota
	archiveKindZip
	archiveKindRar
	archiveKindSevenZip
)

// detectArchiveKind 先看扩展名，扩展名不认识时再看文件头。
//
// 只信扩展名是不够的：网上下载的漫画常有 .zip 实际是 rar 的情况。
func detectArchiveKind(p string) archiveKind {
	switch strings.ToLower(filepath.Ext(p)) {
	case ".zip", ".cbz":
		return archiveKindZip
	case ".rar", ".cbr":
		return archiveKindRar
	case ".7z", ".cb7":
		return archiveKindSevenZip
	}
	if k := sniffArchiveKind(p); k != archiveKindUnknown {
		return k
	}
	// 无扩展名或扩展名陌生时按 zip 兜底（最常见）
	return archiveKindZip
}

// sniffArchiveKind 读取文件头判断真实格式。
func sniffArchiveKind(p string) archiveKind {
	f, err := os.Open(p)
	if err != nil {
		return archiveKindUnknown
	}
	defer f.Close() //nolint:errcheck
	var head [8]byte
	n, _ := io.ReadFull(f, head[:])
	if n < 4 {
		return archiveKindUnknown
	}
	switch {
	case head[0] == 'P' && head[1] == 'K':
		return archiveKindZip
	case head[0] == 'R' && head[1] == 'a' && head[2] == 'r' && head[3] == '!':
		return archiveKindRar
	case head[0] == '7' && head[1] == 'z' && head[2] == 0xBC && head[3] == 0xAF:
		return archiveKindSevenZip
	}
	return archiveKindUnknown
}

// isComicImageName 判断包内条目是否是想要的图片。
func isComicImageName(name string) bool {
	n := path.Clean(filepath.ToSlash(name))
	if n == "." || strings.HasSuffix(n, "/") {
		return false
	}
	// macOS 打包时附带的资源分支目录，整棵树都是垃圾
	if strings.HasPrefix(n, "__MACOSX/") || strings.HasPrefix(n, ".") {
		return false
	}
	if base := path.Base(n); strings.HasPrefix(base, "._") || base == ".DS_Store" {
		return false
	}
	return comicImageExts[strings.ToLower(path.Ext(n))]
}

// —— zip ——

type zipComicArchive struct {
	rc *zip.ReadCloser
}

func (z *zipComicArchive) images() []string {
	out := make([]string, 0, len(z.rc.File))
	for _, f := range z.rc.File {
		if f.FileInfo().IsDir() {
			continue
		}
		if n := path.Clean(filepath.ToSlash(f.Name)); isComicImageName(n) {
			out = append(out, n)
		}
	}
	return out
}

func (z *zipComicArchive) extract(names map[string]bool, dest func(string) string) (int, error) {
	n := 0
	for _, f := range z.rc.File {
		name := path.Clean(filepath.ToSlash(f.Name))
		if !names[name] {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			continue // 单张失败不影响其余
		}
		if err := writeEntry(dest(name), rc); err == nil {
			n++
		}
		_ = rc.Close()
	}
	return n, nil
}

func (z *zipComicArchive) close() error { return z.rc.Close() }

// —— rar ——

// rarComicArchive 只记路径：rar 无法随机读取，每次列名/解压都要重新打开顺序扫。
type rarComicArchive struct {
	path string
}

func (r *rarComicArchive) images() []string {
	rc, err := rardecode.OpenReader(r.path)
	if err != nil {
		return nil
	}
	defer rc.Close() //nolint:errcheck

	var out []string
	for {
		hdr, err := rc.Next()
		if err != nil {
			break
		}
		if hdr.IsDir || hdr.Encrypted {
			continue
		}
		if n := path.Clean(filepath.ToSlash(hdr.Name)); isComicImageName(n) {
			out = append(out, n)
		}
	}
	return out
}

func (r *rarComicArchive) extract(names map[string]bool, dest func(string) string) (int, error) {
	rc, err := rardecode.OpenReader(r.path)
	if err != nil {
		return 0, fmt.Errorf("%w: 无法打开 rar: %s", domain.ErrParseFailed, err.Error())
	}
	defer rc.Close() //nolint:errcheck

	n := 0
	for {
		hdr, err := rc.Next()
		if err != nil {
			break
		}
		if hdr.IsDir || hdr.Encrypted {
			continue
		}
		name := path.Clean(filepath.ToSlash(hdr.Name))
		if !names[name] {
			continue
		}
		// rc 本身就是当前条目的读取流
		if err := writeEntry(dest(name), rc); err == nil {
			n++
		}
	}
	return n, nil
}

func (r *rarComicArchive) close() error { return nil }

// —— 7z ——

type sevenZipComicArchive struct {
	rc *sevenzip.ReadCloser
}

func (s *sevenZipComicArchive) images() []string {
	return walkImageNames(s.rc)
}

func (s *sevenZipComicArchive) extract(names map[string]bool, dest func(string) string) (int, error) {
	n := 0
	for name := range names {
		f, err := s.rc.Open(name)
		if err != nil {
			continue
		}
		if err := writeEntry(dest(name), f); err == nil {
			n++
		}
		_ = f.Close()
	}
	return n, nil
}

func (s *sevenZipComicArchive) close() error { return s.rc.Close() }

// walkImageNames 递归遍历 fs.FS，收集图片条目名。
//
// 不用 fs.WalkDir 是因为 sevenzip 的目录项能否被 WalkDir 正确识别并不确定，
// 这里直接用 Open + ReadDir 自己走，兼容性最好。
func walkImageNames(fsys fs.FS) []string {
	var out []string
	var walk func(dir string)
	walk = func(dir string) {
		f, err := fsys.Open(dir)
		if err != nil {
			return
		}
		defer f.Close() //nolint:errcheck
		rd, ok := f.(fs.ReadDirFile)
		if !ok {
			return
		}
		entries, err := rd.ReadDir(-1)
		if err != nil {
			return
		}
		for _, e := range entries {
			p := path.Join(dir, e.Name())
			if e.IsDir() {
				walk(p)
				continue
			}
			if n := path.Clean(p); isComicImageName(n) {
				out = append(out, n)
			}
		}
	}
	walk(".")
	return out
}

// writeEntry 把条目内容写到 dest（带体积上限）。
func writeEntry(dest string, src io.Reader) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer out.Close() //nolint:errcheck
	n, err := io.Copy(out, io.LimitReader(src, maxEntryBytes))
	if err != nil {
		return err
	}
	if n == 0 {
		return errors.New("空条目")
	}
	return nil
}
