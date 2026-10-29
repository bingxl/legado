package bookparser

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/legado/desktop/internal/domain"
)

// sampleDirEnv 指向真实 EPUB 样本目录的环境变量名。
//
// EPUB 体积大且不便入库，因此真机回归默认关闭：
// 仅当设置该变量时才遍历解析，供本地或 CI 在具备样本时启用。
//
//	LEGADO_EPUB_SAMPLE_DIR=~/Downloads go test ./internal/adapter/bookparser -run TestRealEPUB -v
const sampleDirEnv = "LEGADO_EPUB_SAMPLE_DIR"

// TestRealEPUBSamples 用真实 EPUB 做端到端回归，覆盖各类排版与规范变体。
//
// 它的价值在于捕捉"构造样本发现不了"的问题：畸形文件引起的 panic、
// 目录未收录页面的标题退化、封面被声明成损坏文件等，都是在真实书籍上才暴露的。
func TestRealEPUBSamples(t *testing.T) {
	dir := os.Getenv(sampleDirEnv)
	if dir == "" {
		t.Skipf("未设置 %s，跳过真机回归", sampleDirEnv)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("读取样本目录失败: %v", err)
	}

	parser := NewEPUBParser()
	var checked int
	for _, e := range entries {
		if e.IsDir() || !strings.EqualFold(filepath.Ext(e.Name()), ".epub") {
			continue
		}
		path := filepath.Join(dir, e.Name())
		checked++
		// 子测试让单本书的失败能独立定位，且不会中断其余样本的验证。
		t.Run(e.Name(), func(t *testing.T) {
			parsed, err := parser.Parse(context.Background(), path)
			if err != nil {
				t.Fatalf("解析失败: %v", err)
			}
			if len(parsed.Chapters) == 0 {
				t.Fatal("解析结果没有任何章节")
			}
			if parsed.Meta.Title == "" {
				t.Error("未提取到书名")
			}
			for _, ch := range parsed.Chapters {
				if ch.Resource == "" {
					t.Fatalf("章节 %q 缺少定位信息", ch.Title)
				}
				if ch.Title == "" {
					t.Fatalf("章节 %d 缺少标题", ch.Index)
				}
			}

			// 读取首章与末章：末章常被目录忽略，是标题退化的高发位置。
			for _, idx := range []int{0, len(parsed.Chapters) - 1} {
				content, err := parser.Content(context.Background(), path, parsed.Chapters[idx])
				if err != nil {
					t.Fatalf("读取章节 %d 失败: %v", idx, err)
				}
				if content.HTML == "" {
					t.Errorf("章节 %d 的正文为空", idx)
				}
			}
		})
	}

	if checked == 0 {
		t.Fatalf("样本目录 %s 下没有 .epub 文件", dir)
	}
	t.Logf("已校验 %d 本真实 EPUB", checked)
}

// TestParseRejectsNonEPUB 确认解析器对非 EPUB 内容不会误判或崩溃。
func TestParseRejectsNonEPUB(t *testing.T) {
	path := filepath.Join(t.TempDir(), "not-an-epub.epub")
	if err := os.WriteFile(path, []byte("这不是 EPUB，只是一段文本"), 0o600); err != nil {
		t.Fatalf("准备测试文件失败: %v", err)
	}

	parser := NewEPUBParser()
	if _, err := parser.Parse(context.Background(), path); err == nil {
		t.Fatal("非 EPUB 文件应当解析失败，但未返回错误")
	}
}

// TestFormat 是格式标识的契约检查，防止注册表分发时取错解析器。
func TestFormat(t *testing.T) {
	if got := NewEPUBParser().Format(); got != domain.BookFormatEPUB {
		t.Fatalf("格式标识应为 EPUB，实际 %q", got)
	}
}
