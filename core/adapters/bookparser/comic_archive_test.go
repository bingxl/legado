package bookparser

import (
	"archive/zip"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// makeComicTree 造一棵「两话、每话两张图」的素材目录。
func makeComicTree(t *testing.T, root string) {
	t.Helper()
	for _, vol := range []string{"第1话", "第2话"} {
		dir := filepath.Join(root, vol)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("建目录失败: %v", err)
		}
		for i := 1; i <= 2; i++ {
			name := filepath.Join(dir, fmt.Sprintf("p%d.jpg", i))
			if err := os.WriteFile(name, []byte{0xFF, 0xD8, 0xFF, byte(i)}, 0o644); err != nil {
				t.Fatalf("写图片失败: %v", err)
			}
		}
	}
	// 混入不该收的文件，验证过滤
	_ = os.WriteFile(filepath.Join(root, "第1话", "info.txt"), []byte("x"), 0o644)
	_ = os.WriteFile(filepath.Join(root, "第1话", ".DS_Store"), []byte("x"), 0o644)
}

// makeZip 把 sourceDir 下的内容打成 zip（条目保留顶层目录名）。
func makeZip(t *testing.T, sourceDir, dest string) {
	t.Helper()
	f, err := os.Create(dest)
	if err != nil {
		t.Fatalf("创建 zip 失败: %v", err)
	}
	defer f.Close()
	zw := zip.NewWriter(f)
	err = filepath.Walk(sourceDir, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(sourceDir, p)
		w, err := zw.Create(filepath.ToSlash(rel))
		if err != nil {
			return err
		}
		data, _ := os.ReadFile(p)
		_, err = w.Write(data)
		return err
	})
	if err != nil {
		t.Fatalf("写 zip 失败: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("关闭 zip 失败: %v", err)
	}
}

// checkComic 校验解析结果：2 话、每话 2 张图、URL 可直接映射到磁盘文件。
func checkComic(t *testing.T, archivePath string) {
	t.Helper()
	cache := t.TempDir()
	p := NewComicParser(cache, "/local/comic")
	parsed, err := p.Parse(context.Background(), archivePath)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if len(parsed.Chapters) != 2 {
		t.Fatalf("期望 2 话，实际 %d: %v", len(parsed.Chapters), chapterTitles(parsed.Chapters))
	}
	if parsed.Chapters[0].Title != "第1话" || parsed.Chapters[1].Title != "第2话" {
		t.Fatalf("话名/排序不符: %v", chapterTitles(parsed.Chapters))
	}
	for _, ch := range parsed.Chapters {
		content, err := p.Content(context.Background(), archivePath, ch)
		if err != nil {
			t.Fatalf("取《%s》内容失败: %v", ch.Title, err)
		}
		if len(content.Images) != 2 {
			t.Fatalf("《%s》期望 2 张图（txt/.DS_Store 应被过滤），实际 %d: %v",
				ch.Title, len(content.Images), content.Images)
		}
		for _, u := range content.Images {
			// /local/comic/<相对路径> → 去掉前缀后应在缓存目录存在且非空
			rel := strings.TrimPrefix(u, "/local/comic/")
			info, err := os.Stat(filepath.Join(cache, filepath.FromSlash(rel)))
			if err != nil {
				t.Fatalf("图片未落盘: %s (%v)", u, err)
			}
			if info.Size() == 0 {
				t.Fatalf("图片为空: %s", u)
			}
		}
	}
}

func TestComicParser_Zip(t *testing.T) {
	src := t.TempDir()
	makeComicTree(t, src)
	archive := filepath.Join(t.TempDir(), "book.cbz")
	makeZip(t, src, archive)
	checkComic(t, archive)
}

func TestComicParser_SevenZip(t *testing.T) {
	seven := find7Zip()
	if seven == "" {
		t.Skip("未安装 7-Zip，跳过 7z 用例")
	}
	src := t.TempDir()
	makeComicTree(t, src)
	archive := filepath.Join(t.TempDir(), "book.7z")

	cmd := exec.Command(seven, "a", "-t7z", "-bso0", "-bsp0", archive, ".")
	cmd.Dir = src
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("7z 打包失败: %v\n%s", err, out)
	}
	checkComic(t, archive)
}

// 扩展名撒谎时必须按文件头识别（网上下的 .zip 常有实为 rar 的情况）。
func TestDetectArchiveKind(t *testing.T) {
	dir := t.TempDir()
	cases := []struct {
		name string
		head []byte
		ext  string
		want archiveKind
	}{
		{"a.zip", []byte("PK\x03\x04rest"), ".zip", archiveKindZip},
		{"b.rar", []byte("Rar!\x1a\x07\x00rest"), ".rar", archiveKindRar},
		{"c.7z", []byte("7z\xbc\xaf\x27\x1crest"), ".7z", archiveKindSevenZip},
		{"d.cbz", []byte("Rar!\x1a\x07\x00rest"), ".cbz", archiveKindZip}, // 扩展名优先
		{"e.bin", []byte("Rar!\x1a\x07\x00rest"), ".bin", archiveKindRar}, // 未知扩展名看魔数
	}
	for _, c := range cases {
		p := filepath.Join(dir, c.name)
		if err := os.WriteFile(p, c.head, 0o644); err != nil {
			t.Fatal(err)
		}
		if got := detectArchiveKind(p); got != c.want {
			t.Errorf("%s: 期望 %v，实际 %v", c.name, c.want, got)
		}
	}
}

// find7Zip 定位 7-Zip 可执行文件；找不到返回空串。
func find7Zip() string {
	candidates := []string{
		`C:\Program Files\7-Zip\7z.exe`,
		`C:\Program Files (x86)\7-Zip\7z.exe`,
		"/usr/bin/7z", "/usr/bin/7za", "/opt/homebrew/bin/7z",
	}
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c
		}
	}
	if p, err := exec.LookPath("7z"); err == nil {
		return p
	}
	return ""
}
