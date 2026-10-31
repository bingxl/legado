# legado-go 书源处理核对报告

核对时间：2026-10-29
对照基准：`app/src/main/java/io/legado/app/model/webBook/*.kt`、`model/analyzeRule/*.kt`（Kotlin 原版）
核对对象：`legado-go/pkg/{webbook,rule,urlx,util,js,model,source}`
方法：逐函数对照 Kotlin 源码 + 写临时差分测试跑真实输入（测试已在核对后删除）

> **状态：22 条差异已全部处理**（21 条修复 + 1 条有意保留，见第 6 节修复记录）。
> 回归用例已入库，`go test ./...` 全绿。

---

## 0. 结论速览

| # | 级别 | 问题 | 位置 |
|---|------|------|------|
| 1 | **P0** | `@text` 未做 jsoup `text()` 的空白归一化，标题/章节名带换行缩进 | `util/html.go:92` `rule/jsoup.go:184` |
| 2 | **P0** | `[]` 多索引顺序被反转（`li[2,0]` 取到 `[0,2]`） | `rule/jsoup.go:524` `:560` |
| 3 | **P0** | `book.Type` 从不按书源类型赋值，且取值域与 legado 位域不一致 → 文件型书源 `downloadUrls` 分支永不执行 | `webbook/webbook.go:204` `:528` |
| 4 | **P0** | `ruleContent.title` 完全未实现 | `webbook/webbook.go:751` |
| 5 | **P1** | `ruleContent.webJs` / `sourceRegex` 未传给请求 | `webbook/webbook.go:267` |
| 6 | **P1** | 库层 `GetContent` 无 `nextChapterUrl` 形参，CLI `content`/`validate` 传空 → 下一章刹车失效 | `legado.go:172` `cmd/legado/bookcmd.go:125` |
| 7 | **P1** | `getString` 对 List 结果取首元素，legado 是 `toString()` | `rule/analyze_rule.go:571` |
| 8 | **P1** | `%%` 合并以「最长列表」为界，legado 以 `results[0]` 为界 | `rule/jsoup.go:581` `jsonpath.go:140` |
| 9 | **P1** | `##` 替换后不补行首缩进；替换作用在未 trim 的原文上 | `webbook/webbook.go:831` |
| 10 | **P1** | 属性选择器值不带引号且以数字/`/` 开头时静默失败 | `util/select.go:81` |
| 11 | **P1** | `AnalyzeUrl` 的 `type`（audio/image）未实现 | `urlx/analyze_url.go:216` |
| 12 | **P1** | 搜索结果去重键与 legado 不同（legado 只按 bookUrl） | `webbook/webbook.go:368` |
| 13 | **P1** | `java.get(url, headers)` 被后注册的同名方法覆盖 | `js/ext.go:456` `:496` |
| 14 | **P1** | `java.ajaxAll` 返回 `string[]`，legado 返回 `StrResponse[]` | `js/ext.go:415` |
| 15 | **P1** | JS 超时后 runtime 未 `ClearInterrupt` 就归还池 | `js/engine.go:150` |
| 16 | P2 | JSONPath `length()/min()/max()/avg()/sum()` 不支持（ojg） | `rule/jsonpath.go` |
| 17 | P2 | `formatJs` 的 `gInt` 每章重置（legado 在 bindings 里累加） | `webbook/webbook.go:636` |
| 18 | P2 | `java.reGetBook` / `java.refreshTocUrl` 未实现 | `js/ext.go` |
| 19 | P2 | `preUpdateJs` 失败时 legado 中断目录抓取，Go 忽略 | `webbook/webbook.go:217` |
| 20 | P2 | 单段无 `@text` 的规则（`li`）行为不同：Go 当选择器，legado 当属性名返回空 | `rule/jsoup.go:113` |
| 21 | P2 | `ExploreKind` 空地址分类被丢弃（legado 保留分组标题） | `model/source.go:447` |
| 22 | P2 | 搜索/发现时代 `isRedirect` 恒传 false | `webbook/webbook.go:116` |

已确认对齐的部分见第 4 节。`ruleContent.nextContentUrl` 的「多下一页并发」在这里已经修好（`maxContentPages`/`maxContentConcurrency`），**但第 6 条让刹车信号在 CLI 路径下仍然是空**。

---

## 1. P0 详述

### 1.1 `@text` 没有 jsoup 的空白归一化

**现象**（临时差分测试，输入 `<li> A1 </li><li>\n   B2\n</li>`）：

```
li@text  => []string{" A1 ", "\n   B2\n", "C3", "D4"}
```

legado 的 `getResultLast("text")` 调 `element.text()`，jsoup 的语义是**折叠所有空白为单个空格并 trim**，结果应为 `["A1","B2","C3","D4"]`。

**原因**：`util.NodeText` 只是递归拼接 `TextNode.Data`，不去空白、不 trim；`ownText` 同理。

**影响面**（比看起来大）：

- 章节名：`parseChapterPage` 里 `ch.Title = ar.GetString(nameRule)` 不做 trim → 书名号外的换行缩进全部进标题，写进 txt/epub 后每章标题都是 `\n 第一章\n`；
- 去重键 `c.Title+"\x00"+c.Url` 失真（同一章不同空白视为不同章）；
- `Book` 名字清洗 `FormatBookName` 只 `TrimSpace` 首尾，中间残留的换行/多空格仍在；
- JS 侧 `result.text()` / `element.text()`（`js/ext.go:109`）同样返回原始文本，书源 JS 里 `text().replace(/\s/g,'')` 类的写法会得到不同结果；
- `class.xxx`、`text.xxx` 前缀筛选（`byOwnText`）用未归一化文本做 `Contains`，多空格时会漏匹配。

**建议**：在 `util` 增加 `NodeTextNorm`（jsoup `text()`：`strings.Fields` 后单空格连接）与 `NodeOwnTextNorm`，仅在 `getResultLast` 的 `text`/`ownText`/`textNodes` 和 JS 的 `text()/ownText()` 使用；`data()` 保持原始（jsoup `data()` 本来就不过滤空白）。

### 1.2 `[]` 多索引顺序被反转

**现象**：

```
li[2,0]@text => []string{" A1 ", "C3"}     // 先 0 后 2
li[0,2]@text => []string{"C3", " A1 "}     // 先 2 后 0
```

legado 的结果应是书写顺序：`[2,0]` → 先 2 后 0。

**根因**：Kotlin 的 `findIndexSet` 是**从右往左**扫描、`indexes.add(...)` 逆序压栈，再在 `getElementsSingle` 里 `for (ix in lastIndexes downTo 0)` 反向遍历 → 净效果是书写顺序。
Go 的 `parseIndexItems` 用 `strings.SplitSeq` **从左往右**收集，末尾又做了一次 `reverseInts`（注释写「反转还原书写顺序」），而 `elementsSingle` 是正向遍历 → 两次反转叠加成了反序。

旧式 `.` 索引（`tag.div.0:10`）因为同样做了反转反而是对的，所以只错在 `[]` 分支。

**影响**：`%%` 合并、`getString` 取首条、以及 `[1,0]`/`[-1:0]` 这类「取段落首尾再拼」的规则全部错位。既有测试用例都只用了单索引 `[0]`，所以没暴露。

**修法**：删掉 `parseIndexItems` 末尾的 `reverseInts(items)`（或改为在 `elementsSingle` 反向遍历，二者取其一）。

### 1.3 `book.Type` 从不赋值 → 文件型书源走错分支

Kotlin 在 `WebBook.getBookInfoAwait` / `getChapterListAwait` 入口都做了：

```kotlin
book.removeAllBookType()
book.addType(bookSource.getBookType())
```

Go 的 `GetBookInfo` / `GetChapterList` / `GetContent` 都没有这一步，`book.Type` 只在 `SearchBook.ToBook()` 里继承。

**后果**：`analyzeBookInfoWithRule` 里 `if !book.IsWebFile()` 恒为真（`book.Type` 为 0）→

- 文件/下载型书源（`bookSourceType: 3`）永远走 `tocUrl` 分支，`downloadUrls` 一条也解析不到；
- CLI 的 `legado info -book <url>` / `toc` / `content` 直连路径（`cmd/legado/bookcmd.go:231 newBook` 没设 Type）必然踩到；
- 只有「先 search 再 download」的路径因为经过 `ToBook()` 才侥幸正确。

**修法**：`GetBookInfo`/`GetChapterList`/`GetContent` 入口各加一行 `book.Type = src.GetBookType()`；`newBook` 里也补一次。

**附带问题（同一条根因，但更隐蔽）：`Type` 的取值域和 legado 不同**

legado 的 `Book.type` 是**位域**，`getBookType()` 做的是映射：

```kotlin
BookSourceType.file  -> BookType.text or BookType.webFile   // 1 | 128 = 129
BookSourceType.image -> BookType.image                      // 64
BookSourceType.audio -> BookType.audio                      // 2
else                 -> BookType.text                       // 1
```

Go 的 `model.Book.Type` 直接存 `BookSourceType`（0/1/2/3）。于是：

- `IsWebFile()` 用 `Type == 3` 判定，只在「恰好被赋成 3」时成立，与 legado 的 `type and 128` 不是一回事；
- JS 侧 `book.type`（`js/ext.go:973`）对文本源返回 `0`（legado 是 `1`）、图片源返回 `2`（legado 是 `64`）—— 书源里写 `book.type === 64` / `book.type & 128` 的规则全部判错。

建议分两步走，避免一次改动扩散到 `download.go:48`（`src.GetBookType() == BookTypeImage`）等已依赖「源类型」语义的地方：

1. **最小修复**：`GetBookInfo`/`GetChapterList`/`GetContent` 入口补 `book.Type = src.GetBookType()`，`IsWebFile()` 维持 `Type == BookTypeFile`。这一步就能让下载站走对分支，风险最低。
2. **可选对齐**：在 `model` 加 `SourceTypeToBookType(t int) int`（0→1、1→2、2→64、3→129），只在**暴露给 JS 的 `book.type`** 和 `IsWebFile()`（`Type&128 != 0`）两处使用，内部逻辑继续用源类型。这样书源里 `book.type === 64` / `book.type & 128` 才和 App 一致。

### 1.4 `ruleContent.title` 未实现

`BookContent.kt:66-78` 会在抓正文前先跑 `contentRule.title`，取到值就**回写 `bookChapter.title` 并落库**（有些站目录页只有「第12章」，真实标题只在正文页）。

Go 的 `analyzeContent` 从 `webbook.go:751` 到结束完全没有引用 `contentRule.Title`（字段在 `model/source.go:83` 解析了但没人用）。→ 这类书源的全书章节名都会是目录页的残缺名。

**修法**：`analyzeContent` 开头（`SetChapter` 之后）加：

```go
if t := contentRule.Title; strings.TrimSpace(t) != "" {
    if v := ar.GetString(t); strings.TrimSpace(v) != "" { chapter.Title = v }
}
```

（没有 DB，无法落库，回写到 `chapter` 对象即可——`download` 拼文本时用的就是它。）

---

## 2. P1 详述

### 2.1 `webJs` / `sourceRegex` 未传（`webbook.go:267`）

```go
resp, err := au.GetStrResponse()   // 缺 jsStr/sourceRegex
```

Kotlin：`analyzeUrl.getStrResponseAwait(jsStr = contentRule.webJs, sourceRegex = contentRule.sourceRegex)`。
依赖后台 WebView 混排的书源（正文要 JS 渲染 / 正则从源码里抠）在 Go 里直接拿原始 HTML。
Go 的 `js.Hooks.WebView` 本身也只是打日志返回空（`analyze_url.go:629`），属于「已知不支持」而非漏做，但至少参数不该丢——一旦以后接 WebView 就不用再改调用点。

### 2.2 库层 `GetContent` 缺 `nextChapterUrl`

`legado.go:172` 的 `Engine.GetContent(key, book, chapter)` 没有第 4 参，内部固定传 `""`：

- `cmd/legado/bookcmd.go:125`（`content` 命令）→ 空
- `pkg/source/validate.go:410`（在线校验正文探测）→ 空

`download.go:95` 和 `debugcmd.go:311` 有传，所以只有这两条路径踩坑：`nextContentUrl` 规则误选中「下一章」链接时，会把下一章正文拼到本章尾部（原本 `webbook.go:775` 的刹车判据在空串下不生效），最后被 `maxContentPages=50` 兜住，表现为「正文末尾莫名多出一章」。

**修法**：`Engine.GetContent` 加 `nextChapterUrl string` 形参（或加 `GetContentWithNext`），CLI/validate 按目录下标 `i+1` 传入。

### 2.3 `getString` 对 List 结果的处理（`analyze_rule.go:571`）

```go
case []any:   str = JsToString(t[0])
case []string: str = t[0]
```

Kotlin 是 `result.toString()`，对 `ArrayList` 得到 `"[a, b]"`。所以 `@js:` 返回数组时（如 `result.map(...)`）两边取值不同：Go 取首元素（更符合直觉），legado 得到带方括号的串。**这条会导致「Go 里能跑、legado 里跑不通」的反向不兼容**，如果目标是 100% 复刻应改回 `fmt.Sprint(list)` 风格；如果目标是「更好用」，建议至少在文档里标注。

### 2.4 `%%` 合并长度（`jsoup.go:581`、`jsonpath.go:140`、`xpath.go`）

Kotlin 一律 `for (i in results[0].indices)`——**只按第 1 段长度**截断。Go 取 `maxLen`。当第 2 段比第 1 段长时会多出元素（实测 `li[0]@text %% li[0,1]@text` Go 出 3 条，legado 出 2 条）。

### 2.5 `##` 替换（`webbook.go:831`）

Kotlin：

```kotlin
contentStr = contentStr.split(LF).joinToString("\n") { it.trim() }   // 先按行 trim
contentStr = analyzeRule.getString(replaceRegex, contentStr)          // 再替换
contentStr = contentStr.split(LF).joinToString("\n") { "　　$it" }    // 最后统一加缩进
```

Go：缩进串 `sb` 只在**替换结果为空**时兜底使用；替换成功时既不 trim 也不补缩进。带 `replaceRegex` 的书源段落格式会和 App 里不一致（`^\s*`、`\n\s+` 类正则会因为原文未 trim 而匹配位置不同）。

### 2.6 属性选择器不带引号 + 值以数字/`/` 开头 → 静默失败（`util/select.go:81`）

实测：

```
a[href^="/1"]@text  => ["一"]      ✅
a[href^=/1]@text    => []          ❌ jsoup 能解析
a[title$=2]@text    => []          ❌ jsoup 能解析
a[title^=T]@text    => ["一","二"] ✅（字母开头可以）
```

cascadia 的 tokenizer 要求不带引号的值是标识符（不能以数字开头、不能含 `/`），jsoup 则一路吃到 `]` 或空白。这类写法在真实书源里不算罕见，而且**失败是静默的**（只走 `OnSelectorError`，非 debug 模式没有任何提示）。

**修法**：`selectNodes` 编译前做一遍预处理——把 `[attr<op>value]` 中未加引号的 value 补上双引号（跳过已是引号/纯标识符的情况）。

### 2.7 `AnalyzeUrl.type` 未实现（`analyze_url.go:216`）

Kotlin：`if (type != null) return StrResponse(url, HexUtil.encodeHexStr(getByteArrayAwait()))`——音频/图片源拿到的是 **hex 字符串**，书源 JS 再 `hexDecodeToByteArray` 处理。Go 的 `GetStrResponse` 完全忽略 `au.Type`，返回文本 body；`GetBytes` 也没接。漫画/音频源会拿到乱码或空。

### 2.8 搜索去重键（`webbook.go:368`）

legado：`SearchBook.equals` 只比 `bookUrl`（`SearchBook.kt:65`）。Go：`Name+Author+BookUrl`。同一 URL 不同书名时 legado 只留 1 条，Go 留 2 条。

### 2.9 `java.get` 重复注册（`js/ext.go:456` 与 `:496`）

先注册 `get(url, headers)`（HTTP GET），后注册 `get(key)`（取变量），后者覆盖前者。legado 两个重载共存：1 参走取变量、2 参走 HTTP。现在 `java.get(url, headers)` 会退化成「用 url 当变量名取变量」→ 恒返回空。

### 2.10 `java.ajaxAll` 返回结构（`js/ext.go:415`）

legado 返回 `Array<StrResponse>`，书源里常见 `java.ajaxAll(urls).map(it => it.body)`。Go 返回 `[]string`，`it.body` 是 `undefined` → 依赖它的书源静默拿到空数组内容。

### 2.11 JS 超时后 runtime 未清理（`js/engine.go:150`）

```go
t := time.AfterFunc(e.Timeout, func() { vm.Interrupt(errTimeout) })
...
p.Put(vm)   // 被中断过的 vm 直接回池
```

goja 的 `Interrupt` 状态会保留，回到池里的 vm 后续 `RunProgram` 直接返回中断错误 → 该线程池此后所有 JS 规则失效，且报错是「JS 执行超时」（误导）。修法：`defer` 里 `vm.ClearInterrupt()`，或中断过就丢弃（`vm = nil` 的错误分支已有，但只在 panic 时走到）。

---

## 3. P2 记录（影响小或属已知裁剪）

- **JSONPath 函数**：ojg 不支持 jayway 的 `length()/min()/max()/avg()/sum()`（实测 `$.data.list.length()` 返回空）。`$.a[?(@.id==2)]`、`[-1:]`、`[0,1]`、`=~ /re/`、`$..x` 均正常。
- **JSON 对象字符串化**：legado 用 Java `Map.toString()` → `{k=v}`；Go 输出 JSON `{"k":"v"}`。影响 `@json:` 直接取对象 + `{{}}` 插值。
- **`formatJs` 的 `gInt`**：`webbook.go:636` 每章重新注入 `gInt:0`，legado 在同一 bindings 上累加（`gInt++` 类规则结果不同）；`index`/`title` 是对的。
- **`preUpdateJs` 失败**：Kotlin `runPreUpdateJs(...).getOrThrow()` 会中断目录抓取；Go `_ = RunPreUpdateJs(...)` 忽略。属「更宽容」。
- **`java.reGetBook` / `java.refreshTocUrl`**：未实现，preUpdateJs 里调用会抛「对象无此成员」。这两个依赖搜索/详情回环，桌面端有能力做，值得补。
- **单段无取值关键字的规则**：`rule/jsoup.go:113 isSelectorRule` 让 `li`、`div.item` 这类规则自动补 `@text`；legado 会把它当属性名 → 返回空。这是 Go 有意的容错，但会掩盖书源作者的笔误。
- **`ExploreKind` 空地址项**：`model/source.go:447` 直接丢弃。legado 保留为「分组标题」（`url == ""`），桌面 UI 如果要做分类分组，需要把这些项保留下来。
- **`isRedirect`**：`webbook.go:116` 搜索路径恒传 `false`，`BookUrlPattern` 命中详情页时 `getInfoItem` 的 `isRedirect` 分支走不到（影响很小，因为 `au.Url` 与 `baseUrl` 通常一致）。
- **`getWordCount` / `simulatedTotalChapterNum` / `durChapterTitle` 替换规则**：未实现（依赖 App 配置和 DB，桌面端可接受）。
- **`java` 其它缺口**：`startBrowserAwait`、`getVerificationCode`、`queryTTF`、`getZipByteArrayContent`/`getRar*`/`get7z*`、`getTxtInFolder`、`downloadFile(content,url)` 两参版、`base64Decode(str,flags)`、`readTxtFile(path,charset)`。

---

## 4. 已核对并确认对齐的部分

| 模块 | 结论 |
|------|------|
| `searchBook` / `exploreBook` 主流程 | URL 解析、`loginCheckJs`、`bookUrlPattern` 详情页直连、列表空回落详情、`-`/`+` 反转、去重后反转 ✔ |
| `BookInfo` | `init` 规则、`canReName` 语义、空值不覆盖旧值、`tocUrl`/`tocHtml` 复用、`coverUrl` 按 redirectUrl 补全 ✔ |
| `ChapterList` | `-`/`+`、单链翻页、多链并发（顺序稳定）、`visited` 去重、卷名 `url=title+index`、`title` 空跳过、双重 reverse、`formatJs` ✔ |
| `Content` 分页 | `size==1` 串行、`size>1` 并发不递归、`下一页==下一章` 刹车、绝对 URL 去重、`maxContentPages` ✔（除了第 6 条的传参问题） |
| 规则切分 | `&&`/`\|\|`/`%%` 括号与引号平衡切分、`@get:`/`{{}}`/`$N`/`##` 拆分、`@put:` 提取、`@CSS:`/`@@`/`@XPath:`/`@Json:`/`$/`/`/` 模式识别、`isJSON` 联动 ✔ |
| JSoup | `children`/`class.`/`tag.`/`id.`/`text.` 前缀、`children` 默认、`!` 排除、区间/负索引/步长、`textNodes`/`html`（去 script/style）/`all`/属性去重、`&&`/`\|\|`/`%%`、`:gt/:lt/:eq/:first/:last/:even/:odd`（**位于选择器末尾时**）、`:contains`/`:has`/`:matches`/`:not` 经 cascadia ✔ |
| XPath | `text()`/`@attr`/并集/谓词/`contains()`、`</td>`→`<tr>`→`<table>` 补全 ✔（唯一存疑：legado 的 `AnalyzeByXPath.getString` 走 `TextUtils.join("\n", List<JXNode>)`，即 `JXNode.toString()`；Go 用 `nodeValue` 统一取文本。元素节点在 jxnode 里的 `toString()` 是否等价于 outerHtml 未验证，若有源靠这条取 HTML 需实测） |
| Regex | 多级 `&&` 收窄、分组取值、空分组兜 `""`（legado 会 NPE）✔ |
| URL 解析 | `@js:`/`<js>` + `@result`、`{{}}`、`<1,2,3>` 页码、`,{options}` 宽松解析（method/headers/body/charset/retry/js）、query/form 编码与 `escape`、charset（GBK 等）、data: URI、重定向识别 ✔ |
| 编码/格式化 | `HtmlFormatter.format`/`formatKeepImg`（含 `data-src`/`src`/`data-*` 取图优先级、`,{...}` URL 选项保留）、`UnescapeHtml4`、`RelaxJSONKeys` ✔ |
| 书源加载 | JSON 数组/单对象/多对象拼接/混杂文本、去重、文件名归属 ✔ |

---

## 5. 建议修复顺序

1. **先修 1.2（索引反序）、1.1（text 归一化）**——纯规则层，改动小、影响所有书源、有明确基准可写回归测试。
2. **再修 1.3（book.Type）、1.4（contentRule.title）**——补字段，风险低，直接解锁「下载站 + 正文页标题」两类源。
3. **2.2（nextChapterUrl 形参）**——接口变更，涉及 CLI/validate 两处调用点，一次改干净。
4. **2.1 / 2.7（webJs、type）**——需要先决定桌面端要不要接 WebView/字节流，属于功能补齐。
5. **2.6（选择器引号预处理）、2.9/2.10（JS 重载与 ajaxAll 形状）**——兼容性补丁，可分批。
6. 2.3/2.4/2.5 属于「要不要 100% 复刻 legado 奇葩行为」的取舍，建议单独决策后在注释里写清。

---

## 6. 修复记录（2026-10-29 已全部落地）

### 6.1 逐条状态

| # | 级别 | 问题 | 状态 | 改动位置 |
|---|------|------|------|----------|
| 1 | P0 | `@text` 空白归一化 | ✅ 已修 | `util/html.go` 新增 `NodeTextNorm/NodeOwnTextNorm`（块级补空格 + 折叠空白 + trim）；`rule/jsoup.go` 的 `text/ownText/byOwnText`、`js/ext.go` 的 `text()/ownText()/Elements.text()` 全部改用它 |
| 2 | P0 | `[]` 多索引反序 | ✅ 已修 | 删掉 `parseIndexItems` 末尾的 `items` 反转（与 `elementsSingle` 正向遍历叠加成双反转） |
| 3 | P0 | `book.Type` 未赋值 | ✅ 已修 | `GetBookInfo/GetChapterList` 入口 `book.SetSourceType(...)`（正文并发抓取，`GetContent` 不写共享字段以免数据竞争）；新增 `model.SourceTypeToBookType` 与 `BookFlag*` 位域，`IsWebFile` 改 `Type&128`；JS 的 `book.type` 现在是 legado 位域值 |
| 4 | P0 | `contentRule.title` | ✅ 已修 | `analyzeContent` 开头取标题并回写 `chapter.Title`，在解析正文之前执行（正文规则里的 `{{title}}` 才能拿到新值） |
| 5 | P1 | `webJs`/`sourceRegex` 未传 | ✅ 已修 | 新增 `urlx.GetStrResponseOpt`；`GetContent` 传 `contentRule.WebJs/SourceRegex`；URL 选项 `webView:true` 时交给 `Hooks.WebView`，无实现则退回原始 HTML |
| 6 | P1 | 库层缺 `nextChapterUrl` | ✅ 已修 | `Engine.GetContent` 增加变参 `nextChapterUrl`；`content` 命令与 `validate` 正文探测按 `i+1` 传入 |
| 7 | P1 | `getString` 对 List 取首元素 | ✅ 已修 | 新增 `listToString`，对齐 Java `List.toString()` → `[a, b]` |
| 8 | P1 | `%%` 以最长列表为界 | ✅ 已修 | `mergeStringLists/mergeNodeLists/mergeAnyLists` 统一以 `lists[0]` 长度为界 |
| 9 | P1 | `##` 替换后不 trim/不缩进 | ✅ 已修 | 改为「按行 trim → 替换 → 统一补两个全角空格」，替换结果为空才回退到原文 |
| 10 | P1 | 属性选择器裸值静默失败 | ✅ 已修 | `util/select.go` 新增 `normalizeAttrQuotes`，编译前给 `[attr op value]` 的裸值补引号 |
| 11 | P1 | `AnalyzeUrl.type` 未实现 | ✅ 已修 | `type` 非空时返回 hex 字符串（`GetStrResponseOpt`），`GetBytes` 改走内部 `doRequest` 避免递归 |
| 12 | P1 | 搜索去重键 | ✅ 已修 | 只按 `bookUrl` 去重（对齐 `SearchBook.equals`） |
| 13 | P1 | `java.get` 被同名覆盖 | ✅ 已修 | 单个实现按参数个数分派：1 参取变量、2 参 HTTP GET |
| 14 | P1 | `java.ajaxAll` 形状 | ✅ 已修 | `Hooks.AjaxAll` 改为返回 `[]*ConnectResult`，JS 侧拿到带 `url/body/code` 的对象 |
| 15 | P1 | 超时后 runtime 未清理 | ✅ 已修 | 归还池前 `ClearInterrupt()` |
| 16 | P2 | JSONPath 聚合函数 | ✅ 已修 | `jsonRead` 识别尾部 `.length()/.min()/.max()/.avg()/.sum()` 并自行求值 |
| 17 | P2 | `formatJs` 的 `gInt` 每章重置 | ✅ 已修 | `Bindings.GInt *int` 跨章累加，脚本改写后写回 |
| 18 | P2 | `reGetBook`/`refreshTocUrl` 未实现 | ✅ 已修 | `js.Hooks.ReGetBook/RefreshTocUrl` + `InPreUpdateJs` 阶段守卫（非 preUpdateJs 调用会抛错） |
| 19 | P2 | `preUpdateJs` 失败被忽略 | ✅ 已修 | `AnalyzeRule.EvalJSErr` 保留错误，`RunPreUpdateJs` 返回 error，`GetChapterList` 中断 |
| 20 | P2 | 单段无 `@text` 的规则 | ⚠️ 有意保留 | `li`/`div.item` 仍按选择器处理（Go 的容错，真实书源大量依赖；按属性名处理会让这些源解析出 0 章） |
| 21 | P2 | `ExploreKind` 丢弃分组标题 | ✅ 已修 | 保留空地址项（`IsGroup()`），新增 `firstExploreUrl` 选默认地址时跳过 |
| 22 | P2 | `isRedirect` 恒 false | ✅ 已修 | `fetch` 返回 `IsRedirect`，搜索/发现按真实重定向传入 |

### 6.2 报告里另外两条「java 缺口」的更正与补齐

- `base64Decode(str, flags)`、`readTxtFile(path, charset)` **本来就已实现**（报告误列）。
- 新增 `java.downloadFile(content, url)` 两参版（hex 落盘，需 URL 规则带 `type`）与 `java.getTxtInFolder(path)`。
- 仍未实现且不建议假装支持：`startBrowserAwait`（需真浏览器）、`getVerificationCode`（需 OCR）、`queryTTF`（需字体解析）、`getRar*/get7z*`（需原生解压库）。
- **JSON 对象字符串化仍输出 JSON**（legado 是 Java `Map.toString()` 的 `{k=v}`）：只在「把对象直接当字符串用」时才有差别，保持 JSON 对桌面端脚本更可用；需要 App 一致时再改 `JsToString` 的 map 分支。

### 6.3 新增回归用例

| 文件 | 覆盖 |
|------|------|
| `pkg/rule/compat_test.go` | text/ownText 归一化、块级补空格、`[2,0]` 等多索引顺序、`%%` 边界、属性选择器裸值、`getString` 对 List、JSONPath 聚合函数 |
| `pkg/webbook/content_rules_test.go` | `ruleContent.title` 回写、`replaceRegex` 按行 trim+缩进、文件型书源走 `downloadUrls`、文本型 `book.Type==1`、搜索按 bookUrl 去重 |
| `pkg/js/compat_test.go` | `element.text()/ownText()` 归一化、`java.get` 双重载、`ajaxAll` 返回 StrResponse、`gInt` 累加、超时后 runtime 复用、`reGetBook` 阶段守卫 |
| `pkg/urlx/analyze_url_test.go` | URL 选项 `type` 返回 hex |
| `pkg/util/repro_group_test.go` | 裸值属性选择器不再误报、真正非法分组仍上报且不牵连合法分组 |
| `pkg/model/source_test.go` | 分组标题（空地址）保留语义 |

`go build ./... && go vet ./... && go test ./...` 全绿。

---

*本报告的差分测试为临时文件，核对后已删除；上述回归用例已固化入库。*
