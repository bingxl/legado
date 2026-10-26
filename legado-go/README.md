# legado-go

Legado（阅读）书源 / 漫画源规则引擎的 **Go 重构版**。用于在服务端或命令行上，用 Legado 的书源 JSON 做搜索、发现、详情、目录、正文解析与整本下载。

不是 UI 移植——只重建规则执行层：把 `AnalyzeRule` / `AnalyzeUrl` / `WebBook` / `CookieStore` / `JsExtensions` 这一整套能力用 Go 重新实现，语法与行为对齐 Legado 源码。

## 特性

- **完整规则语法**：JSoup(CSS) / XPath / JSONPath / 正则 / JS 五种模式，`@put` `@get` `{{}}` `$N` `##` `&& || %%`、新老两套索引语法全部支持
- **URL 规则**：`searchUrl` / `exploreUrl` 的 `,{...}` 选项（method / headers / body / charset / retry / webView / js）、`<1,2,3>` 分页、`{{page}}` 与 `{{page-1}}`
- **Cookie 自动处理**：响应 `Set-Cookie` 按二级域名持久化，后续请求自动合并注入请求头，无需书源关心
- **JS 注入**：`java` / `cookie` / `cache` / `source` / `book` / `chapter` / `result` / `baseUrl` / `src` / `title` / `nextChapterUrl` 全套，`jsLib` 按书源共享作用域预编译
- **离线 + 在线校验**：静态检查规则语法，可选联网实测搜索 → 详情 → 目录 → 正文
- **下载**：文本导出 txt/md；漫画按章建目录下载图片
- **配置**：`config.json` 存常用参数（书源目录、默认源、超时、下载目录等），
  优先级 命令行 > 配置 > 内置默认；`config gen` 生成、`config check` 校验

> 详细文档：[规则语法与 JS API 全表](docs/rule-syntax.md) · 可运行示例：[examples/basic](examples/basic/main.go)

## 环境要求

- Go **1.26+**
- 无需任何第三方运行时（JS 由内嵌 goja 执行）

主要依赖：`goja`（JS 引擎）、`goquery`（CSS 选择器）、`htmlquery`（XPath）、`ojg`（JSONPath）、`x/net/publicsuffix`（二级域名）、`x/text`（编码转换）。

## 快速开始

```bash
# 在 legado-go 目录下编译
go build -o legado ./cmd/legado

# 0.（可选）把常用参数写进 config.json，之后就不用每条命令都带 -dir/-source
./legado config gen -dir ./testdata/sources -source yumanhua
./legado config check                    # 校验（会真的加载书源验证 sourceDir/source）

# 下面用自带的 testdata 书源演示，换成你自己的目录（如 ../sources）即可
# 1. 看看书源能不能加载（先认名字，后面 -source 要用）
./legado list -dir ./testdata/sources

# 2. 校验书源语法（离线）
./legado validate -dir ./testdata/sources

# 3. 搜索
./legado search -dir ./testdata/sources -source yumanhua -key 海贼

# 4. 下载（文本源出 txt，漫画源出图片目录）
./legado download -dir ./testdata/sources -source yumanhua -book http://yumanhua.com/GZxNZae/ -max 5 -out ./out

# 5. 跑完整的 API 示例（搜索→详情→目录→正文→下载）
go run ./examples/basic -dir ./testdata/sources -source yumanhua -key 海贼 -max 1
```

也可以不编译直接跑：`go run ./cmd/legado <命令> [选项]`。

> 生成了 `config.json` 之后，上面例子里的 `-dir ./testdata/sources -source yumanhua` 都可以省略，
> 直接 `./legado search -key 海贼`。命令行参数依然能覆盖配置，详见[参数详解·零](#零configjson把常用参数存下来)。

### 用 Task 交叉编译

装了 [Task](https://taskfile.dev) 后，在 `legado-go` 目录直接跑：

```bash
task build:windows   # dist/legado-windows-amd64.exe
task build:linux     # dist/legado-linux-amd64
task build:armv8     # dist/legado-linux-arm64（aarch64，给 Termux / 树莓派）
task build:all       # 上面三个一起出
task build           # 按当前平台出（Windows 下即 exe）
task clean           # 清 dist/
```

全部为 `CGO_ENABLED=0` 静态编译，产物可直接拷到目标机器运行。Termux 用法：
`adb push dist/legado-linux-arm64 /data/local/tmp/legado && adb shell chmod +x /data/local/tmp/legado`，
或先 `termux-setup-storage` 再拷到 `~/`；`GOARCH=arm`（32 位 armv7）把 `build:armv8` 里的 `GOARCH` 换成 `arm` 即可。

> Windows 提示：若直接运行 `./legado.exe` 读 `testdata/sources/*.json` 报 `winapi error #5`，是杀软/目录权限拦截子进程，改用 `go run ./cmd/legado` 或给目录授权即可，与解析逻辑无关。

---

# 参数详解

CLI 的参数分三层：

1. **config.json**（可选）——把常用值存起来，所有命令共享
2. **通用参数**（每个命令都能用，决定"去哪读书源、用哪个源、怎么发请求"）
3. **命令参数**（由命令自己定义）

优先级永远是 **命令行 > config.json > 内置默认**。先看配置文件，它是"少敲参数"的关键。

## 零、`config.json`：把常用参数存下来

每次都敲 `-dir ./sources -source 漫画客 -cookie cookies.json` 很啰嗦。把常用值写进
**当前工作目录**的 `config.json`，之后所有命令自动生效。

**加载顺序（也就是优先级）**：

```
命令行参数   >   config.json   >   内置默认值
```

具体过程是：启动先读配置 → 用配置里的值作为每个参数的默认值 → 再解析命令行。
所以配置里写 `"source": "漫画客"`，命令行再给 `-source 2` 就是 `2` 生效；命令行没给就用配置的。

没有 `config.json` 也完全正常（用内置默认，不报错），因此这是**可选**的。

### 0.1 生成与校验

```bash
./legado config gen                        # 生成 ./config.json（已存在则拒绝，除非 -force）
./legado config gen -dir ./sources         # 生成并预填 sourceDir
./legado config gen -dir ./sources -source 漫画客 -workers 8
./legado config gen -out -                 # 打到终端，不落盘
./legado config gen -docs                  # 顺带打印每个配置项的含义

./legado config check                      # 校验 ./config.json
./legado config check -config my.json       # 校验指定文件
./legado config check -json                 # 机器可读（CI 用）
```

`config gen` 的参数：

| 参数 | 说明 |
|---|---|
| `-out <文件>` | 输出路径，默认 `config.json`；`-out -` 打到标准输出 |
| `-force` | 文件已存在时覆盖 |
| `-dir` / `-file` / `-source` | 预填书源位置与默认书源 |
| `-cookie` / `-cache` / `-ua` | 预填存储文件与 UA |
| `-timeout` / `-js-timeout` | 预填超时（秒） |
| `-debug-output` | 预填 `debug: true` |
| `-out-dir` / `-workers` | 预填下载目录与并发 |
| `-docs` | 生成后打印配置项说明 |

`config check` 不只查语法，还会**真的去加载书源**，验证 `sourceDir` / `sourceFile` / `source` 能不能用：

```
检查 config.json
   · sources: 已加载 2 个书源
   · source: "yumanhua" → 漫画客 <http://yumanhua.com>

共 0 个错误，0 个警告
```

有问题时逐条指出（出现 `✗` 时退出码为 2，可直接放进 CI）：

```
检查 config.json
   ! cookiefile: 未知字段，是否想写 cookieFile？
   ! download.outdir: 未知字段，是否想写 download.outDir？
   ✗ sourceDir: 目录不存在: ./no-such-dir
   ! httpTimeout: 9999秒 偏大，建议 <= 600秒
   ✗ jsTimeout: -1秒 不能为负数
   ✗ download.format: 只能是 txt / md / images（或留空按书源类型）
   · download.workers: 为 0（视为未设置），运行时使用默认 4
```

前两条尤其有用：**JSON 键名区分大小写**，写成 `"cookiefile"` 不会生效，没有这个检查
就只能自己盯着拼写看。程序不认识的键会附上最接近的正确写法。

### 0.2 全部配置项

只写想改的项，没写的自动用默认值。

| 键 | 类型 | 默认 | 对应命令行 | 说明 |
|---|---|---|---|---|
| `sourceDir` | string | `./sources` | `-dir` | 书源文件夹，递归加载 |
| `sourceFile` | string | 空 | `-file` | 单个书源文件；非空时优先于 `sourceDir` |
| `source` | string | 空 | `-source` | 默认书源，6 种写法同 `-source` |
| `cookieFile` | string | `cookies.json` | `-cookie` | 空 = 只存内存 |
| `cacheFile` | string | `cache.json` | `-cache` | 空 = 只存内存 |
| `userAgent` | string | 内置 Chrome UA | `-ua` | 书源 header 里的 UA 优先 |
| `httpTimeout` | int | `30` | `-timeout` | HTTP 超时（秒） |
| `jsTimeout` | int | `30` | `-js-timeout` | JS 执行超时（秒） |
| `debug` | bool | `false` | `-debug` | 调试日志 |
| `download.outDir` | string | `./out` | `-out` | 下载输出目录 |
| `download.format` | string | 空 | `-format` | `txt` / `md` / `images`，空 = 按书源类型 |
| `download.workers` | int | `4` | `-workers` | 并发章节数 |
| `download.max` | int | `0` | `-max` | 最多下载章节数，0 = 全部 |
| `download.start` | int | `0` | `-start` | 起始章节下标 |

最小可用写法（只改书源目录和默认源）：

```json
{
  "sourceDir": "./sources",
  "source": "漫画客"
}
```

完整写法（`legado config gen` 的产物）：

```json
{
  "sourceDir": "./sources",
  "sourceFile": "",
  "source": "漫画客",
  "cookieFile": "cookies.json",
  "cacheFile": "cache.json",
  "userAgent": "",
  "httpTimeout": 30,
  "jsTimeout": 30,
  "debug": false,
  "download": {
    "outDir": "./out",
    "format": "",
    "workers": 4,
    "max": 0,
    "start": 0
  }
}
```

### 0.3 几条实战注意

- **`-config <文件>` 换一份配置**：`./legado search -config ./prod.json -key 海贼`。
- **`-config=` 完全关闭配置**：临时用内置默认跑一次。排查"是不是配置搞的鬼"时很有用。
- **`sourceFile` 与 `-dir` 打架**：库里 `sourceFile` 优先于 `sourceDir`。所以配置里写了
  `sourceFile` 时，你在命令行补 `-dir`，程序会**自动忽略配置里的 `sourceFile`**——
  否则你会发现 `-dir` 莫名其妙不生效。
- **配置里的相对路径相对"当前工作目录"**，不是相对 `config.json` 所在目录。
- **未知键只提示不报错**：多写的键不影响运行，stderr 会打一行提示，`config check` 会列出来。
- **`config` 命令自己不读配置**（它管的就是配置），其余命令都会读。
- **命令行可以只覆盖部分项**：配置里三个参数，命令行改一个，另外两个仍来自配置。

## 一、书源从哪来：`-dir` / `-file`

```bash
-dir  <目录>   书源文件夹，递归加载其中的 .json 和 .txt
-file <文件>   单个书源文件
```

| 场景 | 写法 |
|---|---|
| 一整个书源库 | `-dir ./sources` |
| 只测一个文件 | `-file ../sources/kantianxia.json` |

规则细节：

- **`-file` 优先于 `-dir`**：两个都给时只读 `-file`，`-dir` 被忽略。两个都不给直接报错
  `必须指定书源文件夹(SourceDir)或书源文件(SourceFile)`。
- `-dir` 会**递归子目录**，只认 `.json` / `.txt`，其它扩展名跳过。
- 单个文件加载失败不会中断整体，只往 stderr 打一条 `加载警告:`，其余文件照常加载。
- 所有书源按 `bookSourceUrl` **去重**（同一个源被多个文件包含时只保留第一个）。
- 用 `-dir` 加载时，如果书源本身没写 `bookSourceGroup`，会**用文件名（去扩展名）补上**，
  所以 `kantianxia.json` 里的源分组就是 `kantianxia`。

**一个文件里可以有多个书源**，三种写法都支持：

```jsonc
// 1. 数组（Legado 导出的标准格式，最常见）
[ { "bookSourceName": "A", ... }, { "bookSourceName": "B", ... } ]

// 2. 单个对象
{ "bookSourceName": "A", ... }

// 3. 多个对象直接拼接（部分站点导出的脏数据）
{ "bookSourceName": "A", ... }
{ "bookSourceName": "B", ... }
```

> 所以"一个 JSON 里有几个源"和"`-source` 怎么写"是两件事：文件是**容器**，
> `-source` 选的是**容器里的某一个源**。

## 二、用哪个书源：`-source`（重点）

```bash
-source <key>   可用 6 种写法，不区分大小写；省略时用第 1 个书源
```

### 2.1 六种写法

| 写法 | 例子（假设加载了 `kantianxia.json`） | 说明 |
|---|---|---|
| 序号 | `-source 2`、`-source "#1"` | 对应 `list` 输出的第 1 列，从 1 开始 |
| 书源名称 | `-source 神奇漫画` | 先全等，再子串 |
| `bookSourceUrl` | `-source https://shenqimanhua.net` | 全等（忽略大小写、忽略末尾 `/`） |
| 域名 | `-source shenqimanhua.net` | 等价于上一条，最省事；`www.` 和端口会被忽略 |
| 书籍详情页 URL | `-source https://shenqimanhua.net/comic/abc123` | 按 `bookUrlPattern` / 域名归属倒推是哪个源 |
| 文件名 | `-source kantianxia.json` 或 `-source kantianxia` | **文件名 = 该文件里的源**；一个文件多个源时是"多选一"（见 2.3） |

> 常见误区：`-source` 填的是"书源"，不是"书籍"。书籍地址请给 `-book`，
> 两者可以同时出现：`-source 神奇漫画 -book https://shenqimanhua.net/comic/xxx`。

### 2.2 匹配优先级

从高到低逐级匹配，**命中某一级就停**（该级多个候选时取列表里第一个）：

| 级别 | 规则 |
|---|---|
| 1 | 序号（`2` / `#2`） |
| 2 | `bookSourceUrl` 全等（忽略大小写、末尾 `/`） |
| 3 | `bookSourceName` 全等（忽略大小写、前后空格） |
| 4 | 文件名全等（`kantianxia.json` / `kantianxia` / 绝对路径都行） |
| 5 | 书籍详情页 URL 命中该源的 `bookUrlPattern` |
| 6 | 域名相同（`host` 比较，忽略 `www.` 与端口） |
| 7 | `bookSourceUrl` 含关键字 |
| 8 | `bookSourceName` 含关键字 |
| 9 | 文件名含关键字 |
| 10 | `bookSourceGroup` 含关键字 |

因为"全等"排在"子串"前面，`-source 神奇漫画` 一定不会误中另一个叫"神奇漫画备用"的源。

### 2.3 省略 `-source` 与歧义提示

- **省略**：使用加载到的**第 1 个书源**。如果不止一个源，会往 stderr 打一行提示：

  ```
  提示: 未指定 -source，使用第 1 个书源「VISTA看天下(纯发现源)」（共 2 个，用 list 查看）
  ```

- **一个 key 命中多个源**（典型是文件名，因为一个文件常含多个源）：取第一个，并列出候选：

  ```
  提示: -source "kantianxia.json" 匹配到 2 个书源，已用「VISTA看天下(纯发现源)」；可用序号或完整名称精确指定。候选: VISTA看天下(纯发现源) / 神奇漫画
  ```

  这时如果第一个源没有 `searchUrl`（纯发现源），`search` 会继续报：

  ```
  搜索失败: 书源「VISTA看天下(纯发现源)」没有 searchUrl（纯发现源）；该源有发现地址，可改用 explore
  ```

  解法就是换更精确的 key：`-source 2` 或 `-source 神奇漫画`。

### 2.4 找不到书源的报错

`-source` 匹配不到时不会只丢一句"找不到"，而是把**可用清单和可用写法**一起打出来：

```
$ ./legado search -file ../sources/kantianxia.json -source 海贼王 -key 海贼
未找到书源: "海贼王"
可用书源（共 2 个）:
   1. VISTA看天下(纯发现源)      https://open3.vistastory.com      kantianxia.json
   2. 神奇漫画                   https://shenqimanhua.net          kantianxia.json
-source 可写：序号(1)、名称、bookSourceUrl 全等、域名、书籍详情页 URL 或文件名(如 kantianxia.json)
```

照最后一行改就行——比如 `-source 2`、`-source shenqimanhua.net`、`-source kantianxia.json`。

> 如果你用的还是早期版本，`-source` 只做了 URL / 名称的全等与子串，写文件名会直接报"未找到书源"；
> 当前版本已加上文件名、域名、详情页 URL、序号四种写法。

## 三、通用参数逐条说明

所有命令（`validate` / `list` / `search` / `explore` / `info` / `toc` / `content` / `download`）都支持这 10 个参数。
下表的"默认值"是**没有 config.json 时**的默认；有配置时以配置为准，命令行再覆盖。

| 参数 | 默认值 | 配置项 | 作用 | 备注 |
|---|---|---|---|---|
| `-config <文件>` | `config.json` | — | 用哪份配置文件 | `-config=` 完全不读配置 |
| `-dir <目录>` | `./sources` | `sourceDir` | 书源文件夹 | 递归；与 `-file` 二选一，`-file` 优先 |
| `-file <文件>` | 空 | `sourceFile` | 单个书源文件 | 一个文件可含多个源 |
| `-source <key>` | 空 | `source` | 选哪个书源 | 6 种写法，见上一节；空 = 第 1 个 |
| `-cookie <文件>` | `cookies.json` | `cookieFile` | Cookie 持久化路径 | `-cookie=` 关闭落盘（只存内存） |
| `-cache <文件>` | `cache.json` | `cacheFile` | 缓存持久化路径 | `-cache=` 关闭落盘 |
| `-ua <UA>` | Chrome 120 桌面 UA | `userAgent` | 覆盖默认 User-Agent | 书源 `header` 里显式写了 UA 时以书源为准 |
| `-timeout <秒>` | `30` | `httpTimeout` | HTTP 请求超时 | 单次请求总超时，含重定向与读 body |
| `-js-timeout <秒>` | `30` | `jsTimeout` | 单段 JS 执行超时 | 超时后中断执行并按空结果处理 |
| `-debug` | `false` | `debug` | 打调试日志 | 输出到 stderr，含书源 JS 里 `java.log()` 的内容 |

几个容易忽略的点：

- **参数默认值可能被 config.json 改掉**。`-h` 里显示的就是"配置生效后"的默认值，
  所以看到 `-dir` 默认不是 `./sources` 时先想想是不是有 config.json。
- **`-cookie` / `-cache` 的默认值只在 CLI 生效**。用 Go 库时 `Config.CookieFile` 留空表示
  "只在内存里，不落盘"（适合一次性任务）。
- **命令行与 Cookie 的关系**：命令正常结束会把 Cookie 写回文件；进程内收到新的 `Set-Cookie`
  也会立即落盘。所以 `search` 之后换一条命令 `toc`，登录态是延续的。中途 `Ctrl+C` 强杀不会写。
- **`-ua` 只影响"书源没指定 UA"的请求**。书源 `header` 里写了 `User-Agent` 时书源优先，
  这是 Legado 的行为，也是很多站点反爬能过的原因。
- **`-timeout` 与 `-js-timeout` 是两回事**：前者管网络，后者管 JS 死循环。
  书源 JS 里做长轮询时先把 `-js-timeout` 调大。
- **`-debug` 不改变行为**，只多打日志；排查"某个字段为什么是空"时必开。

## 四、命令参数

### validate — 校验书源语法

```bash
./legado validate -dir ./testdata/sources                          # 离线静态检查
./legado validate -dir ./testdata/sources -bad                     # 只输出有问题的源
./legado validate -dir ./testdata/sources -online -source yumanhua -key 海贼
./legado validate -file ../sources/kantianxia.json -online -source 1   # 纯发现源：自动改走 explore
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-online` | `false` | 联网实测；不加只做静态检查 |
| `-key <关键字>` | 空 | 在线实测用的搜索词；空则用书源的 `ruleSearch.checkKeyWord`，再兜底 `我的` |
| `-bad` | `false` | 只打印有问题的源（离线模式） |
| `-source <key>` | 空 | **只在 `-online` 下生效**；不指定则逐个源都测一遍 |

离线模式**总是校验全部书源**（`-source` 被忽略），适合 CI/批量导入时把关。
输出格式与级别：

```
── 草榴社区-成人文学 <https://t66y.com/thread0806.php?fid=20>
   ! [WARN] searchUrl: 搜索地址为空（仅有发现，属发现型书源）
   ! [WARN] ruleSearch.name: 为空，无法获取书名
   ! [WARN] ruleSearch.bookUrl: 为空，无法获取详情页链接
── 漫画客 <http://yumanhua.com>
   ✓ 无问题

共 2 个书源，0 个存在错误
```

- `✗ ERROR`：一定是 bug——JS 语法错误、`##` 正则不合法、必填字段缺失
- `! WARN`：可能正常——例如纯发现源没有搜索规则
- `· INFO`：在线校验的通过信息（搜索命中几条、目录几章等）

在线实测通过与失败的输出对比：

```
── 漫画客 <http://yumanhua.com>
   · [INFO] search: 搜索成功，命中 9 条
   · [INFO] info: 《海贼王》作者:尾田荣一郎 目录:http://yumanhua.com/GZxNZae/
   · [INFO] toc: 目录解析成功，共 1201 章
   · [INFO] content: 正文解析成功(1045 字)，预览: <img src="https://p9-...
── VISTA看天下(纯发现源) <https://open3.vistastory.com>
   ! [WARN] searchUrl: 搜索地址为空（仅有发现，属发现型书源）
   · [INFO] explore: 发现成功，命中 18 条（搜不到搜索地址，用首个分类实测）
   · [INFO] info: 《当攀岩成为潮流》作者:VISTA看天下 目录:https://...
   · [INFO] toc: 目录解析成功，共 30 章
   · [INFO] content: 正文解析成功(1124 字)，预览: <img src="https://oss.ktx.cn/...
```

退出码：有 ERROR 时为 `2`（可据此卡流水线），否则 `0`。

`-online` 的实测路径：有 `searchUrl` 走搜索，没有则退回 `exploreUrl` 的第一个分类，
然后依次跑详情 → 目录 → 正文，任一步失败就停下并标出是哪一步。

### list — 列出书源（先跑这个再写 `-source`）

```bash
./legado list -dir ./testdata/sources
```

```
共加载 2 个书源
  1. 草榴社区-成人文学          [文本] https://t66y.com/thread0806.php?fid=20 t66y_book_source.json
  2. 漫画客                     [图片/漫画] http://yumanhua.com                    yumanhua_comic_source.json

-source 可用：上面的序号、名称、bookSourceUrl、域名，或最后一列的文件名
```

五列分别是：**序号 / 名称 / 类型 / bookSourceUrl / 来源文件**。
序号就是 `-source 1` 里的 1；最后一列可以直接当 `-source` 用。

### search — 搜索

```bash
./legado search -dir ./testdata/sources -source yumanhua -key 海贼 -page 1 -limit 20
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-key <关键字>` | 空（**必填**） | 搜索词；也可以作为位置参数写在最后 |
| `-page <页码>` | `1` | 翻页，代入 `searchUrl` 的 `{{page}}` |
| `-limit <条数>` | `20` | 最多打印多少条（只影响显示，不影响解析） |

输出：

```
搜索「海贼」命中 9 条
  1. 海贼王                                     http://yumanhua.com/GZxNZae/
  2. 航海王（海贼王）                             http://yumanhua.com/TRNETzf/
  3. 海贼王/航海王(推荐版)                        http://yumanhua.com/OMNCOGq/
```

> 书源是**纯发现源**（没有 `searchUrl`）时，这里会直接报错并提示改用 `explore`。

### explore — 发现

```bash
# 省略 -url：用 exploreUrl 的第一个分类
./legado explore -file ../sources/kantianxia.json -source VISTA

# 指定分类地址，{{page}} 会自动替换成页码
./legado explore -file ../sources/kantianxia.json -source 神奇漫画 -url "/comics?tag=全部&sort=latest&page={{page}}" -page 2
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-url <地址>` | 空 | 发现页地址，相对地址会拼书源 `bookSourceUrl`；空则用 `exploreUrl` 第一个分类 |
| `-page <页码>` | `1` | 代入 `{{page}}` / `{{page-1}}` |
| `-limit <条数>` | `20` | 最多打印条数 |

`exploreUrl` 支持三种写法，都能自动解析出分类（`-url` 不传时取第一个）：
JSON 数组 `[{"title":"分类","url":"/xx"}]`、单个 JSON 对象、按行 `分类名::/xx`。

### info — 书籍详情

```bash
./legado info -dir ./testdata/sources -source yumanhua -book http://yumanhua.com/GZxNZae/
./legado info -dir ./testdata/sources -source yumanhua http://yumanhua.com/GZxNZae/   # 位置参数亦可
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-book <url>` | 空 | 详情页地址；也可作为最后一个位置参数给 |
| `-name <书名>` | 空 | 手动书名：书源没有 `ruleBookInfo`（纯发现源）时必给，否则存盘文件叫 `untitled.txt` |
| `-author <作者>` | 空 | 同上，手动作者 |

### toc — 目录

```bash
./legado toc -dir ./testdata/sources -source yumanhua -book http://yumanhua.com/GZxNZae/ -limit 30
./legado toc -dir ./testdata/sources -source yumanhua -book http://yumanhua.com/GZxNZae/ -all
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-book <url>` | 空 | 详情页地址（可从位置参数取） |
| `-limit <条数>` | `30` | 最多打印多少章 |
| `-all` | `false` | 打印全部章节，覆盖 `-limit` |
| `-name` / `-author` | 空 | 同 `info` |

```
《海贼王》共 1201 章
    1. 番外1 草帽剧场:海的音乐会
    2. 第1话 ROMANCE DAWN
    3. 第2话 戴草帽的路飞
... 其余 1198 章未显示（用 -all 查看）
```

### content — 章节正文

```bash
./legado content -dir ./testdata/sources -source yumanhua -book http://yumanhua.com/GZxNZae/ -index 1 -len 500
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-book <url>` | 空 | 详情页地址（可从位置参数取） |
| `-index <下标>` | `0` | **目录下标，从 0 开始**（不是章节号，也不是 1 起始） |
| `-len <字数>` | `800` | 预览字数；`0` 表示不截断，全打出来 |
| `-name` / `-author` | 空 | 同 `info` |

正文按 Legado 的 `HtmlFormatter.formatKeepImg` 格式化：保留 `<img>`（相对地址补成绝对地址，
图片的 `,{...}` 请求选项原样保留），其余标签清除，段落缩进为全角空格。

### download — 下载整本

```bash
# 按详情页地址下载
./legado download -dir ./testdata/sources -source yumanhua -book http://yumanhua.com/GZxNZae/ -max 5 -out ./out

# 按关键字搜索后下载第一本
./legado download -dir ./testdata/sources -source yumanhua -key 海贼 -workers 8 -out ./out

# 强制按图片模式保存（普通小说站也能强制成 txt）
./legado download -dir ./testdata/sources -source yumanhua -book <url> -format images
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-book <url>` | 空 | 详情页地址；与 `-key` 二选一 |
| `-key <关键字>` | 空 | 没给 `-book` 时先搜索，取**第 1 条**结果下载 |
| `-out <目录>` | `./out` | 输出目录，不存在会创建 |
| `-format <格式>` | 自动 | `txt` / `md` / `images`；不给她按 `bookSourceType` 判断（`2` = 图片/漫画源 → images，其余 → txt） |
| `-workers <并发>` | `4` | 并发抓章节数；目标站限流时调小（1~2） |
| `-max <章数>` | `0` | 最多下载多少章，`0` = 全部 |
| `-start <下标>` | `0` | 起始章节下标（0 开始）；与 `-max` 组成窗口 `[start, start+max)` |
| `-name` / `-author` | 空 | 同 `info`，纯发现源必给 |

产物：

```
out/
├── 斗破苍穹.txt                 # 文本源：单文件，书名/作者在头部，章节以标题分段
└── 海贼王/                      # 漫画源：以书名为目录
    └── 0000_番外1 草帽剧场_海的音乐会/   # 每章一个子目录，按序编号
        ├── 001.jpeg
        └── 002.jpeg
```

## 五、常见任务 → 参数组合

| 我想… | 命令 |
|---|---|
| 看书源里都有什么源 | `list -dir ./sources` |
| 批量检查书源有没有语法错 | `validate -dir ./sources` |
| 检查单个源能不能真的跑通 | `validate -dir ./sources -online -source 2 -key 关键字` |
| 搜索某本书 | `search -dir ./sources -source 2 -key 书名` |
| 书源没有搜索，只能逛分类 | `explore -dir ./sources -source 2` |
| 看某本书有几章 | `toc -dir ./sources -source 2 -book <url>` |
| 试读第 10 章 | `content -dir ./sources -source 2 -book <url> -index 9 -len 2000` |
| 下载前 5 章试水 | `download -dir ./sources -source 2 -book <url> -max 5` |
| 下载整本漫画（慢一点更稳） | `download -dir ./sources -source 2 -book <url> -workers 2` |
| 排查解析为空 | 任意命令加 `-debug`，并配 `-js-timeout 60` |
| 临时不落盘 Cookie | 任意命令加 `-cookie=` |

---

# 作为 Go 库使用

```go
e, err := legado.New(legado.Config{
	SourceDir:  "../sources",
	CookieFile: "./cookies.json",
	CacheFile:  "./cache.json",
	JSTimeout:  30 * time.Second,
	Log:        func(msg string) { fmt.Println("[js]", msg) },
})
```

想和 CLI 共用同一份 `config.json`，直接读进来转换即可（`Normalize` 把 0 值补成默认）：

```go
import (
	legado "github.com/legado/legado-go"
	"github.com/legado/legado-go/pkg/config"
)

c, err := config.Load("config.json") // 不存在会返回 os.ErrNotExist
if err != nil {
	c = config.Default() // 没有配置就用内置默认
}
c.Normalize()
e, err := legado.New(legado.FromFileConfig(c, func(msg string) { log.Println(msg) }))
```

`config.Load` 保留未写字段的默认值（只写想改的项就行），`config.Validate(nil)`
做离线校验，传入 `sourceCheck` 回调还能顺带验证 `sourceDir` / `source` 是否可用
（CLI 的 `config check` 就是这么实现的）。

`Config` 字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `SourceDir` | `string` | 书源文件夹（与 `SourceFile` 二选一，`SourceFile` 优先） |
| `SourceFile` | `string` | 单个书源文件 |
| `CookieFile` | `string` | Cookie 落盘路径；**空 = 不落盘**（与 CLI 默认不同） |
| `CacheFile` | `string` | 缓存落盘路径；空 = 不落盘 |
| `UserAgent` | `string` | 覆盖默认 UA（书源 header 里的 UA 优先） |
| `HTTPTimeout` | `time.Duration` | HTTP 超时，`0` 用默认 30s |
| `JSTimeout` | `time.Duration` | 单段 JS 超时，`0` 用默认 30s |
| `Log` | `func(string)` | 日志回调（`java.log` 也走这里） |

`Engine` 方法第一个参数都是**选源关键字**，规则与 CLI 的 `-source` 完全一致：

```go
list, _ := e.Search("神奇漫画", "海贼", 1)          // 名称
list, _ := e.Search("2", "海贼", 1)                 // 序号
book := list[0].ToBook()
e.GetBookInfo("shenqimanhua.net", book)             // 域名
chapters, _ := e.GetChapterList("https://shenqimanhua.net", book) // 完整 URL
txt, _ := e.GetContent("kantianxia.json", book, chapters[0])      // 文件名
```

| 方法 | 说明 |
|---|---|
| `Find(key) *model.BookSource` | 只查选源结果，可先用它做存在性判断 |
| `Search(key, keyword string, page int)` | 搜索 |
| `Explore(key, url string, page int)` | 发现；`url` 空则用 `exploreUrl` 第一个分类 |
| `GetBookInfo(key, *Book)` | 详情（会就地补全 `book`） |
| `GetChapterList(key, *Book)` | 目录 |
| `GetContent(key, *Book, *BookChapter)` | 正文 |
| `Download(key, *Book, download.Options)` | 整本下载 |
| `ValidateAll()` / `ValidateOnline(key, keyword, items)` | 离线 / 在线校验 |
| `SaveCookies()` | 落盘（进程退出前调用） |

需要更底层的控制时直接用 `pkg/` 下的包：

```go
// 只做规则解析
ar := rule.New(src)
ar.SetContent(htmlStr, "https://example.com/list/")
ar.SetBook(book)
titles := ar.GetStringList("class.item@tag.a@text")

// 只发一个请求（自动带 Cookie、自动识别编码）
page := 1
resp, err := urlx.New(urlx.Options{
	Url:  "https://example.com/search?q={{key}}&page={{page}}",
	Key:  "海贼",
	Page: &page,
}).GetStrResponse()
```

完整可运行示例见 [`examples/basic/main.go`](examples/basic/main.go)。

# Cookie 自动管理

对应 Legado 的 `CookieStore` + `CookieManager`，全部自动，书源无需声明：

1. 响应带 `Set-Cookie` → 自动解析，按**二级域名**分桶保存（`yumanhua.com` 与 `www.yumanhua.com` 共用一桶）
2. 无 `Max-Age` / `Expires` 的存为**会话 cookie**，进程内有效
3. 下次请求同一域名 → 自动 `MergeCookies` 注入 `Cookie` 请求头（同名以新值为准）
4. 单域名 cookie 超过 4096 字节时随机丢弃部分，防止请求头超限（与 Legado 一致）
5. `e.SaveCookies()` / `-cookie` 指定的文件落盘为 JSON，下次启动自动加载

需要临时关掉自动携带时，直接清掉该域名的 Cookie，或单独操作 `store.Default()`：

```go
cs := store.Default()
cs.SetCookie("https://example.com/", "token=abc")  // 手动种
cs.GetCookie("https://example.com/")               // 读取
cs.RemoveCookie("https://example.com/")            // 清除
```

JS 里也可以用：`java.getCookie(url, key)` / `java.setCookie(url, cookie)` / `cookie.getCookie(url)` / `cookie.setCookie(...)`。

# 规则语法支持

完整说明见 [`docs/rule-syntax.md`](docs/rule-syntax.md)。速查：

| 写法 | 说明 |
|---|---|
| `class.item@tag.a@text` | 默认 JSoup/CSS，`@` 分层 |
| `@CSS:...` `@XPath:...` `@Json:...` | 强制指定模式 |
| `$.data.list[*].name` / `$..name` | JSONPath |
| `//div[@id='x']//a/text()` | XPath |
| `<js>...</js>` 或 `@js:...` | JS 模式，结果进 `result` |
| `##正则##替换##` | 替换，最多 4 段 |
| `规则1&&规则2` | 追加：两段结果拼接 |
| `规则1\|\|规则2` | 短路：前者为空才取后者 |
| `规则1%%规则2` | 交错合并列表 |
| `@put:{key: rule}` | 存变量，规则求值后写入 |
| `@get:{key}` | 取变量 |
| `{{expr}}` | JS 表达式内嵌到规则串 |
| `:正则` | allInOne，整体当一条正则 |
| `tag.li.0` `tag.li[-1]` `tag.li[0:3]` `tag.li[1,3]` | 索引（新式） |
| `tag.li.0` `tag.li!0` `tag.li.0:3` | 索引（旧式，`!` 为排除） |

规则中的 `$1` `$2` 引用上一步正则的分组。

# 与 Legado 的对应关系

| Legado (Kotlin) | legado-go |
|---|---|
| `model/analyzeRule/AnalyzeRule.kt` | `pkg/rule/analyze_rule.go` |
| `AnalyzeByJSoup.kt` / `AnalyzeByXPath.kt` / `AnalyzeByJSonPath.kt` / `AnalyzeByRegex.kt` | `pkg/rule/{jsoup,xpath,jsonpath,regex}.go` |
| `RuleAnalyzer.kt`（平衡切分） | `pkg/rule/splitter.go`、`pkg/rule/source_rule.go` |
| `AnalyzeUrl.kt` | `pkg/urlx/analyze_url.go` |
| `help/JsExtensions.kt` | `pkg/js/ext.go` |
| `help/http/CookieStore.kt` + `CookieManager.kt` | `pkg/store/cookie.go` |
| `model/webBook/*` | `pkg/webbook/webbook.go` |
| Rhino | goja（按书源池化 + `jsLib` 预编译共享 + 超时中断） |

# 已知限制

- **朗读/TTS、书签、阅读进度**等阅读器功能不在此项目范围内（只做数据侧）
- `java.webView` **无实现**，返回空串（服务端无浏览器）；若书源强依赖 WebView 取 cookie，会失败
- `java.t2s` / `java.s2t` 简繁转换是**原样返回**的占位实现
- `bookSourceType == 1`（音频源）未支持
- 以下规则字段**仅解析不执行**：`coverDecodeJs`、`ruleContent.imageDecode`、`ruleContent.webJs`、
  `ruleContent.sourceRegex`、`ruleContent.imageStyle`、`ruleContent.payAction`、`ruleToc.nextTocUrlJs`
- 并发章节抓取未做 `concurrentRate` 限速（Legado 的访问间隔控制未实现）
- `config.json` 是**标准 JSON**：不支持注释与尾逗号；程序只读不写（`config gen` 除外）

# 开发与测试

```bash
go build ./...
go vet ./...
go test ./...
go test -race ./...
gofmt -l .
```

测试覆盖：

- `pkg/rule/rule_test.go`：规则引擎单测（五种模式、新老索引、组合符、`@put/@get`、`{{}}`、`##` 替换、切分器、JSON 元素、文档示例）
- `pkg/webbook/webbook_test.go`：httptest 搭的假站点，跑通搜索 → Cookie 自动保存 → 详情 → 目录 → 需要 Cookie 的正文，以及 JS 扩展与变量
- `pkg/source/find_test.go`：`-source` 十级匹配（序号/URL/名称/文件名/域名/详情页 URL/子串/歧义/找不到）
- `pkg/util/html_test.go`：`HtmlFormat` / `FormatKeepImg` 与规则型 `<img src>`
- `pkg/download/download_test.go`：图片地址抽取
- `pkg/model/source_test.go`：`exploreUrl` 解析、UA 覆盖优先级
- `testdata/sources/`：两个真实书源（文本 + 漫画）作为回归输入

# 目录结构

```
legado-go/
├── README.md              本文件
├── docs/rule-syntax.md    规则语法与 JS API 参考
├── examples/basic/        可运行的 API 使用示例
├── legado.go              顶层 API（Engine / Config / FromFileConfig）
├── cmd/legado/
│   ├── main.go            CLI 命令与参数
│   └── configcmd.go       config gen / config check
├── pkg/
│   ├── util/              URL / HTML 实体与格式化 / 编码探测 / goquery 封装
│   ├── model/             书源与规则实体、Book / BookChapter、变量域
│   ├── store/             Cookie（二级域名+会话双桶）、Cache
│   ├── net/               HTTP Client（自动 Cookie / 编码 / 重试 / 代理）
│   ├── js/                goja 引擎 + JsExtensions
│   ├── rule/              切分器 / SourceRule / 五种模式 / AnalyzeRule
│   ├── urlx/              AnalyzeUrl
│   ├── webbook/           搜索·发现·详情·目录·正文
│   ├── source/            加载 / 选源 / 离线校验 / 在线校验
│   ├── config/            config.json 读写与校验（字段元数据、拼写建议）
│   └── download/          txt/md 导出 + 漫画下图
├── config.example.json    配置示例（拷成 config.json 即可用）
└── testdata/sources/      回归用真实书源
```

# 常见问题

**改了 config.json 却没生效**
按顺序查三件事：① 文件名是不是 `config.json`、键名大小写对不对（`legado config check` 会指出
`cookiefile` 这类拼写问题）；② 当前工作目录是不是放配置的那个目录（配置里的相对路径相对 cwd，
不是相对配置文件的目录）；③ 命令行是不是又显式给了同名参数——命令行优先级更高。
最快的排除法是 `-config=` 关掉配置再跑一次对比。

**怎么确认某次运行到底用了哪些默认值**
`legado <命令> -h` 打印的默认值就是"配置生效后"的值，例如 `-dir` 默认显示 `./testdata/sources`
说明配置里的 `sourceDir` 被读到了。

**想临时换一份配置 / 完全不用配置**
`-config ./prod.json` 换文件；`-config=` 关掉。两者都只影响本次运行。

**`-source` 提示"未找到书源"**
按报错里给出的清单逐项对：名称是否多打了空格/括号（中文全角括号很常见）、
文件是否真的被加载（先 `list` 看一眼）、`-dir` 里是否包含那个文件。
最稳的写法是直接用 `list` 输出第 1 列的**序号**：`-source 2`。

**`-source` 用文件名却选到了别的源**
一个文件里常有多个源，文件名只能定位到"文件"而不是"文件里的某一个"，
此时会打提示并取第一个。用序号或完整名称即可精确指定。

**搜索结果是 0 条**
先跑 `validate -file xxx.json -online -source xxx -key 关键字` 看断在哪一步。
常见原因：书源需要登录（`loginUrl`）、搜索页有反爬、`searchUrl` 里的 `{{key}}`
需要 URL 编码但书源没写 `java.encodeURI`。

**目录能拉到但正文是空的**
多为 `ruleContent.content` 依赖翻页，或正文在 iframe / JS 渲染里。
逐条试：`content -index 0 -len 2000 -debug`，看 JS 日志。

**漫画下载图片是 403**
说明图片需要 `Referer`。书源一般会写成
`<img src="{{$.pic}},{"headers":{"Referer":"..."}}">`，本实现会把 `,{...}` 原样保留，
下载时由 `AnalyzeUrl` 解析成请求头。

**书名是 `untitled`**
纯发现型书源（`ruleBookInfo` 为空）取不到书名，加 `-name`。

**JS 报 `timeout`**
`-js-timeout` 调大。也可能是书源在 JS 里做了长轮询或无限循环。

**每次运行都生成 `cookies.json` / `cache.json`**
这是 CLI 的默认行为（为了跨命令复用登录态）。不需要就加 `-cookie=` / `-cache=`；
文件里没有内容时不会写出空文件。
