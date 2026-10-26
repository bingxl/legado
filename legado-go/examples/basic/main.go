// 一个最小的使用示例：搜索 → 详情 → 目录 → 正文 → 下载。
//
// 运行：
//
//	go run ./examples/basic -dir ../sources -source yumanhua -key 海贼
package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	legado "github.com/legado/legado-go"
	"github.com/legado/legado-go/pkg/download"
)

func main() {
	dir := flag.String("dir", "./sources", "书源文件夹")
	file := flag.String("file", "", "单个书源文件（优先于 -dir）")
	source := flag.String("source", "", "书源 URL 或名称（子串匹配）")
	key := flag.String("key", "", "搜索关键字")
	out := flag.String("out", "./out", "下载目录")
	maxCh := flag.Int("max", 3, "最多下载章节数")
	flag.Parse()

	if *key == "" {
		fmt.Fprintln(os.Stderr, "请用 -key 指定搜索关键字")
		os.Exit(2)
	}

	e, err := legado.New(legado.Config{
		SourceDir:  *dir,
		SourceFile: *file,
		CookieFile: "./cookies.json",
		CacheFile:  "./cache.json",
		JSTimeout:  30 * time.Second,
		Log:        func(msg string) { fmt.Println("[js]", msg) },
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "加载书源失败:", err)
		os.Exit(1)
	}
	for _, le := range e.LoadErrors {
		fmt.Fprintln(os.Stderr, "加载警告:", le)
	}

	// 搜索 → 取第一本
	list, err := e.Search(*source, *key, 1)
	if err != nil {
		fmt.Fprintln(os.Stderr, "搜索失败:", err)
		os.Exit(1)
	}
	if len(list) == 0 {
		fmt.Fprintln(os.Stderr, "搜索结果为空")
		os.Exit(1)
	}
	book := list[0].ToBook()
	fmt.Printf("命中 %d 条，取第一本：《%s》 %s\n", len(list), book.Name, book.Author)

	// 详情（补全简介、封面、tocUrl）
	if err := e.GetBookInfo(*source, book); err != nil {
		fmt.Fprintln(os.Stderr, "获取详情失败:", err)
	}

	// 目录
	chapters, err := e.GetChapterList(*source, book)
	if err != nil {
		fmt.Fprintln(os.Stderr, "获取目录失败:", err)
		os.Exit(1)
	}
	fmt.Printf("共 %d 章\n", len(chapters))

	// 单章正文（前 200 字）
	if len(chapters) > 0 {
		txt, err := e.GetContent(*source, book, chapters[0])
		if err != nil {
			fmt.Fprintln(os.Stderr, "获取正文失败:", err)
		} else {
			if r := []rune(txt); len(r) > 200 {
				txt = string(r[:200]) + "…"
			}
			fmt.Printf("第一章「%s」：\n%s\n", chapters[0].Title, txt)
		}
	}

	// 整本下载
	res, err := e.Download(*source, book, download.Options{
		OutDir:  *out,
		Workers: 8,
		Max:     *maxCh,
		Progress: func(done, total int, title string) {
			fmt.Printf("\r下载 %d/%d %s", done, total, title)
		},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "\n下载失败:", err)
		os.Exit(1)
	}
	fmt.Println()
	fmt.Println(res.String())

	// Cookie 落盘，下次启动自动加载
	if err := e.SaveCookies(); err != nil {
		fmt.Fprintln(os.Stderr, "保存 Cookie 失败:", err)
	}
}
