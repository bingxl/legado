// Command dictbuild 把上游词典数据构建成词典 SQLite 库。
//
// 这是**离线构建工具**，不参与应用运行：
//
//	go run ./cmd/dictbuild -csv ecdict.csv -tier core -out internal/app/dictdata/en-zh.core.v1.db
//	go run ./cmd/dictbuild -cedict cedict_ts.u8 -out /tmp/zh-en.db
//
// 转换逻辑本身在 internal/adapter/dictbuild 里，与运行时「下载后转换」
// 共用同一份实现——两处各写一份会让 schema 与词形规则悄悄漂移。
package main

import (
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/legado/desktop/internal/adapter/dictbuild"
)

func main() {
	var (
		csvPath = flag.String("csv", "ecdict.csv", "ECDICT 的 ecdict.csv 路径")
		cedict  = flag.String("cedict", "", "CC-CEDICT 的 cedict_ts.u8 路径（给了就走汉英库）")
		out     = flag.String("out", "en-zh.db", "输出 SQLite 路径")
		tier    = flag.String("tier", "core", "裁剪档位：core(3万) / standard(6万) / full(全量)")
		gz      = flag.Bool("gz", true, "同时输出 <out>.gz")
		quiet   = flag.Bool("quiet", false, "不打印进度")
	)
	flag.Parse()

	ctx := context.Background()
	var (
		entries int
		err     error
	)
	progress := func(done, total int64) {
		if *quiet || total == 0 {
			return
		}
		fmt.Printf("\r处理中 %5.1f%%", float64(done)/float64(total)*100)
	}
	if *cedict != "" {
		entries, err = dictbuild.CEDICT(ctx, *cedict, *out, progress)
	} else {
		entries, err = dictbuild.ECDICT(ctx, *csvPath, *out, *tier, progress)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "\n构建失败:", err)
		os.Exit(1)
	}
	if !*quiet {
		fmt.Println()
	}

	info, err := os.Stat(*out)
	if err != nil {
		fmt.Fprintln(os.Stderr, "构建失败:", err)
		os.Exit(1)
	}
	sum, err := fileSHA256(*out)
	if err != nil {
		fmt.Fprintln(os.Stderr, "构建失败:", err)
		os.Exit(1)
	}
	if *gz {
		if err := gzipFile(*out, *out+".gz"); err != nil {
			fmt.Fprintln(os.Stderr, "构建失败:", err)
			os.Exit(1)
		}
	}
	fmt.Printf("词条数   %d\n", entries)
	fmt.Printf("体积     %.2f MB\n", float64(info.Size())/(1<<20))
	fmt.Printf("sha256   %s\n", sum)
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close() //nolint:errcheck
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// gzipFile 以最高压缩级别写 .gz。
//
// 用 BestCompression 而不是默认级别：产物随二进制分发，
// 2 MB 与 2.6 MB 的差别会体现在每个用户的下载量上，而构建只做一次。
func gzipFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close() //nolint:errcheck

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	zw, err := gzip.NewWriterLevel(out, gzip.BestCompression)
	if err != nil {
		out.Close() //nolint:errcheck
		return err
	}
	if _, err := io.Copy(zw, in); err != nil {
		zw.Close() //nolint:errcheck
		out.Close()
		return err
	}
	if err := zw.Close(); err != nil {
		out.Close() //nolint:errcheck
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	info, err := os.Stat(dst)
	if err != nil {
		return err
	}
	fmt.Printf("gz 体积  %.2f MB -> %s\n", float64(info.Size())/(1<<20), dst)
	return nil
}
