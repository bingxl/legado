# EPUB + TXT + 漫画图片：Go 生态承接度调研

> 承接《书籍格式Go生态对照调研.md》《自研部分C++库对照调研.md》。
> 本轮变更：**支持格式缩小为 EPUB、TXT、漫画图片**，砍掉 MOBI、UMD、PDF。

---

## 一、结论先行

**砍掉 MOBI / UMD / PDF 之后，Go 生态在这三块上几乎全绿，而且全部纯 Go、无 cgo。**

三个直接结果：

1. **上一轮纠结的全部消失** —— MOBI 的 libmobi（LGPL + cgo）与 shisho fork、UMD 的自研 1,158 行，统统不用管了。
2. **自研量从 ~3,300 行降到 ~500 行**（只剩 TXT 目录规则），**降幅约 85%**。
3. **`CGO_ENABLED=0` 和全平台交叉编译完整保住**，MyGo 重新回到可选范围。

更关键的是漫画侧有一个架构级洞察：**桌面端走 WebView 时，图片解码根本不需要 Go 做**（详见第四节），这直接绕开了"Go 生态 WebP/AVIF 断层"这个在其他场景下会致命的问题。

---

## 二、EPUB —— 库的能力超出上一轮评估

### 2.1 库：`github.com/raitucarp/epub`

| 项 | 内容 |
|---|---|
| **许可** | **MIT** |
| **规范** | 实现 **EPUB 3.3**：OCF、package document、NAV 导航文档，以及 EPUB 2 的 legacy NCX |
| **验证** | 通过 **W3C EPUB conformance test suite**，并用 Standard Ebooks 的真实高质量书籍验证 |
| **入口** | **Reader** / **Writer** / **Editor**（`reader.Edit()` 原地修改 + 与 Reader 双向切换，链式 API） |
| **要求** | Go 1.25+（`legado-go` 是 1.27.0，满足） |
| **活跃度** | 非常活跃。2026-09-26 仍在提交（Editor、多 rendition、metadata.yml）；2026-08 把测试覆盖率提到 90%+ |
| **安全** | **2026-07-06 修过 Zip Slip 漏洞**（EPUB reader 路径遍历）— 这一点很重要，EPUB 是 zip，野文件必须防 |

### 2.2 对 legado 有用的具体能力

| legado 需求 | epub 库对应 API |
|---|---|
| 元数据（书名/作者/语言/简介/标识符） | `Title()` `Author()` `Language()` `Description()` `UID()` `Metadata()` |
| **TOC** | `TableOfContents()` → NAV 或 NCX，`Landmarks()`、`PageList()` |
| **正文（XHTML）** | `ReadContentHTMLById(id)` / `ByHref` → **`*html.Node`** |
| 封面与图片资源 | `Cover()`、`Images()`、`ImageResources()`、`ReadImageBytesById` |
| 资源按 spine 顺序 | `ListContentDocumentIds()`、`Resources()`、`SelectResourceByHref` |
| **导出 EPUB** | `Writer`（`New` / `AddContent` / `TableOfContents` / `Write` / `WriteBytes`），**可直接替代 legado 自研 epublib 的 EpubWriter(206) + PackageDocumentWriter(246)** |

### 2.3 一个绝佳的配合点

`ReadContentHTMLById` 返回的是 **`*html.Node`**，而 `legado-go` 已经在用 **goquery**（v1.13.0，依赖里就有）。两者可以直接衔接：

```go
node := book.ReadContentHTMLById(id)   // *html.Node
doc := goquery.NewDocumentFromNode(node)  // 无缝接进现有规则引擎
```

意味着 EPUB 正文可以直接喂给已有的 `pkg/rule` 做清洗、净化、替换，**不需要另写一套 HTML 处理**。

另有 `ReadContentMarkdownById` 可直出 Markdown —— 如果桌面端想做"导出 MD"（legado 现有导出格式之一），这是白送的。

### 2.4 仍需自研的部分（很小）

| 项 | 说明 |
|---|---|
| 章节切分与分页 | EPUB 正文交给前端 WebView 排版，Go 侧只需按 spine 提供 HTML 序列 |
| 字体/排版设置 | 前端 CSS |
| 字体混淆（font obfuscation） | 库已支持 |
| **Zip Slip 注意** | 库已修，但如果自己直接用 `archive/zip` 解析要自行防 |

---

## 三、TXT —— 只剩目录规则要自己写

| 子项 | 方案 | 状态 |
|---|---|---|
| **编码检测** | `github.com/saintsfish/chardet` | ✅ ICU 算法 Go 移植，40+ 识别器；`NewTextDetector` / `NewHtmlDetector` 双入口，正好对应 legado 两种采样路径 |
| **编码转码**（GBK/GB18030/Big5 → UTF-8） | `golang.org/x/text/encoding/simplifiedchinese` + `traditionalchinese` | ✅ **`golang.org/x/text` v0.43.0 已在 `legado-go/go.mod` 直接依赖里，零新增依赖** |
| **章节切分** | 自研 | ~300 行（按目录规则正则匹配切段） |
| **TXT 目录规则（TxtTocRule）** | 自研 | ~200 行 |
| **字数统计** | 自研 | 几十行 |
| 导出 TXT / MD | 纯文本流式写 | 极简单 |

**自研合计约 500 行**，且难度低（不涉及二进制格式）。

### 🔥 那个硬伤依然存在，优先级最高

上一轮发现的正则环视问题**与本轮范围无关、不能靠砍格式绕开**：

- 内置 `app/src/main/assets/defaultData/txtTocRule.json` 使用 Java 正则环视：`(?!` **33 次**、`(?<=` **12 次**、`(?=` **2 次**
- Go 标准库 `regexp`（RE2）**完全不支持** lookahead/lookbehind
- `legado-go/pkg/rule/regex.go` 的 `compileReg` 只做了 `\A`/`\Z`/`\d` 替换，**未处理环视** → 编译失败 → `RegexGetElement` **静默返回 nil，不报错**
- 影响面**不止 TXT**：书源 `replaceRegex`、净化规则、用户自定义书源都会命中

解法：`github.com/dlclark/regexp2`（支持环视与反向引用）**已在 `go.sum` 里**（goja 间接依赖 v2.8.1）。建议 `compileReg` 改双路：先 RE2（快），失败降级 regexp2，缓存编译结果，用内置 `txtTocRule.json` 做回归基线。

> 缩小格式范围没有让这个问题消失——**TXT 仍在范围内，而它恰恰是受影响最重的**。

---

## 四、漫画 —— 关键洞察：Go 侧几乎不需要解码图片

### 4.1 先看 legado 现在怎么做的

实测 `app/src/main/java/io/legado/app/`：

| 事实 | 位置 |
|---|---|
| `localBook/` 下**没有任何图片/漫画解析器** —— 只有 TextFile / EpubFile / MobiFile / PdfFile / UmdFile | `model/localBook/` |
| 本地导入仅支持 **txt / epub / pdf / umd / 压缩文件** | `LocalBook.kt:66, 504` |
| 漫画是独立模块，**2,675 行 / 21 文件** | `ui/book/manga/`（ReadMangaActivity、ReadMangaViewModel、MangaAdapter、MangaLayoutManager、WebtoonFrame、MangaColorFilterConfig、EpaperTransformation、GrayscaleTransformation、ScrollTimer…） |
| 图片**来自书源抓取的网络 URL**，带 BookSource 的 header 下载后缓存 | `model/ImageProvider.kt`（212 行）、`model/ReadManga.kt`（639 行）、`help/glide/ImageLoader.kt`（108 行） |

**结论：legado 的漫画是"在线书源 + 图片 URL 列表 + Glide 加载 + RecyclerView 渲染"，不是本地 CBZ/CBR 文件解析。**

### 4.2 这一事实把 Go 侧的工作变得极轻

桌面端走 WebView 时，前端一个 `<img>` 标签就接管了一切：

| 能力 | 安卓端怎么做的 | 桌面端怎么做 |
|---|---|---|
| 图片解码（JPEG/PNG/WebP/AVIF/GIF/动画） | Glide + 系统解码器 | **WebView `<img>`，Go 侧零代码** |
| 内存/磁盘缓存、降采样 | Glide | **浏览器 HTTP 缓存 + 前端懒加载** |
| 条漫连续滚动（WebtoonFrame） | 自定义 LayoutManager | CSS + JS 虚拟滚动 |
| 双页对开 | 自定义 LayoutManager | CSS flex |
| 灰度 / 色彩滤镜 / 水墨屏模式 | EpaperTransformation、GrayscaleTransformation、MangaColorFilter | **CSS `filter`** |
| 自动滚动（ScrollTimer） | 定时器 + RecyclerView | JS |
| 长按手势（GestureDetectorWithLongTap） | 自定义手势 | JS |

**这直接绕开了 Go 生态最大的坑**：`golang.org/x/image/webp` 只支持纯 Go **解码**、不支持动画与部分特性；**AVIF / HEIC 在纯 Go 里基本没有成熟实现**（`chai2010/webp`、`kolesa-team/go-webp` 都要 cgo 绑 libwebp；`h2non/bimg` 要 libvips）。

**但只要不自己解码，这个问题就不存在。** WebView 支持什么格式，你的漫画阅读器就支持什么格式——比 Glide 覆盖面还广。

### 4.3 Go 侧真正要做的只有一件事：带书源头的图片代理

漫画图片常有防盗链（校验 Referer / UA）。`<img src="外链">` 直接打过去会被拒。所以 Go 侧需要一个代理：

```
书源规则抓到图片 URL
  → Go 侧带 BookSource 的 header（Referer/UA/Cookie）下载
  → 落本地缓存目录 + LRU
  → 通过 Wails 的 asset handler（或本地 HTTP 服务）把字节流喂给 <img>
```

这正好复用 `legado-go` 已有的 `pkg/net`（Cookie/UA/代理）与 `pkg/download`。**工作量约 200-300 行**，而且是在已有模块上扩展。

> Wails v3 有 asset server（桌面端 WebViewAssetLoader / assets handler）可直接注册 handler 返回字节；MyGo 官方插件也提供无 CORS 的 Fetch。

### 4.4 如果要新增"本地 CBZ/CBR 导入"（安卓端本来没有）

这属于**新功能**而非移植。若要做，Go 生态有两个现成选择：

| 库 | 说明 |
|---|---|
| **`github.com/mholt/archives`** | **MIT，335 star，纯 Go 无 cgo**。zip / tar / **rar（只读）** / **7z（只读）**；统一的 `Identify` + `Extract` API；可作 `io/fs` 虚拟文件系统（`ArchiveFS`、`DeepFS`）；支持**带密码的 7z / RAR**；**静态二进制 + 跨平台** |
| **`github.com/ophymx/longbox`** | **CBZ 专用**，零第三方依赖（只用 `archive/zip` + `encoding/xml`）。带 **ComicInfo.xml**（Anansi schema，兼容 Komga / Kavita / KOReader）；**自然排序**（`2.jpg` 排在 `10.jpg` 前）；按 zip central directory **随机访问第 N 页**，不解包；容忍野文件（缺 ComicInfo、`.DS_Store`、`__MACOSX/`、子目录嵌套） |

`mholt/archives` 的已知限制：**rar/7z 只读**（不能写），**不支持 seek**（对 HTTP range 有影响，但本地漫画阅读是顺序读 + 随机取页，影响不大）。

**建议**：zip/CBZ 用标准库 `archive/zip` 或 longbox；CBR/7z 用 `mholt/archives`。如果只做在线漫画（对齐安卓端现有能力），这两个库**都不需要**。

### 4.5 只有一种情况需要 Go 侧解码图片

**生成书架封面缩略图**。此时用：

- **`github.com/disintegration/imaging`** —— 纯 Go、无 cgo。多种重采样滤波器（Lanczos / CatmullRom / MitchellNetravali…）、**多核并行**、`AutoOrientation(true)` 自动修正 EXIF 方向、模糊/锐化/灰度/对比度/饱和度调整、裁剪与叠加。统一返回 `*image.NRGBA`，链式调用不需要手动转类型（这一点很重要——`image.Decode` 出来可能是 `*image.YCbCr` 或 `*image.NRGBA`，直接丢给绘图函数会出问题）。
- WebP 封面：`golang.org/x/image/webp`（纯 Go，仅解码）。封面只有一张，慢一点无所谓。

---

## 五、工作量对比

| 项 | 原方案（全格式） | 本轮（EPUB+TXT+漫画） | 变化 |
|---|---|---|---|
| EPUB | 替代自研 epublib 12,627 行 | `raitucarp/epub` | 不变，仍白省 12.6k 行 |
| **MOBI** | 自研 1,633 行 或 fork shisho | **砍掉** | **−1,633 行** |
| **UMD** | 自研 1,158 行 或 foxbook | **砍掉** | **−1,158 行** |
| TXT | 自研 ~500 行 | 自研 ~500 行 | 不变 |
| PDF | 桌面端 Go 侧 0 行 | **砍掉** | 0 |
| 漫画 | — | **Go 侧 ~200-300 行**（图片代理 + 缓存），渲染全给前端 | 新增但很轻 |
| **自研合计** | **~3,300 行** | **~700-800 行** | **↓ 约 77%** |

同时，本轮范围下**没有任何一个库需要 cgo**：

| 库 | 许可 | cgo |
|---|---|---|
| `raitucarp/epub` | MIT | 否 |
| `saintsfish/chardet` | — | 否 |
| `golang.org/x/text`（已在依赖里） | BSD | 否 |
| `mholt/archives` | MIT | 否 |
| `ophymx/longbox` | MIT | 否 |
| `disintegration/imaging` | MIT | 否 |
| `golang.org/x/image/webp` | BSD | 否 |

---

## 六、变化带来的连带影响

1. **MyGo 重新成为可选方案。** 上一轮"推荐 Wails v3"的核心理由之一是"Linux 必须 cgo，而 MyGo 无 cgo"——现在因为**完全不需要 cgo**，MyGo 的"零 cgo + 原生 UI"优势重新成立，两条路线都能走。框架选择可以重新回到"成熟度 vs 原生手感"的原点，而不再被 cgo 绑架。
2. **上一轮那份 MOBI 调研可以归档。** libmobi / shisho / wazero 那套分析只在"要支持 MOBI"时才有意义。
3. **PDF 砍掉不影响体验。** 桌面端原本就是靠 pdf.js，砍掉只是不提供 PDF 导入，前端能力没损失。

---

## 七、建议

**立即做（按优先级）**

1. **修正则环视硬伤** —— 唯一"不修就静默出错、修起来极便宜"的问题，且不因砍格式而消失。用 `txtTocRule.json` 做回归基线。
2. **EPUB 打通** —— `epub.OpenReader` → `ReadContentHTMLById` → `goquery.NewDocumentFromNode` → 现有 `pkg/rule` 清洗 → 前端渲染。这条链路能跑通，EPUB 就算落地。
3. **TXT 打通** —— chardet 检测 → `x/text` 转 UTF-8 → 目录规则切章（注意环视降级）。
4. **漫画图片代理** —— 复用 `pkg/net` + `pkg/download`，加一个带书源头的下载缓存与 asset handler。

**可以明确不动**

- MOBI / UMD / PDF 的解析代码
- 任何 cgo 依赖
- Go 侧的图像解码器（除封面缩略图外）

---

## 附：接入 TTS 时，PDF 是否还需要 Go 侧处理

### 结论：不需要。而且 legado 安卓端本来就不能朗读 PDF。

### 证据：`PdfFile.getContent()` 返回的是图片标签，不是文本

`app/src/main/java/io/legado/app/model/localBook/PdfFile.kt:137`：

```kotlin
private fun getContent(chapter: BookChapter): String? =
    if (pdfRenderer == null) null
    else pdfRenderer?.let { renderer ->
        buildString {
            val start = chapter.index * PAGE_SIZE          // PAGE_SIZE = 10
            val end = ((chapter.index + 1) * PAGE_SIZE).coerceAtMost(renderer.pageCount)
            (start until end).forEach {
                append("<img src=").append('"').append(it).append('"').append(" >")
                .append('\n')
            }
        }
    }
```

**正文是 `<img src="0" >` `<img src="1" >` … 一串图片占位符，一个字都没有。** 底层是 Android `PdfRenderer` 把每页渲成 Bitmap，目录按每 10 页硬切。

所以：**PDF 在 legado 里从来就是"图片格式"而非"文本格式"**。TTS 拿到 `<img>` 标签无内容可读——安卓端 PDF 朗读本来就不可用。桌面端不做，不算功能缺失。

### 那 TTS 的文本从哪来？

从**已解析的正文**来，而不是各格式再提取一遍：

| 格式 | 正文来源 | TTS 可用性 |
|---|---|---|
| EPUB | `epub.ReadContentHTMLById` → 清洗 → 纯文本 | ✅ |
| TXT | 切章 + 目录规则 → 纯文本 | ✅ |
| 漫画 | 图片 | ❌ 无文本 |
| **PDF** | **`<img>` 标签** | **❌ 无文本（安卓端同样如此）** |

EPUB 与 TXT 共用同一套"HTML/文本 → 纯文本"管道，`legado-go/pkg` 已有 HTML 处理能力，增量很小。

### 如果一定要**新增** PDF 朗读（超越安卓端的能力）

顺序如下，**Go 侧仍应尽量避免自己解析**：

**① 首选：让前端做，Go 侧零代码**
桌面端走 WebView 时，pdf.js 的 `getTextContent()` 可直接取到文本层（带坐标、字体、方向）。CJK 支持是浏览器级的，**比任何 Go 库都好**。取到文本后交给 Go 侧 TTS 即可。

**② 备选：Go 侧直接解析（仅在必须读本地文件时）**

| 库 | 许可 | cgo | 判断 |
|---|---|---|---|
| **`klippa-app/go-pdfium`** | 绑定 MIT + PDFium Apache-2.0 | **可选** | ✅ **唯一推荐**。提供 `single_threaded`(cgo) / `multi_threaded`(cgo) / **`webassembly`(Wazero)** 三种实现，**接口完全一致**；WASM 版**无外部依赖、不需要 CGO**。有结构化文本 API（文本/角度/位置/字号/字体）。限制：wazero 仅 amd64/arm64 有编译器，其他架构走解释器会慢很多 |
| `ledongthuc/pdf` | BSD-3 | 否 | ⚠️ 纯 Go 轻量常用，但三个硬伤：**Form XObject 内文本丢失**、`%%EOF` 后附加内容打不开、**CID 中文字体在 CMap 缺失时乱码** —— 第三条对中文 PDF 朗读是致命的 |
| `gen2brain/go-fitz`（MuPDF） | **AGPL-3.0** | 是 | ❌ AGPL 与 GPLv3 组合后整体需按 AGPLv3 分发；需 cgo；不含 CJK 字体；且只有整页纯文本 API，无坐标级 |
| `pdfcpu` | Apache-2.0 | 否 | ❌ **没有文本提取功能**（网上说法是误传） |
| `rsc.io/pdf` | BSD-3 | 否 | ❌ 已归档，只有字符级 run，无行/块结构，阅读顺序需自己聚类 |

**③ 扫描版 PDF（无文本层）→ 需要 OCR**，这是另一个量级的问题（tesseract，Go 生态无成熟纯 Go 实现）。安卓端同样不支持，建议直接砍。

### 顺带：桌面端 TTS 本身的路线选择

legado 现有 TTS 实现规模：`BaseReadAloudService.kt` **784 行**（朗读引擎核心：分段、进度、调度、通知）、`HttpReadAloudService.kt` **596 行**、`TTSReadAloudService.kt` **265 行**（Android `TextToSpeech`），另有 `help/TTS.kt`、`HttpTTS`/`HttpTTSDao` 配置实体与导入/编辑 UI。

桌面端建议：

| 路线 | 说明 |
|---|---|
| **HTTP TTS（推荐优先做）** | legado 已有完整实现（596 行）。本质是"POST 文本 → 取音频流 → 播放"，**纯 HTTP、跨平台、零 native 依赖**，桌面端可直接复用逻辑；播放交给 `<audio>` 或 Web Audio API |
| 系统 TTS（后置） | 三平台都要 native：macOS `NSSpeechSynthesizer`（ObjC）、Windows SAPI（COM）、Linux speech-dispatcher —— 会引入 cgo / 平台绑定，与"保住 `CGO_ENABLED=0`"冲突 |

**即：桌面端 TTS 先做 HTTP TTS，既复用存量，又不破坏纯 Go 构建。**
