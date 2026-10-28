package main

import (
	"fmt"
	"os"

	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/source"
)

// cmdValidate 校验书源语法：默认离线，加 -online 连网实测
func cmdValidate(args []string) {
	fs, g := newFlags("validate")
	online := fs.Bool("online", false, "连网实际校验（搜索/详情/目录/正文）")
	keyword := fs.String("key", "", "在线校验使用的关键字")
	onlyBad := fs.Bool("bad", false, "只输出有问题的书源")
	g.parse(args)

	if !*online {
		validateOffline(g, *onlyBad)
		return
	}
	validateOnline(g, *keyword)
}

// validateOffline 只做语法检查，不需要建引擎
func validateOffline(g *globalFlags, onlyBad bool) {
	list := loadSources(g)
	bad := 0
	for _, s := range list {
		r := source.Validate(s)
		if onlyBad && r.OK() {
			continue
		}
		if !r.OK() {
			bad++
		}
		printSourceIssues(s.BookSourceName, s.BookSourceUrl, sourceIssueLines(r.Issues))
	}
	fmt.Printf("\n共 %d 个书源，%d 个存在错误\n", len(list), bad)
	if bad > 0 {
		os.Exit(2)
	}
}

// validateOnline 按 -source 决定校验一个还是全部书源
func validateOnline(g *globalFlags, keyword string) {
	e := newEngine(g)
	items := source.CheckItems{Search: true, Info: true, Toc: true, Content: true}

	if g.source != "" {
		r := source.ValidateOnline(resolveSource(e, g), keyword, items)
		printResult(r)
		if !r.OK() {
			os.Exit(2)
		}
		return
	}
	for _, s := range e.Sources {
		printResult(source.ValidateOnline(s, keyword, items))
	}
}

// loadSources 按 -file/-dir 加载书源（-file 优先）
func loadSources(g *globalFlags) []*model.BookSource {
	switch {
	case g.file != "":
		list, err := source.LoadFile(g.file)
		if err != nil {
			failErr("加载书源", err)
		}
		return list
	case g.dir != "":
		list, errs := source.LoadDir(g.dir)
		for _, e := range errs {
			fmt.Fprintln(os.Stderr, "加载警告:", e)
		}
		return list
	default:
		failf("请用 -dir 指定书源文件夹或 -file 指定书源文件")
		return nil
	}
}

// printResult 输出单个书源的在线校验结果
func printResult(r *source.Result) {
	printSourceIssues(r.Source.BookSourceName, r.Source.BookSourceUrl, sourceIssueLines(r.Issues))
}
