# AGENTS.md

**生效范围**：`legado-go/` 及其子目录。
**读者**：所有在本目录生成、修改 Go 代码的 AI agent。
**裁决规则**：本文件与仓库根目录 `AGENTS.md`（Android/Kotlin + Gradle）冲突时，**以本文件为准**——本目录是独立 Go module，不参与 Gradle 构建，不要在这里执行 `./gradlew`。

---

## 1. 项目是什么（先读这段再动手）

把 Legado（Kotlin/Android）的**书源规则引擎**用纯 Go 重新实现。目标不是"写一个类似的下载器"，而是：**同一份书源 JSON，在 Kotlin 客户端和 legado-go 里跑出同样的结果**。

由此产生三条不可动摇的底线，任何设计取舍都要让位于它们：

1. **语义以 Kotlin 源码为唯一裁判**（见第 5 节）——不是以"看起来更合理"为准。
2. **产物必须 `CGO_ENABLED=0`**（见第 2 节）——这是能塞进 Termux、树莓派、静态交叉编译的前提。
3. **规则层必须能脱网单测**（见第 6 节）——真实站点会挂、会改版，测试不能依赖它们。

---

## 2. 工具链基线（硬性，不得协商）

| 项 | 值 | 约束 |
|---|---|---|
| Go | **1.27.x** | `go.mod` 的 `go` 指令必须是 `1.27.0`；**禁止下调**，下调会让第 3 节的写法全部失效 |
| CGO | **禁用** | 构建统一走 `CGO_ENABLED=0`（见 `Taskfile.yaml`）；任何依赖引入 cgo 就换掉，不接受"只在这台机器上要" |
| 格式化 | `gofmt` | 唯一格式化器；`gofmt -l .` 必须无输出 |
| 静态检查 | `go vet` | 必须零告警；不做"先关掉再说" |
| 构建入口 | `Taskfile.yaml` | 新增构建/发布动作加 task，不要写散落脚本 |

### 2.1 直接依赖白名单（6 个）

| 模块 | 用途 | 不可替代的原因 |
|---|---|---|
| `dop251/goja` | 执行书源 JS | 纯 Go 无 cgo；语法覆盖已是 Legado 所用 Rhino 1.8.1 的超集 |
| `PuerkitoBio/goquery` + `andybalholm/cascadia` | CSS 选择器 | 需对齐 jsoup 的 `:contains/:has/:matches/:not` 语义 |
| `antchfx/htmlquery` | XPath 1.0 | 需对齐 jsoup `Selectors` 的 XPath 行为 |
| `ohler55/ojg` | JSONPath | 需支持 legado 的 `$..`、`[?(@.x)]` 等扩展 |
| `golang.org/x/net` | `html` / `publicsuffix` / `proxy` | 标准库没有；`publicsuffix` 决定 Cookie 的二级域名归属 |
| `golang.org/x/text` | GBK/GB2312/Big5 解码 | 中文站点必需 |

**新增依赖的准入门槛**（四条全满足，且在回复里写清理由）：纯 Go（`CGO_ENABLED=0 go build ./...` 通过）、无 `init()` 期网络/文件副作用、许可证为 MIT/Apache-2.0/BSD、属于 `x/` 官方库或周下载量 > 10k。

**明确禁止引入**：ORM、Web 框架、DI 容器、第三方日志库、第三方断言/mock 库（用 `testing` + `net/http/httptest`）。

---

## 3. Go 1.27 写法基线

以下每条都在本机 `go1.27.1` 实测通过。写**新代码**必须遵守；改旧代码时，动到哪个函数就顺手把该函数内的旧写法换掉，不做全仓无差别重写。

### 3.1 必用写法

| 写法 | 起始版本 | 本项目示例 |
|---|---|---|
| `any` 而非 `interface{}` | 1.18 | 全仓已统一为 `any`，继续保持，不要回退 |
| 内置 `min` / `max` / `clear` | 1.21 | `c.Download.Workers = min(c.Download.Workers, 64)`（`pkg/config`） |
| `for i := range n` | 1.22 | `for i := range len(chapters)` 取代 `for i := 0; i < n; i++` |
| 循环变量每轮独立 | 1.22 | **不要再写** `i, ch := i, ch`；闭包直接捕获即可 |
| 泛型方法（方法自带类型参数） | **1.27** | 方法可声明自己的类型参数。限制：接口方法**不能**声明类型参数，泛型方法**不能**用来实现接口方法 |
| 结构体字面量键可用字段选择器 | **1.27** | `Outer{In.X: 1}` 合法；本仓库暂无需求，别为用而用 |
| `strings.CutLast` / `bytes.CutLast` | **1.27** | 取 URL 最后一段、`规则##替换` 的尾部拆分 |
| `net/url.URL.Clone` / `Values.Clone` | **1.27** | `pkg/urlx` 要改 URL 副本时用它，**不要手工复制 URL 结构体字段** |
| `httptest.NewTestServer` | **1.27** | 配合 `testing/synctest` 做内存假网络的新测试 |
| `strings.SplitSeq` / `FieldsSeq` / `Lines` | 1.24 | 遍历行而不保留切片，减少分配（`pkg/model/source.go` 解析 `exploreUrl` 处已改） |
| `os.Root` | 1.24 | 路径来自书源或用户输入时（下载输出、书源文件）用 `os.OpenRoot` 限制在目标目录内 |
| `testing/synctest` | 1.25 | 测并发与超时（`pkg/js` 的 JS 执行超时、`pkg/download` 的并发抓取），不用 `time.Sleep` 赌时序 |
| `sync.WaitGroup.Go` | 1.25 | `wg.Go(func(){...})` 取代 `wg.Add(1); go func(){ defer wg.Done(); ... }()` |
| `slices.Sort` / `SortFunc` | 1.21 | 取代 `sort.Strings` / `sort.Slice` |
| `slices.Contains` | 1.21 | 取代"遍历找相等就 break"（`pkg/rule` 的去重、`byClass` 的命中判断） |
| `slices.Backward(s)` | 1.23 | `for i := len(s)-1; i >= 0; i--` → `for i := range slices.Backward(s)`；要元素就 `for _, v := range` |
| `min` / `max`（内置） | 1.21 | 取代手写的 `if a < b { return a } return b` 小函数 |
| `slices.Sorted(maps.Keys(m))` | 1.23 | 取代"取 keys → 排序"两段式 |
| `maps.Copy(dst, src)` | 1.21 | 取代 `for k, v := range src { dst[k] = v }` |
| `strings.Cut` | 1.18 | 取代 `s[:i]` + `s[i+1:]` + `Index` 三元组 |
| `errors.Join` | 1.20 | 多处校验错误合并（`pkg/config.Validate`、`pkg/source` 批量加载） |
| `errors.Is` / `errors.As` | 1.13 | 判断错误**必须**用它们，不要比较 `err.Error()` 字符串 |
| 类型化 `atomic.Int64` / `atomic.Bool` | 1.19 | 取代 `atomic.AddInt64(&x, 1)` |
| `math/rand/v2` | 1.22 | 需要随机时用它，禁止 `math/rand`（v1） |
| `cmp.Ordered` / `cmp.Compare` | 1.21 | 泛型排序/比较 |

### 3.2 禁止 → 改用（agent 最容易写出的旧代码）

| 禁止写出 | 必须改成 |
|---|---|
| `interface{}` | `any` |
| `sort.Strings(x)` | `slices.Sort(x)` |
| `sort.Slice(x, func(i, j int) bool {...})` | `slices.SortFunc(x, func(a, b T) int {...})` |
| `for k, v := range src { dst[k] = v }`（map 合并） | `maps.Copy(dst, src)` |
| `keys := make([]K, 0, len(m)); for k := range m {...}; sort.Strings(keys)` | `slices.Sorted(maps.Keys(m))` |
| `for _, s := range strings.Split(text, sep)`（只遍历） | `for s := range strings.SplitSeq(text, sep)` |
| `if i := strings.Index(s, sep); i >= 0 {...}` | `if before, after, ok := strings.Cut(s, sep); ok {...}` |
| `for i := len(s) - 1; i >= 0; i--`（倒序遍历） | `for i := range slices.Backward(s)` |
| `for _, x := range xs { if x == v { found = true; break } }` | `slices.Contains(xs, v)` |
| `func minInt(a, b int) int {...}` | 内置 `min(a, b)` |
| `ioutil.ReadFile` / `ioutil.WriteFile` | `os.ReadFile` / `os.WriteFile` |
| `wg.Add(1)` + `go func(){ defer wg.Done() }()` | `wg.Go(func(){...})` |
| `atomic.AddInt64(&n, 1)` | `var n atomic.Int64; n.Add(1)` |
| `fmt.Errorf` 包一个**指针** error（`%w` 传 `*E` 而 `E` 已实现 error） | 传值或实现值接收者；Go 1.27 的 `printf` 分析器会报这个 |
| `for i := 0; i < n; i++` | `for i := range n`（仅当不用 i 的初值时） |
| `if err != nil { return err }` 层层裸传 | 加语境：`fmt.Errorf("获取目录: %w", err)` |
| `_ = f()` 忽略错误 | 要么处理，要么写注释说明为何可忽略；**不得静默** |
| `time.After` 在循环/长生命周期里做超时 | `time.NewTimer` + `defer t.Stop()`，避免泄漏 |

### 3.3 本项目的三个"不要升级"

1. **不要迁移到 `encoding/json/v2`。**
   实测：对 `{"name":"a","name":"b"}`，v1 静默取最后一个值，v2 返回 `jsontext: duplicate object member name "name"`。真实书源里存在重复键、非法 UTF-8 等脏数据，切到 v2 会直接让一批源加载失败。
   → 解析书源继续用 `encoding/json`。**确实需要严格模式时**，只在局部用 `encoding/json/jsontext` 做结构探查，并写注释说明。

2. **不要使用任何 `GOEXPERIMENT`**（含 `simd`、`archsimd`、`jsonv2`）。实验特性不进产物，`go.mod` 与源文件里都不许出现。

3. **不要引入 `log/slog` 或全局 logger。**
   日志是注入式的：`js.OnLog func(string)`、`Config.Log func(string)`、`download.Options.Progress func(...)`。库代码**不得**直接往 stdout/stderr 写；只有 `cmd/legado` 负责最终输出。

---

## 4. 结构约束

依赖只能自上而下（箭头表示"被谁依赖"），**禁止反向或跨层回指**：

```
util   model   config   debug         ← 叶子：只依赖标准库
  ↓
store   net
  ↓
  js                                  ← 依赖 model/net/store/util
  ↓
rule                                  ← 只依赖 js/model/util，禁止碰 webbook/source
  ↓
urlx
  ↓
webbook
  ↓
source（校验）    download（落盘）
  ↓
legado.go / cmd/legado                ← 唯一对外门面 + CLI
```

| 包 | 职责（一个包一件事） |
|---|---|
| `pkg/util` | HTML 清洗（`HtmlFormat`/`FormatKeepImg`）、URL 绝对化、编码识别。**无业务状态** |
| `pkg/model` | `BookSource` / `Book` / `BookChapter` / `SearchBook` / 各 `Rule` 结构；只做数据与字段默认值 |
| `pkg/config` | `config.json` 的加载、校验、生成、字段文档 |
| `pkg/store` | Cookie（按二级域名）与 cache 的持久化 |
| `pkg/net` | HTTP 客户端、代理、重试、响应编码解码 |
| `pkg/debug` | 调试日志：state 语义（1/-1/10/20/30/40/1000）、文本/JSONL/响应体落盘三种 Sink、`[mm:ss.SSS]` 时间戳。**零依赖，只许 import 标准库** |
| `pkg/js` | goja 引擎 + `java.*`/`source`/`book`/`cookie` 等宿主对象注入 |
| `pkg/rule` | 规则引擎五模式：JSoup / XPath / JSONPath / Regex / JS，以及切分器、索引、`{{}}` |
| `pkg/urlx` | `AnalyzeUrl`：URL 规则、`<1,2,3>` 分页、`{{}}`、POST body |
| `pkg/webbook` | 业务四步：搜索 / 发现 / 详情 / 目录 / 正文 |
| `pkg/source` | 书源加载、匹配（`-source` 十级优先级）、语法校验 |
| `pkg/download` | 并发下载、txt/md/图片落盘 |

硬规则：

- 新增包必须放 `pkg/` 下、单个小写单词命名、有 `doc.go` 或包级注释说明职责。
- `cmd/legado` **只做**参数解析、调用 pkg、打印；不许出现 HTTP 请求、HTML 解析、业务判断。
- `legado.go` 是唯一对外 API 面；新增导出符号必须有 doc comment，且注释写"做什么"，不写"怎么实现"。
- `pkg/rule` 出现 `webbook`/`source` 的 import = 架构违规（会让规则引擎无法脱网单测）。
- `pkg/debug` 只能 import 标准库。它被 `rule`/`urlx`/`webbook`/`cmd` 反向引用，一旦 import 项目内其他包立刻成环。

### 4.1 调试打点约定

对应客户端「书源调试」（`Debug.startDebug` + `model/webBook/*.kt` 里的 `Debug.log`）。

- 打点统一走 `pkg/debug`；库代码里不许 `fmt.Print`（见 3.3）。
- 文案与位置对齐 Kotlin：`≡` 提示、`︾`/`︽` 阶段起止、`┌`/`└` 规则组、`◇` 统计。新增字段日志沿用 Kotlin 的标签（如 `┌获取书名`），**不要自创符号**。
- 响应体一律 `debug.Body(state, body)`，state 用 10/20/30/40 表达"这是哪一步的源码"。**不许**把响应体拼进普通日志行——Sink 靠 state 决定截断、落盘与 JSON 字段。
- 列表类字段日志只对首条打（`i == 0`），否则几十条结果会刷屏；对齐 Kotlin 的 `log` 参数。
- `└` 后面必须是**规则求值结果**，不是合并进实体后的字段值。Kotlin 的写法是
  `"┌获取书名"` → 求值 → `"└$result"`，即使结果为空、实体沿用了旧值，`└` 也照空打。
  空是"规则没命中"的唯一信号，写反了会把书源规则失效伪装成正常。
- 未启用时必须零开销：拼串前先判 `debug.Enabled()`（见 `pkg/urlx` 的 `requestLine`）。
- 并发路径上的成组日志用 `debug.Pair` / `debug.Lines`，它们保证 `┌` 与 `└` 不被其他 goroutine 插队。
- 新增阶段或 state 时，同步更新 `debug.StateName`、README 的符号表、`TestDebugTraceManhua`。

---

## 5. 语义对齐：以 Kotlin 为唯一裁判（最高优先级）

### 5.1 改规则语义前，先读这些文件

| 你要改的东西 | 必读 Kotlin 源（相对仓库根） |
|---|---|
| 规则分发、`@`／`##`／`&&`／或运算／`%%`、`@put/@get` | `app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt` |
| 切分规则串、索引表达式 `[0] [-1] [0:3] [!0]` | 同目录 `RuleAnalyzer.kt` |
| CSS/jsoup 取值（`text`/`html`/`attr`/单段规则语义） | 同目录 `AnalyzeByJSoup.kt`（含 `SourceRule`） |
| XPath / JSONPath / 正则 | 同目录 `AnalyzeByXPath.kt`、`AnalyzeByJSonPath.kt`、`AnalyzeByRegex.kt` |
| URL 规则、分页、`{{}}`、POST | 同目录 `AnalyzeUrl.kt` |
| JS 注入的变量与 `java.*` 方法 | `modules/rhino/`、`app/.../model/analyzeRule/RuleData.kt` |
| 搜索/发现/详情/目录/正文四步流程 | `app/src/main/java/io/legado/app/model/webBook/` |
| 对比其他实现线索 | 仓库根 `legado-rule-engine.md`、`书源知识库.md` |

### 5.2 禁止"顺手优化"

改语义时的默认姿态是**照抄怪癖**，不是修得更好。以下操作一旦发生，必须先在 Kotlin 里找到依据，否则视为 bug：

- 给取值结果 `TrimSpace`（legado 在特定位置才 trim，位置不同结果不同）
- 去重、排序、过滤空值
- 给缺省字段补默认值（默认值往往在 `BookSource` 的 getter 里，不在解析处）
- 把"空结果"当 `nil`、把 `nil` 当空串——三态必须显式区分
- 替换 `&&`/`||`/`%%` 的组合语义（分别是追加/短路/交错，**不是**集合交集并集）
- 改 `##` 的段数上限（最多 4 段）
- 在 `GetString` 里"只取第一条"（多结果要按位置语义处理）

### 5.3 空值三态

`nil`（无结果）、`""`（有结果但为空）、`[]`（空元素列表）在规则链里含义不同，尤其在判断"是否继续用上一步结果"时。写任何 `if x == ""` 之前，先问：这里该判的是哪一个。

---

## 6. 测试约束

### 6.1 默认断网

真实站点请求一律走录制/回放，快照在 `testdata/fixtures/`（`index.json` 以 `method + url + body sha1` 为键）。

| 场景 | 命令 |
|---|---|
| 日常回归（断网、秒级） | `go test ./pkg/webbook` |
| 直连真实站点 | `LEGADO_ONLINE=1 go test ./pkg/webbook -run TestSourceOnlineLive` |
| 重新录制快照 | `LEGADO_RECORD=1 go test ./pkg/webbook -run 'TestSource.*Replay'` |

纪律：

- 测试默认路径**不许**联网；联网代码只能出现在 `LEGADO_ONLINE` / `LEGADO_RECORD` 分支后面。
- 不许手工编辑快照文件让它"看起来对"。要改就重新录制，并在回复里说明站点是否变过。
- **文件名不等于源名**，一个 JSON 里可能有多个源：
  - `testdata/sources/yumanhua_comic_source.json` → 漫画客（搜索 9 条）
  - `testdata/sources/t66y_book_source.json` → 草榴社区-文学（不可达，仅离线规则校验）+ 狼人小说（发现 30 条 / 目录 70 章）
  - `../sources/kantianxia.json` → VISTA看天下(纯发现源)（18 条）+ 神奇漫画（24 条）
- 不要拿已失效的源当回归基准：`shenqimanhua` 搜索页已无 `/comic/` 链接（站点改版）、`t66y` TCP 超时（网络不可达）。要联网补充验证就用 VISTA 看天下。
- 录制路径是并发的（下载会并发抓取），改动后必须跑 `go test -race`。

### 6.2 什么改动必须配测试

| 改了 | 必须加 |
|---|---|
| `pkg/rule` 任何语义 | `pkg/rule/regress_test.go` 加最小复现用例（输入 HTML/JSON + 规则 + 期望值），并在注释里写对应的 Kotlin 行为 |
| `pkg/urlx` 的 URL 拼接/分页/`{{}}` | `pkg/urlx/analyze_url_test.go` 表驱动用例 |
| `pkg/js` 宿主对象 | `pkg/js/js_test.go`，断言必须覆盖"返回值类型"而不只是"没报错" |
| `pkg/source` 匹配/校验 | `pkg/source/` 对应测试，覆盖十级优先级的边界 |
| 业务四步流程 | `pkg/webbook/testdata_source_test.go` 用真实书源快照断言条数与关键字段 |
| 调试打点（文案/位置/state） | `pkg/webbook/debug_trace_test.go` 断言阶段标记与四种 state 都在 |

测试写法：表驱动用 `for _, tc := range cases`（Go 1.22 起**不需要** `tc := tc`）；断言用标准库，失败信息带上输入，不要只写 `want != got`。

---

## 7. 质量门（不全绿 = 未完成）

```bash
gofmt -l .                 # 必须无输出
go build ./...             # 必须成功
go vet ./...               # 必须零告警
go test ./...              # 全部包必须 ok（config js model rule source urlx util webbook download）
go test -race ./...        # 并发相关改动必跑
CGO_ENABLED=0 go build ./...   # 动了依赖或构建标签时必跑
test -z "$(go fix -json ./... | grep -v '^{}$')"  # 现代化自检：无诊断（见 7.1）
```

### 7.1 `go fix` 是官方的"写法漂移"探测器

Go 1.27 的 `go fix` 内置现代化器：`atomictypes`、`embedlit`、`minmax`、`mapsloop`、`rangeint`、
`slicesbackward`、`slicescontains`、`sortslice`、`stringsseq`、`stringscut`、`unsafefuncs`。
它们正是本项目"新写法"清单的机器版本，跑一遍就知道有没有混进旧写法。

**验收判据是 `go fix -json ./...` 没有任何诊断对象**（每个包输出一行 `{}` 即通过）：

```bash
test -z "$(go fix -json ./... | grep -v '^{}$')"   # 无诊断即成立
```

> **不要用 `go fix -diff` 判断**。它有两个坑：
> 1. 同一文件里多个分析器都要改 import 块时（例如 `maps.Copy` 与 `slices.Backward` 都要插 import），
>    编辑会"冲突"，工具**跳过这些修复且不打印 diff**，只在 stderr 留一句
>    `1 of 10 fixes skipped (e.g. due to conflicts)`。看起来"没有 diff"，其实一条都没修。
> 2. 它的退出码不区分"无待修"和"跳过了待修"。
>
> 所以看到 `fixes skipped` 时，用 `-json` 把待修项列出来，**手工应用**（按 `suggested_fixes` 的
> 编辑内容改），然后再用 `-json` 复核。

---

## 8. 已知陷阱（本项目真实踩过，写代码时直接避开）

| 现象 | 根因 | 正确做法 |
|---|---|---|
| 页面明明有内容却解析为空 | **RE2 不支持前瞻/后顾**，`(?!x)` 直接编译失败或语义错 | 不用环视；改用"匹配后校验边界"或手工扫描（见 `pkg/util/html.go` 的 `removeTags`） |
| 取 `<img>` 属性乱套 | RE2 对嵌套大括号取**最短**匹配 | 手工解析标签属性，别用正则吃嵌套结构 |
| `/allbook{{page===1?'':'_2_'+page}}.html` 首页 404 | 替换值为**空串**时被当成"未命中"，花括号被保留 | `InnerBraceReplace` 必须返回 `(string, bool)`，命中即替换为空 |
| 章节地址变成书籍地址、正文为空 | 单段规则 `"href"` 被当 CSS 标签选择器 | 裸词按**属性名**处理，`text.`/含索引/含空格才当选择器（对齐 `getResultLast`） |
| JS 里 `result.select('td').text()` 报 `has no member 'text'` | 返回的是裸数组，没有 jsoup `Elements` 方法 | 返回"既是数组又带 `text/attr/size/get` 方法"的对象（`elementsObject`） |
| JSON 对象被误当成 JS 的 NativeObject | 只按类型判断，无法区分来源 | 用标记类型 `*NativeObject` 显式区分（`pkg/rule/native.go`） |
| 正文里的 `<img>` 全没了 | 简介用的 `HtmlFormat` 会剥离图片 | 正文走 `FormatKeepImg` |
| URL 里的 `{{}}` 变成 `%7B%7B%7D%7D` | `url.ResolveReference().String()` 会做百分号转义 | 字符串拼接 + 路径归一化，不经过 `URL.String()` |
| 正则里逗号前瞻写错导致 POST body 解析错 | `paramPattern` 是 `\s*,\s*(?=\{)`（逗号 + 前瞻左花括号），不是整个大括号表达式 | 按 Kotlin 原文逐字符核对 |
| `-source` 用文件名/URL 找不到书源 | 匹配只有"名称全等"一档 | 十级优先级：序号 → bookSourceUrl → 名称 → 文件名 → bookUrlPattern → 域名 → 子串 |
| `config check` 通过但字段名拼错 | 用小写比较导致 `cookiefile` 被当合法 | 用原始驼峰键比较 + 编辑距离 ≤1 提示 |
| 并行 `go run` 报 `Access is denied` | Windows 下 build cache 锁冲突 | 串行执行，不要并行跑多个 `go run`/`go build` |
| 调试流里 `┌获取书名` 后面是空的 `└` | 规则取不到值，不一定是引擎 bug | 先 `debug -save-dir` 存下响应，再对着该字段的规则手查选择器；`-body head` 也能立刻看出是不是被反爬页替换了 |

---

## 9. Agent 行为约束

1. **一次只解决一个关注点。** 不把"修 bug"和"重构"塞进同一次改动；需要重构就单独说明。
2. **不确定语义就去读 Kotlin，不许猜。** 猜出来的"合理行为"通常和 legado 相反，且会被快照测试抓住。
3. **改完必须实跑第 7 节全部命令并贴结果。** 不要写"应该能通过"。
4. **不许为了变绿而放宽断言、跳过测试、删用例。** 测试失败先判断是代码错还是站点变了——站点变了要明说，并说明用哪个源代替验证。
5. **不许留半成品**：`TODO`、`panic("not implemented")`、空实现函数。做不到就在回复里说明卡在哪。
6. **不许制造临时文件残留**：调试用的 `tmp_*/`、`*.bak`、探针 `main.go` 用完即删；不要把 `cookies.json`、`cache.json`、`config.json` 等运行产物留在仓库。
7. **不许动 `.workbuddy/`。**
8. **不许改 `go.mod` 的 `go` 指令版本**（升可以，在明确需要新语法时；降绝对不行），不许把 `require` 块拆散（1.27 的 tidy 会强制合并为"直接 + 间接"两块）。
9. **新增公开 API 先想清楚是否必要**：`pkg/` 里的导出面越窄越好，能小写就小写。
10. **回复里说清三件事**：改了哪些文件、行为发生了什么变化、用什么命令验证的。不要只说"已完成"。

---

## 10. 提交前 checklist

- [ ] `go.mod` 的 `go` 指令 = `1.27.0`，没有新增计划外依赖
- [ ] 新代码用的是第 3.1 节写法，没有出现第 3.2 节的禁用写法
- [ ] 没有引入 cgo、`GOEXPERIMENT`、`log/slog`、`encoding/json/v2`
- [ ] 没有新增反向/跨层 import（第 4 节图）
- [ ] 语义改动都能指到 Kotlin 的 `文件:行` 依据
- [ ] 对应包的回归用例已加，且**先失败后通过**
- [ ] `gofmt -l .` 无输出、`go build`/`go vet` 干净、`go test ./...` 全绿、`go fix -diff ./...` 无 `---`/`+++` 块
- [ ] 并发改动跑过 `go test -race ./...`
- [ ] 没有临时文件、运行产物、被注释掉的死代码
- [ ] README / `docs/rule-syntax.md` 中受影响的行为已同步更新
