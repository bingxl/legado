# 规则语法参考

本文说明 legado-go 支持的规则语法，与 Legado 源码
`app/src/main/java/io/legado/app/model/analyzeRule/` 的行为对齐。

## 1. 一条规则是怎么被解析的

给定规则串（例如 `class.item@tag.a@text##<[^>]+>##`），内部处理顺序是：

```
规则串
  │
  ├─ 1. 剥离 @put:{...}            → 存进变量表（值仍是"规则"，求值后才写入）
  │
  ├─ 2. 判定模式                    → XPath / Json / Default / Js / Regex
  │
  ├─ 3. 按 ## 拆替换               → 最多 4 段：规则 ## 正则 ## 替换 ## 仅替换首个(true)
  │
  ├─ 4. 按 @get:{key} 与 {{expr}} 切段
  │       └─ 命中时，除非此前已是 Js/Regex，否则整条降级为 Regex 模式
  │
  └─ 5. 逐段求值 → 段间结果是"上一层的内容"
```

第 4 步值得强调：**规则里只要写了 `{{...}}` 或 `@get:{...}`，整条规则的模式会变成 Regex**，
也就是默认走"把结果当字符串做正则"的路径，而不是继续当 CSS 选择器。这是 Legado 的行为，
所以 `{{}}` 通常写在 URL 规则或 JS 里，而不是混在分层 CSS 规则中。

## 2. 模式判定

按以下顺序**首个命中者生效**（忽略大小写）：

| 顺序 | 前缀 / 条件 | 模式 | 说明 |
|---|---|---|---|
| 1 | `@css:` | Default | 强制 JSoup/CSS |
| 2 | `@@` | Default | 同上，Legado 的旧写法（前缀会被剥掉） |
| 3 | `@xpath:` | XPath | |
| 4 | `@json:` | Json | |
| 5 | 内容本身是 JSON，或规则以 `$.` / `$[` 开头 | Json | |
| 6 | 规则以 `/` 开头 | XPath | |
| 7 | 其它 | Default | JSoup/CSS |

`@js:` 和 `<js>...</js>` 在更早的步骤就被识别为 JS，不进这张表。

```jsoup
class.item@tag.a@text       // Default
@CSS:class.item@tag.a@text  // Default（显式）
@XPath://div[@id="list"]//a/text()
@Json:$.data.list[*].name
$.data.list[*].name
//div[@id="list"]//a
```

## 3. Default 模式（JSoup/CSS）

`@` 分层，每层是"元素选择器 + 可选取值后缀"。

### 3.1 选择器部分

| 写法 | 含义 |
|---|---|
| `tag.div` | 标签名 `div` |
| `class.item` | class 包含 `item` |
| `id.list` | id 为 `list` |
| `text.正文` | `ownText` 包含"正文"的节点 |
| `children` | 当前节点的全部直接子元素 |
| `*` | 同上（等价 children） |
| `div.a.b#c` | 组合选择器，直接当 CSS 选择器用 |

判断顺序是：先看有没有 `.`/`#` 组成的选择器形态，命中则走 goquery；
否则按 `children` / `class` / `tag` / `id` / `text` 分支处理。

### 3.2 取值后缀

层级末尾可以用 `@text` 之类的后缀，也可以直接写裸词：

| 后缀 | 结果 |
|---|---|
| `@text` | `Element.text()`（含子孙文本） |
| `@ownText` | `Element.ownText()`（仅直接文本节点） |
| `@textNodes` | 拼接所有文本节点 |
| `@html` | `Element.html()`（内层 HTML） |
| `@all` | `Element.outerHtml()` |
| `@href` / `@src` / `@title` … | 任意属性名，取 `attr(...)` |

```jsoup
class.book-list@tag.li@tag.a@text          // 列表里的书名
class.info@tag.img@src                     // 封面地址
id.content@html                            // 正文原始 HTML
id.content@all                             // 正文连同容器标签
```

默认（不带后缀）取 `text`。取到的值会做 HTML 实体反转义。

**单段规则的特殊约定**：整条规则只有一段、且不像选择器时，这一段会被当作**属性名**
（对齐 legado 的 `getResultLast` 默认分支）。所以下面三种写法都成立：

```jsonc
"chapterName": "text",     // 取值关键字 → Element.text()
"chapterUrl":  "href",     // 裸属性名   → Element.attr("href")
"chapterUrl":  "a@href"    // 常规写法
```

判断「像不像选择器」的依据：含空白/`[]`/`!`/`>`、以 `.`/`#` 开头，或以
`class.` / `tag.` / `id.` / `text.` / `ownText.` / `children` 开头 → 当选择器；
其余裸词（`href`、`title`、`src`、`data-src`）→ 当属性名。

### 3.3 索引语法

索引直接写在**层**的末尾，紧跟选择器；`@` 之后的取值后缀不算在索引里。

**新式（推荐）**——`[...]`：

| 写法 | 含义 |
|---|---|
| `tag.li[0]` | 第 1 个 |
| `tag.li[-1]` | 最后一个 |
| `tag.li[0:3]` | 下标 0 到 3（含） |
| `tag.li[1,3,5]` | 指定几个下标 |
| `tag.li[3:-2:-10]` | 从 3 到 -2，步长 10 |
| `tag.li[!0,1]` | 排除 0、1（取其余） |

`[!...]` 是"排除"语义，等价于旧的 `!` 分隔符。

> 注意：`a[href=x]` 这种属性选择器不会被误判为索引——解析失败时会整体当 CSS 选择器交给 goquery。

**旧式**——`.N` / `!N` / `:N`：

```
class.item.0        // 第 0 个（. 包含）
class.item.-1       // 最后一个（负数从尾部数）
class.item!0        // 排除第 0 个
class.item.0:3      // 0 到 3
```

旧式写法在规则中仍大量存在，两种都支持，但**不要混用**在同一层。

### 3.4 组合符

规则在**顶层**按 `&&` / `||` / `%%` 切分（括号内、引号内不切），一条规则只按最先命中的一种组合符切：

| 组合符 | 语义 |
|---|---|
| `规则A&&规则B` | **追加**：A 的结果在前，B 的结果在后，直接拼接 |
| `规则A\|\|规则B` | **短路**：A 有结果就用 A，A 为空才取 B |
| `规则A%%规则B` | **交错**：A₁ B₁ A₂ B₂ … |

```jsoup
// 追加：两个选择器的结果按顺序合起来
class.hot@tag.a@text&&class.new@tag.a@text

// 短路：主标题取不到才用副标题
class.title@text||class.subtitle@text

// 交错：书名与作者交替排列
class.item@tag.a.0@text%%class.item@tag.span.1@text
```

> **常见误解**：`&&` 不是"缩小范围"。要先定位容器再取里面的条目，用 `@` 分层而不是 `&&`：
>
> ```jsoup
> id.list@tag.li@tag.a@text     // 正确：先找 #list，再找其中的 li
> id.list&&tag.li@tag.a@text    // 错误：两段各自在整页上跑，结果相加
> ```
>
> 这也意味着 `A&&B` 在 `GetString` 下会得到 `"A结果\nB结果"`（多条结果用换行拼接），
> 而不是只留一条。

## 4. Json 模式（JSONPath）

`$.` / `$[` 开头或内容为 JSON 时自动进入。

| 写法 | 含义 |
|---|---|
| `$.data.name` | 取字段 |
| `$..name` | 递归查找 |
| `$.list[*].title` | 取数组每项 |
| `$.list[0].title` | 第 1 项 |
| `$.list[?(@.id>10)]` | 过滤 |

JSON 里若含字符串化的内嵌 JSON（常见于 SSR 页面），可以连续取：
`$.props.pageProps.bookList[*]`。

`{$.xxx}` 形式可以嵌到规则串中做拼接，例如封面：
`$.cover` 是相对路径时写 `https://h.com/{$.cover}`——不过通常更推荐在 `coverUrl` 里直接写完整 JSONPath，交给 `isUrl` 参数补全。

## 5. XPath 模式

`/` 开头或 `@xpath:` 前缀。使用 `antchfx/htmlquery`，支持标准 XPath 1.0：

```xpath
//div[@id="list"]/ul/li
//a[contains(@class,"title")]/@href
//div[@class="content"]/text()
string(//span[@class="count"])
```

解析前会做一次 **HTML 修补**：裸 `<tr>` / `<td>` 会被补上 `<table><tbody>` 包裹，
否则 htmlquery 会因标签嵌套不合法而丢掉表格节点（Legado 同样处理）。

## 6. Regex 模式与 `##` 替换

`##` 最多 4 段：

```
规则 ## 查找正则 ## 替换内容 ## true
```

第 4 段为 `true` 时只替换第一个匹配。`$1` `$2` 引用分组。

```jsoup
class.title@text##(.*?)最新章节##$1
id.content@html##<br\s*/?>##\n##
class.time@text##\d{4}-\d{2}-\d{2}##              // 第 3 段为空 = 删除匹配
```

注意 Go 用 RE2，**不支持反向引用与前瞻断言**。若书源用到了 `(?=...)` / `(?!...)`，
本实现会做兼容处理的地方（如 `<img>` 解析）已改为非正则实现；纯规则里的前瞻会编译失败并报错。

`:正则` 前缀是 allInOne 语法，把整条规则当一条正则作用于当前字符串，返回全部分组：

```
:编号(\w+)结束
```

## 7. JS 模式

两种写法等价：

```
<js>result.split("\n").filter(s => s.length > 10).join("\n")</js>
@js:java.ajax(baseUrl + "/api/list?page=" + page)
```

JS 中可用的全局变量见第 9 节。`<js>` 内部可以正常使用 `<`、`>`、`&&` 等字符，
规则解析器会先剥离 JS 块再处理剩余部分。

`@js:` 的 JS 里可以直接 return 一个值；也可以用 `result` 引用上一个模式的结果：

```js
// 上一段是 CSS 提取的 HTML，这里做二次处理
let doc = result;
JSON.parse(doc).data.map(x => x.title).join(",")
```

返回值类型决定后续行为：

- 返回字符串 → 按字符串处理，可继续被 `##` 替换
- 返回数组 → `GetStringList` 会逐项转字符串
- 返回 **JS 对象**（`NativeObject`）→ 后续规则的"键值直接访问"分支生效，
  即 `chapterName: "name"` 会直接从对象里取 `name` 字段（这是漫画/JSON 源写目录的常用手法）
- 返回 jsoup 元素 / 元素数组 → 后续规则可以继续用 CSS 解析

### JS 里的 `result.select(...)`

`select()` 返回的是模拟 jsoup `Elements` 的对象：**既是数组**（可下标、有 `length`），
又带 `Elements` 的方法，所以下列写法都能直接跑（书源里很常见）：

```js
result.select('td.tal').text()      // 各元素文本，空格拼接
result.select('td.tal').size()      // 元素个数
result.select('h3 a').attr('href')  // 第一个元素的属性
result.select('a').get(0).text()    // 等价于 result.select('a')[0].text()
result.select('a').first().text()
result.select('a').last().text()
result.select('a').text()           // 元素对象本身也有 select/text/attr
```

单元素对象（`ElementWrap`）同样提供 `select` / `text` / `ownText` / `html` / `outerHtml` /
`attr` / `tagName` / `className` / `id` / `parent` / `children` / `next` / `textNodes` / `data`。

## 8. 变量：`@put` / `@get` / `java.put`

### `@put`

```jsonc
"bookList": "class.item@tag.li@tag.a@text@put:{title: \"h3@text\", author: \"p.author@text\"}"
```

`@put` 的值是**规则**，不是字面量：解析这条规则时，会先对每个 put 项求值，再写入变量表。

### `@get`

```jsonc
"tocUrl": "/book/{{@get:{bookId}}}/chapters"
```

### `java.put` / `java.get`

JS 里读写同一份变量表：

```js
java.put("bookId", book.bookUrl.match(/\/(\d+)/)[1]);
java.get("bookId")
```

### 变量作用域与优先级

读取顺序：**chapter → book → ruleData → source → 兜底 vars**

`source` 级变量按 `bookSourceUrl` 隔离，同一进程跑多个书源不会互相污染。
值长度 ≥ 10000 字符时会被转到"大变量"存储，避免把整章正文塞进 V8 绑定。

## 9. JS 注入清单

### 全局变量

| 变量 | 内容 |
|---|---|
| `source` | 当前书源对象（`.bookSourceUrl` `.bookSourceName` `.getKey()` …） |
| `book` | 当前书籍（`.name` `.author` `.bookUrl` `.variable` …） |
| `chapter` | 当前章节（`.title` `.url` `.index` …） |
| `title` | 章节标题；无 chapter 时为书名 |
| `result` | 上一段规则的结果（字符串 / 数组 / 对象 / 元素） |
| `baseUrl` | 书源 `bookSourceUrl` |
| `src` | 当前内容的原始形态（HTML 字符串或节点） |
| `nextChapterUrl` | 正文翻页的下一页地址 |
| `key` | 搜索关键字 |
| `page` | 当前页码 |
| `java` | 见下 |
| `cookie` | `.get(url)` `.getCookie(url)` `.getKey(url,key)` `.set(url,cookie)` `.setCookie(...)` `.removeCookie(url)` |
| `cache` | `.get(key)` `.put(key,value)` `.delete(key)` |
| `md5(s)` | 快捷 MD5 |
| `console` | `.log()` |

### `java` 对象

**网络**

| 方法 | 说明 |
|---|---|
| `java.ajax(url)` | GET，返回字符串；`url` 可以是完整 URL 规则（含 `,{...}` 选项与 JS） |
| `java.ajaxAll(urls)` | 并发拉取，返回字符串数组 |
| `java.connect(url)` | 返回 `{body, headers, url}` |
| `java.get(url, headers?)` | 同 ajax |
| `java.post(url, body, headers?)` | POST |
| `java.head(url)` | HEAD，返回响应头字符串 |

**编码 / 摘要**

`base64Decode(s, flags?)` `base64Encode(s, flags?)` `md5Encode(s)` `md5Encode16(s)`
`hexEncodeToString(bytes)` `hexDecodeToString(s)` `strToBytes(s)` `bytesToStr(b)`
`encodeURI(s)` `decodeURI(s)` `htmlFormat(html)` `t2s(s)` `s2t(s)`

**字符串**

`substring(s, start, end)`（负数从尾部算） `replace(pattern, replacement, input, isRegex?)`
`split(str, sep)` `trim(s)`

**时间**

`timeFormat(time, format)` `timeFormatUTC(time, format)`

**变量**

`put(k,v)` `get(k)` `putVar(k,v)` `getVar(k,v)` `getString(k)`

> `java.put` 写入的变量，后续规则可直接用 `@get:{k}` 读取。
> `java.getString(k)` 在本实现中是"读变量"的别名（Legado 无此方法），等价 `java.get(k)`。

**Cookie**

`getCookie(url)` `setCookie(url, cookie)` `removeCookie(url)`

**文件 / 缓存**

`getFile(path)` `readFile(path)` `readTxtFile(path)` `deleteFile(path)`
`unzipFile(zip, path)` `unArchiveFile(...)` `getZipStringContent(zip, path)`
`downloadFile(url)` `cacheFile(url, cacheTime?)` `importScript(path)`

**其它**

`log(msg)` `logType(type, msg)` `toast(msg)` `longToast(msg)`
`randomUUID()` `androidId()` `getWebViewUA()`
`webView(html)` `startBrowser(url)` `openUrl(url)` `getSource()` `toNumChapter(title)`

> `webView` 在服务端**无实现**，返回空串。依赖 WebView 拿 cookie 的书源会失败。

## 10. URL 规则

`searchUrl` / `exploreUrl` / `tocUrl` 里的地址不是纯 URL，而是"URL 规则"：

```
基础 URL ,(可选) {选项 JSON}
```

示例：

```jsonc
"searchUrl": "/search?q={{key}}&page={{page}},{\"method\":\"POST\",\"body\":\"keyword={{key}}&page={{page}}\",\"charset\":\"gbk\"}"
"exploreUrl": "/comics?tag=全部&page={{page}}"
```

### 支持的选项

| 键 | 类型 | 说明 |
|---|---|---|
| `method` | string | `GET`（默认）/ `POST` |
| `headers` | object | 自定义请求头，会与书源 `header` 合并 |
| `body` | string | POST 请求体；GET 时拼到 query |
| `charset` | string | 响应编码，如 `gbk`；不填自动探测 |
| `retry` | number | 重试次数 |
| `type` | string | 响应类型提示 |
| `webView` | bool | 需要 WebView（本实现忽略） |
| `js` | string | 对响应再做一次 JS 处理 |

GET 的 query 与 POST 的 form 会自动按 `?`/`&`/`=` 判定是否已编码，避免二次编码。

### 特殊语法

| 语法 | 说明 |
|---|---|
| `{{key}}` | 搜索关键字 |
| `{{page}}` | 当前页码 |
| `{{page-1}}` | 页码运算（任意 JS 表达式均可） |
| `<1,2,3>` | 分页列表，展开成多个 URL 依次请求 |
| 以 `<js>` 开头 | 整个 URL 由 JS 生成 |
| `@js:` | 同上 |
| `{{@get:{k}}}` | 引用变量 |

## 11. 字段级规则速查

| 规则字段 | 允许的语法 |
|---|---|
| `ruleSearch.bookList` / `ruleExplore.bookList` / `ruleToc.chapterList` | 元素列表规则（CSS/XPath/JSON/JS），返回元素集合 |
| `name` `author` `kind` `lastChapter` `intro` `coverUrl` `wordCount` | 字符串规则，作用于**每一项元素** |
| `bookUrl` `chapterUrl` `tocUrl` | 上述 + 会自动补全为绝对地址 |
| `ruleBookInfo.init` | 详情页初始化 JS，`result` 为详情页内容 |
| `ruleToc.formatJs` | 目录后处理 JS，可改 `result`（数组） |
| `ruleToc.preUpdateJs` | 更新目录前的 JS |
| `ruleContent.content` | 正文规则，结果按 `FormatKeepImg` 格式化（保留 `<img>`） |
| `ruleContent.nextContentUrl` | 正文翻页，会串行抓取并拼接 |
| `ruleContent.replaceRegex` | 正文后处理，`##正则##替换##` |
| `ruleContent.imageDecode` | 图片地址解码 JS —— **未实现**（仅解析字段） |
| `bookUrlPattern` | 详情页 URL 特征，常用于让"搜索结果直接是详情页"的源跳过列表解析 |
| `jsLib` | 书源级 JS 库，预编译后所有规则共享同一作用域 |

未实现（只参与校验，执行时忽略）：`coverDecodeJs`、`ruleContent.webJs`、`ruleContent.sourceRegex`、
`ruleContent.imageStyle`、`ruleContent.payAction`、`ruleToc.nextTocUrlJs`（`nextTocUrl` 本身支持）。

`bookUrlPattern` 命中时，`bookList` 规则会被跳过，直接把搜索页当详情页处理——这是很多
单页源（如漫画站）的关键写法。

## 12. 写规则时的常见坑

1. **`{{}}` 会改变模式**：一条规则里出现 `{{}}`，整条会降级为 Regex。想保留 CSS 分层，把
   动态部分放到 URL 规则或 JS 里。

2. **`@` 分层与 `[href=x]` 冲突**：`a[href*="/book/"]` 里没有 `@`，安全；但
   `div@a[0]` 的 `[0]` 会被当索引而不是属性选择器。要选属性请写 `@CSS:` 强制。

3. **`&&` 不是"与"也不是"串联"**：`a&&b` 表示 a、b 各自独立执行后结果追加。要"在前者结果里找"
   用 `@` 分层（`a@b`）；要表达"同时满足两个条件"直接写进选择器（`div.item.active`）。

4. **XPath 的 `text()` 返回多段**：用 `GetStringList` 拿，`GetString` 只取第一段。

5. **JSON 源别忘 `$`**：`data.list` 在 JSON 模式下会被当字面键名，要写 `$.data.list`。

6. **封面相对路径**：`coverUrl` 会自动补全为绝对地址，不用自己拼 `baseUrl`。若设了
   `bookUrlPattern` 之外的 `redirectUrl`，补全基于实际响应 URL。

7. **`<js>` 里不要写 `</js>`**：字符串里出现会被提前截断，用 `<\/js>` 转义。
