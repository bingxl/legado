// Package dictdata 内嵌随二进制分发的最小词库。
//
// 为什么要内嵌而不是让用户先下载：下载链路是这个功能唯一的高失败环节
// （实测 GitHub 直连 27 KB/s、镜像 283 KB/s，46 MB 的全量包要几分钟），
// 把「查个常用词」绑在一条可能失败的下载上，等于给核心阅读体验加单点故障。
// 4 MB 换「永不失败」划算——见设计方案 §4.1。
//
// 文件由 cmd/dictbuild 生成，**不要手改**：
//
//	go run ./cmd/dictbuild -csv ecdict.csv -tier core \
//	    -out internal/app/dictdata/en-zh.core.v1.db
package dictdata

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"

	_ "embed"
)

// CoreVersion 是内置核心词库的版本号。
//
// 换词库必须同时改这里与文件名，两者不一致会导致「升级后仍读旧库」：
// 解压目标是 <data>/dict/en-zh.core.<CoreVersion>.db，版本号不变就不会重新解压。
//
// 命名带数据源与档位：ecd(ECDICT) - 1.0(构建规则版本)。
const CoreVersion = "ecd-1.0"

// CoreEntries 与 CoreBuiltAt 是构建产物的事实，用于设置页展示「词库是不是太旧」。
//
// 重新生成词库时必须同步更新这两个值（cmd/dictbuild 会把真实数字打印出来）。
// 它们只影响展示，查词逻辑不依赖它们。
const (
	CoreEntries = 38243
	CoreBuiltAt = "2026-11-08"
)

//go:embed en-zh.core.v1.db.gz
var coreGz []byte

//go:embed manifest.json
var manifestJSON []byte

// SourceCoord 是扩展包在仓库里的**与镜像无关**的坐标。
//
// 只存 repo / ref / path，不存任何镜像地址：地址由「源配置 + 模板 + 坐标」
// 现场拼出来。这样加新镜像不用发版，镜像也永远拿不到哈希（投毒无门）。
type SourceCoord struct {
	Repo string `json:"repo"`
	Ref  string `json:"ref"`
	Path string `json:"path"`
	// Form 是托管形态：raw（raw.githubusercontent）或 release（Release 资产）。
	Form string `json:"form"`
	// Size 与 SHA256 是**源文件**的，用于下载后校验。
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

// Pack 是一个可安装的扩展包。
type Pack struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	FileName string `json:"fileName"`
	// Kind 决定用哪个转换器：ecdict / cedict。空表示直接落位 .db（预留）。
	Kind string `json:"kind"`
	// Tier 只对 ecdict 有意义：core / standard / full。
	Tier    string `json:"tier"`
	Entries int    `json:"entries"`
	BuiltAt string `json:"builtAt"`
	// SourceLabel 是界面上「来源与许可」那一行的文案。
	SourceLabel string `json:"sourceLabel"`
	// DownloadBytes 是源文件体积，InstalledBytes 是转换后 .db 的估算体积。
	// 两者都给出来，用户才知道「下 66 MB 换 47 MB」这件事。
	DownloadBytes  int64       `json:"downloadBytes"`
	InstalledBytes int64       `json:"installedBytes"`
	Source         SourceCoord `json:"source"`
}

type manifestFile struct {
	Version int    `json:"version"`
	Packs   []Pack `json:"packs"`
}

var (
	manifestOnce sync.Once
	manifestVal  []Pack
	manifestErr  error
)

// ExtPacks 返回内嵌清单里的扩展包。
func ExtPacks() ([]Pack, error) {
	manifestOnce.Do(func() {
		var mf manifestFile
		if err := json.Unmarshal(manifestJSON, &mf); err != nil {
			manifestErr = fmt.Errorf("内置词典清单损坏: %w", err)
			return
		}
		manifestVal = mf.Packs
	})
	return manifestVal, manifestErr
}

// ExtPack 按 ID 找扩展包，找不到返回 false。
func ExtPack(id string) (Pack, bool) {
	packs, err := ExtPacks()
	if err != nil {
		return Pack{}, false
	}
	for _, p := range packs {
		if p.ID == id {
			return p, true
		}
	}
	return Pack{}, false
}

// CoreCompressedSize 返回内嵌数据的压缩体积（字节），用于诊断与日志。
func CoreCompressedSize() int { return len(coreGz) }

// ExtractCore 把内嵌词库解压到 dst。
//
// 先写 .tmp 再 rename：解压中途被杀（用户关窗、断电）时不会留下
// 一个半截的 .db——那会让下一次启动读到损坏文件，比缺失更难查。
func ExtractCore(dst string) error {
	if len(coreGz) == 0 {
		return fmt.Errorf("内置词库为空（构建时未生成 dictdata/en-zh.core.v1.db.gz）")
	}
	zr, err := gzip.NewReader(bytes.NewReader(coreGz))
	if err != nil {
		return fmt.Errorf("内置词库损坏: %w", err)
	}
	defer zr.Close() //nolint:errcheck

	tmp := dst + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return fmt.Errorf("创建 %s: %w", tmp, err)
	}
	if _, err := io.Copy(f, zr); err != nil {
		f.Close()      //nolint:errcheck
		os.Remove(tmp) //nolint:errcheck
		return fmt.Errorf("解压内置词库: %w", err)
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp) //nolint:errcheck
		return err
	}
	if err := os.Rename(tmp, dst); err != nil {
		os.Remove(tmp) //nolint:errcheck
		return fmt.Errorf("落盘内置词库: %w", err)
	}
	return nil
}
