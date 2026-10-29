# Legado 书籍格式在 Go 生态的实现对照 · 调研

> 调研时间：2026-10-29
> 目的：盘点 Legado 原生支持的书籍格式，逐项核对 Go 生态是否有对等实现，评估移植成本

---

## 一、结论速览

**好消息远多于坏消息。** Legado 在书籍格式上大量自研（因为 Android/Java 生态当时没有好选择），而这些恰恰是 Go 生态已经解决的部分：

| 结论 | 内容 |
|---|---|
| ✅ **可直接用现成库，省掉大几千行移植** | EPUB（`raitucarp/epub` 等）、RAR/7Z（纯 Go，**比 legado 的 JNI native so 更好**）、编码检测（`saintfish/chardet`，**省掉自研 icu4j 3088 行**）、简繁转换（`longbridge/opencc`，纯 Go 无 cgo） |
| ⚠️ **有实现但不成熟，需评估或自研** | MOBI/AZW3（含 HUFF-CDIC）、UMD |
| 🔧 **桌面端可绕过，甚至反超** | PDF：安卓端靠 `PdfRenderer` 渲染成 Bitmap（纯图片、无文本层、无真实书签）；桌面 Web 模式可用 WebView 内置 PDF 能力或 pdf.js，**能出文本层与真实书签** |
| 🔥 **发现一个具体硬伤** | **Java 正则的环视（lookahead/lookbehind）在 Go 的 RE2 中不支持**，而内置 TXT 目录规则里 `(?!` 出现 33 次、`(?<=` 12 次、`(?=` 2 次。`legado-go/pkg/rule/regex.go` 当前未处理，**会静默失效** |

**最划算的三笔账**：编码检测省 3088 行、EPUB 省 12627 行、RAR/7Z 从 JNI 换成纯 Go。

---

## 二、Legado 侧：格式支持全清单（实测）

### 2.1 导入（`model/localBook/`）

| 格式 | 处理类 | 行数 | 依赖 | 能力 |
|---|---|---|---|---|
| **TXT** | `TextFile.kt` | 478 | 自研 `lib/icu4j` **3088 行** + jsoup | 目录规则、章节切分、编码检测、字数统计；无图片/元数据 |
| **EPUB** | `EpubFile.kt` | 438 | 自研 epublib **12627 行 / 68 文件** | TOC(NCX+NAV)、正文、图片资源、元数据、封面 |
| **MOBI** | `MobiFile.kt` | 318 | 自研 `lib/mobi` **1633 行 / 34 文件** | KF6 + KF8 双路径；**支持 HUFF-CDIC**（133 行）+ LZ77/PalmDOC（49 行）+ Plain |
| **PDF** | `PdfFile.kt` | 229 | Android `PdfRenderer` | **纯图片形式**：每页渲染成 Bitmap，正文是 `<img>` 串；TOC 按每 10 页合成"分段_N"；无文本层、无真实书签 |
| **UMD** | `UmdFile.kt` | 122 | 自研 `me.ag2s.umdlib` **1158 行 / 9 文件** | 文本型(0x01) + 图片型(0x02)；块类型 1-15 及 129/130/131/132/135/240/241；正文 zlib inflate |

### 2.2 导出

`ExportBookService.kt`（877 行）→ **EPUB**（走自研 epublib 的 `EpubWriter` 206 行 + `PackageDocumentWriter` 246 行）/ **TXT** / **MD**（后两者是纯文本流式写，很简单）。

### 2.3 归档与周边

| 能力 | 实现 | 说明 |
|---|---|---|
| ZIP / GZIP | `ZipUtils.kt` 409 行 | JDK `java.util.zip`，只写不读归档遍历 |
| RAR / 7Z / ZIP | `LibArchiveUtils.kt` 371 行 + `ArchiveUtils.kt` 109 行 | **经 JNI 接入**，产物含 `libarchive-jni.so`；正则 `.*\.(zip\|rar\|7z)$`，不支持 tar |
| 编码检测 | `EncodingDetect.kt` + 自研 `lib/icu4j` **3088 行** | 采样前 8000 字节 → ICU `CharsetDetector`；HTML 先走 meta charset |
| 简繁转换 | `quick-chinese-transfer:quick-transfer-core` 0.2.16 | — |
| HTML 清洗 | jsoup 1.16.2 + `HtmlFormatter.kt` | — |
| TXT 目录规则 | `TxtTocRule` 表 + `defaultData/txtTocRule.json` | 所有启用规则匹配前 512KB，取命中最多且间隔 >1000 字符者胜出 |

---

## 三、Go 生态逐项对照

### ✅ 3.1 可直接用（省下大量移植）

| 能力 | Go 实现 | 说明 | 省的代价 |
|---|---|---|---|
| **EPUB 读+写+编** | **`github.com/raitucarp/epub`** | Reader/Writer/Editor 三入口，实现 EPUB 3.3（OCF、package document、NAV、legacy NCX），支持 Markdown 转换、封面、字体混淆、RTL。Go 1.25+ | **替代自研 epublib 12627 行** |
| | `github.com/billdaws/epub` | 纯 Go **零依赖**，读/写/校验三合一，线程安全，支持 EPUB 2/3 | 备选（更轻） |
| | `github.com/bmaupin/go-epub` | 老牌，主要面向生成 | 备选 |
| **编码检测** | **`github.com/saintfish/chardet`** | **ICU 字符集检测算法的 Go 移植**，40+ 识别器，覆盖 UTF 家族、ISO-8859、GB18030、Big5、Shift-JIS、EUC-KR、ISO-2022；有 `NewTextDetector` / `NewHtmlDetector` 两个入口，正好对应 legado 的两种采样路径 | **省掉自研 icu4j 3088 行移植** |
| | `github.com/go-playground/universal-detector` | 同样基于 ICU 算法 | 备选 |
| | `golang.org/x/text/encoding` + `htmlindex` | 读 meta charset 声明 | 配合用 |
| **简繁转换** | **`github.com/longbridge/opencc`** | **纯 Go**，用 `go:embed` 把 OpenCC 官方词典打进二进制，无 cgo。支持 s2t/t2s/s2tw/s2hk/tw2sp/s2twp 等 16 种配置 | 替代 quick-chinese-transfer，**且无 cgo** |
| **ZIP** | 标准库 `archive/zip` | — | 免费 |
| **RAR** | `github.com/nwaples/rardecode` | 纯 Go 读，支持密码 | **替代 JNI** |
| **7Z** | `github.com/bodgit/sevenzip` | 纯 Go 读，支持密码 | **替代 JNI** |
| **统一归档封装** | `golift.io/xtractr` / `github.com/mholt/archives` | 统一 API 覆盖 zip/rar/7z/tar/gz/bz2/xz/zst/ISO；**无 cgo**；RAR 与 7z 为只读（基于上面两个纯 Go 库） | 一个依赖搞定全部 |
| **HTML 解析** | `github.com/PuerkitoBio/goquery` | legado-go 已在用 | 已解决 |
| **Markdown** | `github.com/yuin/goldmark` / `gomarkdown` | 导出 MD 用 | 免费 |

> **值得强调**：legado 在 Android 上为了让 RAR/7Z 能跑，不得不打包 `libarchive-jni.so`（JNI native）。Go 侧 `rardecode` + `sevenzip` 都是**纯 Go**，不仅省掉 native 依赖，还直接满足 `CGO_ENABLED=0`。

### ⚠️ 3.2 有实现但不成熟，需评估或自研

| 格式 | Go 实现 | 现状 | 建议 |
|---|---|---|---|
| **MOBI / AZW3** | `github.com/shishobooks/shisho/pkg/mobi` | 手写实现，支持 MOBI6 / KF8 / combo，有 `ReadTOC`、`Rewrite`、EXTH 元数据；明确声明"hand-written 以避免 GPL" | **首选评估对象**，但需实测 HUFF-CDIC 支持情况 |
| | `github.com/jparkerweb/azw3-to-pdf/internal/ebook` | 源码含 `huffcdic.go`、`palmdoc.go`、`palmdb.go`、`exth.go`，**HUFF-CDIC 有实现**；但位于 `internal/`，**不可直接外部引用** | 需 fork 或 vendor；可作移植参考 |
| | `github.com/766b/mobi` | 81 star，**偏 Writer**；README 自述 "Reader does not give any useful information"；2020 年停更 | 不适合做 Reader |
| | `github.com/ignisVeneficus/ebook` | 仅元数据 + 封面 | 不够 |
| **结论** | — | — | legado 自研 MOBI 共 1633 行，其中 `HuffcdicDecompressor` 仅 133 行、`Lz77Decompressor` 49 行。**移植成本可控（约 1.6k 行），推荐直接移植而非依赖外部库** |
| **UMD** | `github.com/linpinger/foxbook-golang/ebook`（UMDReader）、`github.com/linpinger/umd2txt` | **确实存在 Go 实现**（推翻"Go 生态空白"的预判），但：21 star、8 commits、2021 年停更、单人项目；umd2txt 是命令行工具而非库 | 可先跑通验证正确性；若不放心则自研——legado 侧仅 1158 行，且正文就是 zlib inflate，Go 标准库 `compress/zlib` 直接可用 |

### 🔧 3.3 PDF：桌面端可绕过，甚至反超安卓端

安卓端 `PdfFile.kt`（229 行）的能力边界很窄：靠 `android.graphics.pdf.PdfRenderer` 把每页渲染成 Bitmap，**无文本层、无真实书签**，TOC 是每 10 页硬切一段。

桌面端走 Web 模式时有更好的选择：

| 方案 | 说明 |
|---|---|
| **WebView 内置 PDF 能力** | WebView2（Windows）、WKWebView（macOS）、WebKitGTK（Linux）都可承载 PDF 查看；Windows 侧 WebView2 基于 Chromium，内置 PDF 阅读器 |
| **pdf.js** | 直接作为前端资源打包进去，纯前端渲染，**支持文本层、搜索、真实书签（outline）** |
| Go 侧纯 Go 渲染 | `rsc.io/pdf`、`ledongthuc/pdf`（仅文本提取）；`gen2brain/go-fitz`（cgo + MuPDF，功能强但破坏无 cgo） |

**结论**：桌面端 PDF 不需要 Go 侧渲染库，交给 pdf.js 反而能拿到比安卓端更完整的能力（文本层 + 真实书签 + 搜索）。

---

## 四、🔥 关键硬伤：Java 正则的环视在 Go 中不支持

这是本次调研最值得立刻处理的发现。

### 4.1 事实

Legado 内置的 TXT 目录规则（`app/src/main/assets/defaultData/txtTocRule.json`）大量使用 Java 正则的**环视**特性：

| 特性 | 出现次数 | Go RE2 支持 |
|---|---|---|
| `(?!` 负向前瞻 | **33** | ❌ 不支持 |
| `(?<=` 正向后顾 | **12** | ❌ 不支持 |
| `(?=` 正向前瞻 | **2** | ❌ 不支持 |

示例（内置规则"目录(去空白)"）：
```
(?<=[　\s])(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和]))).{0,30}$
```

### 4.2 当前代码的行为

`legado-go/pkg/rule/regex.go` 的 `compileReg` 只做了最小兼容：

```go
var javaToGoReplacer = strings.NewReplacer(`\A`, `^`, `\Z`, `$`, `\z`, `$`, `\d`, `[0-9]`)

func compileReg(pattern string) (*regexp.Regexp, error) {
	p := javaToGoReplacer.Replace(pattern)
	p = unescapeCharClass(p)
	re, err := regexp.Compile(p)
	if err != nil {
		return regexp.Compile(pattern) // 回退：原样编译
	}
	return re, nil
}
```

**完全没有处理环视。** 遇到 `(?<=` 或 `(?!`，`regexp.Compile` 报 `invalid or unsupported Perl syntax`，回退原样编译同样失败，返回 error → `RegexGetElement` / `RegexGetElements` **静默返回 nil**。

**影响面**：不只 TXT 目录规则。书源规则里的 `replaceRegex`、正文净化规则、以及用户自定义书源中写的环视正则，都会命中同一问题。

### 4.3 解决方案

**`github.com/dlclark/regexp2`** —— .NET 风格正则引擎，支持环视、反向引用、条件表达式等 RE2 不具备的特性。

有利条件：**`legado-go/go.sum` 中已有 `github.com/dlclark/regexp2/v2 v2.8.1`**（作为 goja 的间接依赖），引入成本为零，不新增外部依赖。

建议做法：
1. `compileReg` 改为：先尝试标准 `regexp`（快），失败则降级 `regexp2`；或按"是否含环视/反向引用"预判断路。
2. 注意 `regexp2` 性能低于 RE2，建议对命中环视的规则做编译结果缓存。
3. 补一组针对内置 `txtTocRule.json` 的回归用例——该文件就是最好的测试语料。

---

## 五、移植成本汇总

| 能力 | legado 自研规模 | Go 侧方案 | 实际需写 |
|---|---|---|---|
| EPUB 读写 | 12,627 行 / 68 文件 | `raitucarp/epub` 或 `billdaws/epub` | **≈ 0**（仅适配层） |
| 编码检测 | 3,088 行（icu4j） | `saintfish/chardet` | **≈ 0** |
| ZIP | 409 行 | 标准库 | **≈ 0** |
| RAR / 7Z | 371 行 + **JNI so** | `rardecode` + `sevenzip` | **≈ 0，且去掉 native** |
| 简繁转换 | 第三方库 | `longbridge/opencc` | **≈ 0，且纯 Go** |
| HTML 清洗 | jsoup | goquery（已在用） | **≈ 0** |
| TXT 解析 | 478 行 | 标准库 + 目录规则引擎 | ~500 行 |
| MOBI | 1,633 行 / 34 文件 | 无成熟库，**建议移植** | **~1,600 行** |
| UMD | 1,158 行 / 9 文件 | `linpinger` 有但老旧 | **~1,200 行**（或验证后采用） |
| PDF | 229 行 + 系统 API | **pdf.js / WebView**，无需 Go 库 | **≈ 0**（前端方案） |
| 正则兼容 | — | `dlclark/regexp2`（已在依赖树） | 改造 `compileReg` + 缓存 |
| 导出 EPUB | epublib 写路径 | `raitucarp/epub` Writer | **≈ 0** |
| 导出 TXT / MD | 简单流式写 | 标准库 + goldmark | **≈ 0** |

**合计真正需要自研的：约 3,300 行**（MOBI 1,600 + UMD 1,200 + TXT 500），相比 legado 侧 2 万行量级的自研，Go 生态承接了绝大部分。

---

## 六、建议

1. **优先级最高：先修正则环视。** 这是唯一一个"不修就静默出错"的问题，且修复成本极低（regexp2 已在依赖树里）。用内置 `txtTocRule.json` 做回归基线。
2. **EPUB 直接用 `raitucarp/epub`**，不要再移植 epublib。它同时覆盖读（导入）和写（导出），一份依赖解决两侧。
3. **归档层换纯 Go**：把 libarchive JNI 换成 `mholt/archives` 或 `golift.io/xtractr`，顺带保住 `CGO_ENABLED=0`。
4. **MOBI 与 UMD 自己移植**：外部库要么不成熟、要么在 `internal/`、要么停更。但规模只有 1.6k + 1.2k 行，且关键算法很小（HUFF-CDIC 133 行、UMD 正文就是 zlib）。UMD 可先跑 `linpinger` 的实现做交叉验证。
5. **PDF 交给前端**：桌面 Web 模式用 pdf.js，能力反超安卓端，Go 侧零成本。
6. **编码检测与简繁转换直接换库**，省掉 3088 行移植。
