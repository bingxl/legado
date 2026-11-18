// Command legado 是 headless 宿主：不启动任何 UI，直接驱动 core 的能力。
//
// 常用：
//
//	legado info
//	legado schema -o methods.json
//	legado methods Source
//	legado call Shelf.ListGroups
//	legado call Shelf.ListBooks '[1]'
//	legado serve -port 0
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/legado/core/boot"
	"github.com/legado/core/kernel"
	lghttp "github.com/legado/hosts/http"
	"github.com/legado/hosts/rt"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]

	var err error
	switch cmd {
	case "info":
		err = cmdInfo(args)
	case "schema":
		err = cmdSchema(args)
	case "methods":
		err = cmdMethods(args)
	case "call":
		err = cmdCall(args)
	case "serve":
		err = cmdServe(args)
	case "-h", "--help", "help":
		usage()
		return
	default:
		fmt.Fprintf(os.Stderr, "未知命令: %s\n\n", cmd)
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "错误:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `legado —— headless 宿主

用法:
  legado info                       打印运行时信息
  legado schema [-o file]           导出全部方法表（JSON）
  legado methods [Domain]           列出方法（可按域过滤）
  legado call <Method> [argsJSON]   调用方法，argsJSON 为位置参数数组
  legado serve [-port N]            启动 loopback HTTP（/rpc、/events）

环境变量:
  LEGADO_HOME   数据根目录（默认用户配置目录下的 legado）
`)
}

func cmdInfo(args []string) error {
	r, err := rt.Open("", boot.Options{}, "")
	if err != nil {
		return err
	}
	defer r.Close() //nolint:errcheck

	info, err := r.Call(context.Background(), "System.Info")
	if err != nil {
		return err
	}
	fmt.Printf("root:    %s\n", r.Reg.Env.Root)
	fmt.Printf("methods: %d\n", len(r.Reg.Methods()))
	fmt.Printf("version: %s\n", r.Reg.Env.Version)
	return printJSON(info)
}

func cmdSchema(args []string) error {
	fs := flag.NewFlagSet("schema", flag.ExitOnError)
	out := fs.String("o", "", "输出文件（默认 stdout）")
	_ = fs.Parse(args)

	r, err := rt.Open("", boot.Options{}, "")
	if err != nil {
		return err
	}
	defer r.Close() //nolint:errcheck

	b, err := json.MarshalIndent(r.Schema(), "", "  ")
	if err != nil {
		return err
	}
	if *out == "" {
		fmt.Println(string(b))
		return nil
	}
	if err := os.WriteFile(*out, b, 0o644); err != nil {
		return err
	}
	fmt.Printf("已写入 %s（%d 个方法）\n", *out, len(r.Reg.Methods()))
	return nil
}

func cmdMethods(args []string) error {
	fs := flag.NewFlagSet("methods", flag.ExitOnError)
	_ = fs.Parse(args)
	prefix := ""
	if fs.NArg() > 0 {
		prefix = fs.Arg(0)
	}

	r, err := rt.Open("", boot.Options{}, "")
	if err != nil {
		return err
	}
	defer r.Close() //nolint:errcheck

	names := r.Reg.SortedNames()
	filtered := names[:0]
	for _, n := range names {
		if prefix == "" || strings.HasPrefix(n, prefix+".") || strings.EqualFold(n, prefix) {
			filtered = append(filtered, n)
		}
	}
	sort.Strings(filtered)
	for _, n := range filtered {
		m, _ := r.Reg.Lookup(n)
		fmt.Printf("%-28s %s\n", n, kernel.DocOf(*m))
	}
	fmt.Printf("\n合计 %d 个方法\n", len(filtered))
	return nil
}

func cmdCall(args []string) error {
	fs := flag.NewFlagSet("call", flag.ExitOnError)
	pretty := fs.Bool("pretty", true, "缩进输出")
	home := fs.String("home", "", "数据根目录")
	_ = fs.Parse(args)
	if fs.NArg() < 1 {
		return fmt.Errorf("缺少方法名，例如: legado call Shelf.ListGroups")
	}
	method := fs.Arg(0)

	var rawArgs []json.RawMessage
	if fs.NArg() > 1 {
		raw := []byte(fs.Arg(1))
		if len(raw) > 0 && raw[0] == '[' {
			if err := json.Unmarshal(raw, &rawArgs); err != nil {
				return fmt.Errorf("参数不是合法 JSON 数组: %w", err)
			}
		} else {
			rawArgs = []json.RawMessage{raw}
		}
	}

	r, err := rt.Open(*home, boot.Options{}, "")
	if err != nil {
		return err
	}
	defer r.Close() //nolint:errcheck

	data, err := r.Reg.Call(context.Background(), method, rawArgs)
	if err != nil {
		return err
	}
	if !*pretty {
		return printJSON(data)
	}
	b, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	return nil
}

func printJSON(v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	return nil
}

// cmdServe 启动 loopback HTTP。端口 0 时打印实际端口，供 UI 或脚本连接。
func cmdServe(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	port := fs.Int("port", 0, "监听端口，0 表示随机")
	home := fs.String("home", "", "数据根目录")
	_ = fs.Parse(args)

	r, err := rt.Open(*home, boot.Options{}, "")
	if err != nil {
		return err
	}
	defer r.Close() //nolint:errcheck

	s := lghttp.New(r, fmt.Sprintf("127.0.0.1:%d", *port))
	if err := s.Listen(fmt.Sprintf("127.0.0.1:%d", *port)); err != nil {
		return err
	}
	fmt.Printf("listening %s\n", s.URL())
	select {} // 由信号终止
}
