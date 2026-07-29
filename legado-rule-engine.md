# Legado 书源规则引擎详解

## 目录

1. [规则解析器选择机制](#1-规则解析器选择机制)
2. [规则前缀语法速查](#2-规则前缀语法速查)
3. [内联表达式（@put / @get / \{\{js\}\}）](#3-内联表达式)
4. [规则组合器（&& / || / %%）](#4-规则组合器)
5. [流水线数据流与 result 类型](#5-流水线数据流与-result-类型)
6. [各 Pipeline 详解](#6-各-pipeline-详解)
7. [NativeObject 特殊处理](#7-nativeobject-特殊处理)
8. [正则替换（##）](#8-正则替换)
9. [URL 选项（webView / header / method）](#9-url-选项)
10. [重要边界情况](#10-重要边界情况)

---

## 1. 规则解析器选择机制

### 1.1 核心文件

`app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt`

### 1.2 SourceRule 初始化流程

当 `splitSourceRule(ruleStr)` 或 `splitSourceRule(ruleStr, allInOne)` 被调用时，创建 `SourceRule` 实例。构造函数按以下优先级决定 **mode**（解析器类型）：

```kotlin
// 优先级顺序（从高到低）：
rule = when {
    mode == Mode.Js || mode == Mode.Regex -> ruleStr                // ① 已由 splitSourceRule 标记为 Js 或 Regex
    ruleStr.startsWith("@CSS:", true)   -> { mode = Mode.Default; ruleStr }   // ② 显式 CSS
    ruleStr.startsWith("@@")            -> { mode = Mode.Default; ruleStr.substring(2) } // ③ 显式 CSS（@@ 是 @@ 的别名）
    ruleStr.startsWith("@XPath:", true) -> { mode = Mode.XPath;  ruleStr.substring(7) }  // ④ 显式 XPath
    ruleStr.startsWith("@Json:", true)  -> { mode = Mode.Json;   ruleStr.substring(6) }  // ⑤ 显式 Json
    isJSON || ruleStr.startsWith("$.") || ruleStr.startsWith("$[")  // ⑥ 自动 Json
        -> { mode = Mode.Json; ruleStr }
    ruleStr.startsWith("/")             -> { mode = Mode.XPath;  ruleStr }     // ⑦ 自动 XPath（以 / 开头）
    else                                -> ruleStr                              // ⑧ 默认 Jsoup/CSS
}
```

> **重要**：`isJSON` 标志在 `setContent()` 时根据 `content.toString().isJson()` 设置。如果 body 是 JSON 字符串，`isJSON = true`，所有规则默认走 Json 模式（除非显式指定其他前缀）。

### 1.3 splitSourceRule 的 allInOne 参数

| 调用场景 | allInOne | 备注 |
|---------|----------|------|
| `getElements(ruleStr)` | `true` | list 类规则 |
| `getElement(ruleStr)` | `true` | 单元素规则（如 `init`） |
| `getString(ruleStr)` | `false` | 文本规则 |
| `getStringList(ruleStr)` | `false` | 文本列表规则 |

当 `allInOne = true` 且 `ruleStr` 以 `:` 开头时，整个规则被视为 **Regex** 模式（`:regexPattern`）。

### 1.4 JS 规则的两种写法

JS_PATTERN 定义 (`AppPattern.kt:7`)：
```regex
<js>([\w\W]*?)</js>|@js:([\w\W]*)
```

在 `splitSourceRule` 中，匹配到的 JS 块被分割为独立的 `SourceRule(mode = Mode.Js)`，剩余部分按普通规则处理。这意味着一个 ruleStr 可以混合 JS 和其他规则：

```
// 示例：CSS + JS 混合
"div.title@text && <js>result.trim()</js>"
```

### 1.5 五个解析器模式

| 模式 | 枚举值 | 解析器类 | 输出类型 |
|------|--------|---------|---------|
| Jsoup/CSS | `Mode.Default` | `AnalyzeByJSoup` | `Element`, `Elements`, `String`, `List<String>` |
| XPath | `Mode.XPath` | `AnalyzeByXPath` | `JXNode`, `List<JXNode>`, `String`, `List<String>` |
| JsonPath | `Mode.Json` | `AnalyzeByJSonPath` | `LinkedHashMap`, `ArrayList`, `String`, `List<String>` |
| JavaScript | `Mode.Js` | `evalJS()` via Rhino | `Any?` (NativeObject, NativeArray, String, Number, Boolean, null) |
| Regex | `Mode.Regex` | `AnalyzeByRegex` | `List<String>` (match groups), `List<List<String>>` |

---

## 2. 规则前缀语法速查

| 前缀 | 解析器 | 示例 |
|------|--------|------|
| *(无前缀, 内容为 HTML)* | Jsoup/CSS | `div.title@text` |
| *(无前缀, 内容为 JSON)* | JsonPath | `$.data.list` |
| `@CSS:` | Jsoup/CSS (显式) | `@CSS:div.title@text` |
| `@@` | Jsoup/CSS (显式) | `@@div.title@text` |
| `@XPath:` | XPath (显式) | `@XPath://div/@data-id` |
| `/` 开头 | XPath (自动) | `//div[@class='title']/text()` |
| `@Json:` | JsonPath (显式) | `@Json:$.data.title` |
| `$.` 开头 | JsonPath (自动) | `$.data.title` |
| `$[` 开头 | JsonPath (自动) | `$[0].title` |
| `<js>...</js>` | JavaScript | `<js>result.title</js>` |
| `@js:` | JavaScript | `@js:result.title` |
| `:` 开头 (仅 allInOne) | Regex | `:(\w+)` |
| 包含 `##` | 本模式 + Regex替换 | `text##old##new` |
| 包含 `{{...}}` | 内联 JS 表达式 | `{{result.title + '!'}}` |
| `@put:{...}` | 变量存储 | `@put:{"key":"val"}div.text` |
| `@get:{...}` | 变量读取 | `@get:{key}` |
| 包含 `$1`, `$2` | Regex 分组引用 | `text$1##前缀\s+` |

---

## 3. 内联表达式

### 3.1 `{{...}}` — 内联 JavaScript

在 `SourceRule.makeUpRule()` 中，`{{...}}` 内的内容被提取并执行：

```kotlin
regType == jsRuleType -> {
    if (isRule(ruleParam[index])) {
        // @开头 / $.开头 / $[开头 / //开头 → 作为规则递归解析
        val ruleList = getOrCreateSingleSourceRule(ruleParam[index])
        getString(ruleList).let { infoVal.insert(0, it) }
    } else {
        // 否则作为 JS 执行
        val jsEval: Any? = evalJS(ruleParam[index], result)
        // result 是当前处理的元素（Any?）
    }
}
```

**示例**：
```
// 执行 JS，result 指向当前元素
{{result.title + '-' + result.id}}

// 内部再次调用解析规则（@, $., // 开头）
{{@XPath://div/@data-id}}
{{$.title}}
```

### 3.2 `@put:{...}` — 变量存储

`@put:{"key":"value"}` 将 key-value 存入变量空间。value 本身也是一个规则字符串，会先被 `getString` 解析再存储。

```kotlin
// @put:{"key1":"rule1"}div.text
// 先 getString("rule1") 得到实际值，保存到 key1，然后再执行 div.text
```

变量存储优先级：`chapter.putVariable` → `book.putVariable` → `ruleData.putVariable` → `source.put`

### 3.3 `@get:{...}` — 变量读取

`@get:{key}` 从变量空间读取之前存储的值。读取优先级：

```kotlin
chapter?.getVariable(key)
    ?: book?.getVariable(key)
    ?: ruleData?.getVariable(key)
    ?: source?.get(key)
    ?: ""
```

特殊预定义变量：
| 变量名 | 来源 | 说明 |
|--------|------|------|
| `bookName` | book | 书名 |
| `title` | chapter | 当前章节标题 |

---

## 4. 规则组合器

在各解析器的 `getStringList` / `getElements` / `getString` 中，规则字符串会通过 `RuleAnalyzer.splitRule()` 按 `&&`、`||`、`%%` 分割。

| 组合器 | 含义 | 行为 |
|--------|------|------|
| `&&` | AND | 合并所有规则的结果 |
| `\|\|` | OR | 取第一个非空结果后停止 |
| `%%` | ZIP | 交错合并（类似 zip），逐个索引交替取各规则的值 |

**示例**：
```
// AND：合并 title 和 author
div.title@text && div.author@text

// OR：title 规则为空则用 h1
div.title@text || h1@text

// %%：交错合并（通常用于表格数据）
td.name@text %% td.value@text
// 结果: [name1, value1, name2, value2, ...]
```

---

## 5. 流水线数据流与 result 类型

### 5.1 核心概念

整个引擎围绕 `AnalyzeRule` 实例展开，其核心状态：

```kotlin
class AnalyzeRule {
    private var content: Any? = null    // 当前处理的内容
    private var isJSON: Boolean = false // content.toString() 是否为 JSON
    private var isRegex: Boolean = false // 是否已进入正则模式
}
```

### 5.2 数据流生命周期

每一次 HTTP 请求完成后：

```
HTTP 响应 body (String)
    → analyzeRule.setContent(body)
    → isJSON = body.toString().isJson()
    
    [getElements(listRule)]       → List<Any> (元素列表)
        遍历每个元素:
            analyzeRule.setContent(item)  → content 变为单个元素
            [getString(nameRule)]         → String
            [getString(urlRule)]           → String (或 URL)
```

### 5.3 `setContent` 的 `isJSON` 判定影响

`isJSON` 在 `SourceRule` 构造时影响 mode 选择（规则 ⑥）。但 `SourceRule` 是在 `splitSourceRule` 调用时创建的，此时 `isJSON` 已经确定。

**关键陷阱**：当从 `getElements` 返回的列表遍历元素时：
- 如果列表来自 JsonPath 解析 JSON 数组 → 每个元素是 `LinkedHashMap`
- `LinkedHashMap.toString()` 返回 `{key=val}` 格式（不是合法 JSON）
- 调用 `analyzeRule.setContent(linkedHashMap)` 后 `isJSON = false`
- 但 `SourceRule` 的 mode 在之前的 `splitSourceRule` 时已经确定，不受影响
- 所以规则 `$.url` 在 `SourceRule` 中的 mode 是 `Mode.Json`，会正确走 JsonPath 路线

### 5.4 result 类型总表

| 来源 | 解析器 | `result` 类型 | 传给下个字段时的 `setContent` 类型 |
|------|--------|--------------|----------------------------------|
| HTML body | — | `String` (初始) | `String` |
| `getElements` (Default) | Jsoup | `Elements` → 每个 `Element` | `Element` |
| `getElements` (XPath) | XPath | `List<JXNode>` → 每个 `JXNode` | `JXNode` 或 `Element` |
| `getElements` (Json) | JsonPath | `ArrayList<LinkedHashMap>` → 每个 `LinkedHashMap` | `LinkedHashMap` |
| `getElements` (Regex) | Regex | `List<List<String>>` | `List<String>` (单个匹配的 groups) |
| `getElements` (JS) | Rhino | `NativeArray` → 每个 `NativeObject` / `String` / `Number` | `NativeObject` / `String` / `Number` |
| `getElement` (Default) | Jsoup | `Elements` (第一个) | `Element` |
| `getString` | 任意 | `String` | — |
| `getStringList` | 任意 | `List<String>` | — |

---

## 6. 各 Pipeline 详解

### 6.1 Search / Explore 搜索发现流 (BookList.kt)

```
入口: analyzeBookList(bookSource, ruleData, analyzeUrl, baseUrl, body, ...)

1. analyzeRule.setContent(body)           // body = HTML 或 JSON String
2. analyzeRule.getElements(bookListRule.bookList)  → List<Any> (书籍列表元素)

遍历每个 item:
  3. analyzeRule.setContent(item)          // content = Element / JXNode / LinkedHashMap / NativeObject
  4. analyzeRule.getString(bookListRule.name)        → String (书名)
  5. analyzeRule.getString(bookListRule.author)       → String (作者)
  6. analyzeRule.getStringList(bookListRule.kind)     → List<String>? (分类)
  7. analyzeRule.getString(bookListRule.wordCount)    → String (字数)
  8. analyzeRule.getString(bookListRule.lastChapter)  → String (最新章节)
  9. analyzeRule.getString(bookListRule.intro)        → String (简介)
 10. analyzeRule.getString(bookListRule.coverUrl)     → String (封面)
 11. analyzeRule.getString(bookListRule.bookUrl, isUrl=true) → String (详情页链接)

生成 SearchBook 对象
```

**特殊行为**：
- `bookUrlPattern` 匹配时，直接按详情页解析单本书
- 规则支持 `-` 前缀反转列表，`+` 前缀无条件

### 6.2 BookInfo 详情页流 (BookInfo.kt)

```
入口: analyzeBookInfo(book, body, analyzeRule, bookSource, baseUrl, redirectUrl, canReName)

1. analyzeRule.setContent(body)           // body = HTML String

2. [可选] infoRule.init 规则:
   analyzeRule.getElement(it)  → 提取子元素
   analyzeRule.setContent(提取的元素)  // content 被替换为子元素

3. analyzeRule.getString(infoRule.name)          → String (书名)
4. analyzeRule.getString(infoRule.author)         → String (作者)
5. analyzeRule.getStringList(infoRule.kind)       → List<String>? (分类)
6. analyzeRule.getString(infoRule.wordCount)      → String (字数)
7. analyzeRule.getString(infoRule.lastChapter)    → String (最新章节)
8. analyzeRule.getString(infoRule.intro)          → String (简介)
9. analyzeRule.getString(infoRule.coverUrl)       → String (封面)
10. analyzeRule.getString(infoRule.tocUrl, isUrl=true)  → String (目录链接)
  // 或下载链接:
    analyzeRule.getStringList(infoRule.downloadUrls, isUrl=true) → List<String>?
```

**init 规则的特殊性**：
```kotlin
// BookInfo.kt:62
analyzeRule.setContent(analyzeRule.getElement(it))
// getElement 提取的元素直接替换 content
// 这意味着后续所有规则都在这个子元素范围内执行
// init 通常是 CSS/XPath 选择器，提取主要的内容容器
```

### 6.3 ChapterList 目录流 (BookChapterList.kt)

```
入口: analyzeChapterList(bookSource, book, baseUrl, redirectUrl, body)

1. analyzeRule.setContent(body)                       // body = HTML 或 JSON String
2. analyzeRule.getElements(tocRule.chapterList)       → List<Any> (章节元素列表)

   // 提前解析子字段规则（SourceRule 列表已确定 mode）
3. nameRule  = analyzeRule.splitSourceRule(tocRule.chapterName)
4. urlRule   = analyzeRule.splitSourceRule(tocRule.chapterUrl)
5. vipRule   = analyzeRule.splitSourceRule(tocRule.isVip)
6. payRule   = analyzeRule.splitSourceRule(tocRule.isPay)
7. upTimeRule= analyzeRule.splitSourceRule(tocRule.updateTime)
8. isVolumeRule = analyzeRule.splitSourceRule(tocRule.isVolume)

遍历每个 item:
  9. analyzeRule.setContent(item)                     // content = 单个元素
 10. analyzeRule.setChapter(bookChapter)
 11. analyzeRule.getString(nameRule)                  → String (章节名)
 12. analyzeRule.getString(urlRule)                    → String (章节链接)
 13. analyzeRule.getString(upTimeRule)                 → String (更新时间)
 14. analyzeRule.getString(isVolumeRule)               → String (是否一卷)

   // 如果 url 为空，则使用 baseUrl 替代（或 title+index 如果是一卷）
   // 如果 title 为空，跳过此条目

生成 BookChapter 列表，支持分页（nextTocUrl）
```

### 6.4 Content 正文流 (BookContent.kt)

```
入口: analyzeContent(bookSource, book, bookChapter, baseUrl, redirectUrl, body, nextChapterUrl)

1. analyzeRule.setContent(body)                       // body = HTML String
2. [可选] contentRule.title → 更新章节标题
3. analyzeRule.getString(contentRule.content, unescape=false)  → String (正文)
   // HtmlFormatter.formatKeepImg(content, rUrl) 格式化

   // 支持分页
4. contentRule.nextContentUrl → 获取下一页链接

5. contentRule.replaceRegex → 全文替换

生成正文 String，保存到数据库
```

**正文规则的特殊性**：
- `unescape=false` 不自动反转义 HTML 实体
- 之后显式调用 `HtmlFormatter.formatKeepImg` 和 `StringEscapeUtils.unescapeHtml4`
- 返回给用户的是纯文本/HTML 字符串

### 6.5 RSS 流 (RssParserByRule.kt)

```
入口: parseXML(sortName, sortUrl, redirectUrl, body, rssSource, ruleData)

1. analyzeRule.setContent(body)
2. analyzeRule.getElements(rssSource.ruleArticles)  → List<Any>

遍历每个 item:
  3. analyzeRule.setContent(item)
  4. analyzeRule.getString(ruleTitle)           → String
  5. analyzeRule.getString(rulePubDate)         → String
  6. analyzeRule.getString(ruleDescription)     → String
  7. analyzeRule.getString(ruleImage, isUrl=true) → String
  8. analyzeRule.getString(ruleLink)            → String

生成 RssArticle 列表
```

---

## 7. NativeObject 特殊处理

### 7.1 触发条件

当通过 JS 执行（`evalJS`）返回 `NativeObject`（Rhino JavaScript 对象）时，该对象会成为 `content`。后续 `getString` 和 `getStringList` 会走 **特殊分支**。

### 7.2 getString 中的 NativeObject 分支

```kotlin
// AnalyzeRule.kt:273-285
if (result is NativeObject) {
    val sourceRule = ruleList.first()          // 只取第一个 SourceRule！
    putRule(sourceRule.putMap)
    sourceRule.makeUpRule(result)
    result = if (sourceRule.getParamSize() > 1) {
        sourceRule.rule                        // 有 {{}} 等，用替换后的 rule
    } else {
        result[sourceRule.rule]?.toString()    // 直接访问 JS 属性！
    }?.let {
        replaceRegex(it, sourceRule)
    }
}
```

**关键行为**：
1. **只使用 `ruleList.first()`** — 列表中的后续规则被忽略
2. **直接属性访问**：`nativeObject[rule.rule]` — 规则字符串直接作为 JS 属性名
3. **`rule.rule` 就是原始规则字符串**，不做解析器路由

**对 rule 格式的影响**：
| 规则字符串 | NativeObject 上的行为 | 结果 |
|-----------|----------------------|------|
| `title` | `obj["title"]` | ✅ 返回 title 值 |
| `url` | `obj["url"]` | ✅ 返回 url 值 |
| `$.title` | `obj["$.title"]` | ❌ 返回 undefined（属性名含 `$.`） |
| `$.url` | `obj["$.url"]` | ❌ 返回 undefined |
| `@Json:$.title` | `obj["@Json:$.title"]` | ❌ 属性名完全错误 |

**结论**：当 content 是 NativeObject 时，**必须使用裸键名**（如 `title`、`url`），不能加 `$.` 或 `@Json:` 前缀。

### 7.3 getStringList 中的 NativeObject 分支

```kotlin
// AnalyzeRule.kt:179-198
if (result is NativeObject) {
    val sourceRule = ruleList.first()          // 同样只取第一个
    putRule(sourceRule.putMap)
    sourceRule.makeUpRule(result)
    result = if (sourceRule.getParamSize() > 1) {
        sourceRule.rule
    } else {
        result[sourceRule.rule]                // 直接取值，不转 toString
    }
    // 如果是 List 则对每个元素做 replaceRegex
}
```

**与 getString 的差异**：不做 `.toString()`，直接返回原始值。

### 7.4 何时会产生 NativeObject？

1. `chapterList` 规则返回 JS 数组 `[{...}, {...}]` → `NativeArray`，每个元素是 `NativeObject`
2. `bookList` 规则使用 `<js>...</js>` 或 `@js:` 返回 JavaScript 对象数组
3. `content` 规则使用 JS 返回对象

### 7.5 判定流程图

```
当前 content 类型
├── NativeObject → 走特殊分支（直接属性访问，只用 ruleList.first()）
├── Element (Jsoup) → Jsoup 解析器
├── JXNode (XPath) → XPath 或 Jsoup 解析器（取决于 mode）
├── LinkedHashMap (JsonPath) → JsonPath 解析器
├── String → 根据 isJSON 和 rule 前缀决定解析器
└── 其他 → toString() 后当作字符串处理
```

---

## 8. 正则替换

### 8.1 规则格式

`rule##match##replace[##]`

| 部分 | 含义 | 必填 |
|------|------|------|
| `rule` | 实际的提取规则 | 是 |
| `match` | 正则匹配模式 | 是 |
| `replace` | 替换文本 | 是 |
| 第三个 `##` | 标记为只替换第一个匹配 | 否 |

### 8.2 处理流程

```kotlin
// SourceRule.makeUpRule() 中：
val ruleStrS = rule.split("##")
rule = ruleStrS[0].trim()          // 实际规则
if (ruleStrS.size > 1) {
    replaceRegex = ruleStrS[1]     // match
}
if (ruleStrS.size > 2) {
    replacement = ruleStrS[2]      // replace
}
if (ruleStrS.size > 3) {
    replaceFirst = true            // 仅替换第一个
}
```

### 8.3 `$1`, `$2` 分组引用

如果规则中包含 `$1`, `$2` 等，`SourceRule.init` 中的 `splitRegex` 会将其标记为 regex 模式：

```kotlin
// 规则 "text$1##前缀(.+)"
// 先按 ## 拆分后得到 "text$1" 和 "前缀(.+)"
// "text$1" 中的 $1 触发 Regex 模式
// makeUpRule 时 $1 从 result（List<String>）中取第 1 组
```

---

## 9. URL 选项

URL 字符串可在末尾附加 `,` 加 JSON 选项：

```
https://example.com/api,{"method":"POST","body":"...","webView":true}
```

支持的选项：
| 选项 | 类型 | 说明 |
|------|------|------|
| `method` | String | `GET` / `POST` |
| `body` | String | POST 请求体 |
| `contentType` | String | 请求 Content-Type |
| `webView` | Boolean | 是否使用 WebView 加载 |
| `sourceRegex` | String | WebView 嗅探正则 |
| `headers` | Map | 自定义请求头 |
| `weight` | String | WebView 加载等待的 dom 选择器 |

### 9.1 WebView 模式

当 `webView: true` 时，使用 `BackstageWebView` 加载页面：

1. 创建不可见 WebView
2. 设置 User-Agent 为当前源配置
3. 添加请求头
4. 加载 URL
5. 等待页面渲染完成
6. 执行 `webJs`（如果有）
7. 如果有 `sourceRegex`，嗅探匹配的资源 URL
8. 返回页面 HTML 或嗅探到的 URL

适用于：
- JavaScript 渲染的 SPA（如 Next.js）
- 需要执行 JS 才能看到内容的页面
- 需要获取动态加载的数据

---

## 10. 重要边界情况

### 10.1 URL 为空时的降级

```kotlin
// BookChapterList.kt:230-243
if (bookChapter.url.isEmpty()) {
    if (bookChapter.isVolume) {
        bookChapter.url = bookChapter.title + index  // 用标题替代
    } else {
        bookChapter.url = baseUrl                    // 用 baseUrl 替代
    }
}
```

### 10.2 title 为空时跳过

```kotlin
// BookChapterList.kt:245
if (bookChapter.title.isNotEmpty()) {
    // 只有 title 非空才添加到列表
}
```

### 10.3 getString 的 isUrl 参数

当 `isUrl = true` 时：
- 结果为空 → 返回 `baseUrl`
- 结果非空 → `NetworkUtils.getAbsoluteURL(redirectUrl, str)` 转为绝对 URL

使用场景：`bookUrl`、`tocUrl`、`coverUrl`、`nextContentUrl`、`nextTocUrl` 等链接字段。

### 10.4 isJSON 的隐式修改

`setContent()` 每次调用都重新计算 `isJSON`。如果在遍历元素时调用 `setContent(item)`：
- `item` 是 `Element` → `isJSON = false`（Node 类型硬编码为 false）
- `item` 是 `LinkedHashMap` → `isJSON = false`（toString 不是合法 JSON）
- `item` 是 `String` → `isJSON = string.isJson()`

### 10.5 Regex 模式的自动触发

以下情况会自动切换到 Regex 模式：
1. `allInOne = true` 且规则以 `:` 开头
2. `splitSourceRule` 中 `isRegex` 已被设为 true（从上一个 Regex 模式延续）
3. `SourceRule.init` 在 `splitPutRule` 之后发现 `evalPattern`（`@get:{...}` 或 `{{...}}`）且不在首位/前面没有 `##`
4. `splitRegex` 中发现 `$1`, `$2` 等分组引用

### 10.6 列表反转

规则以 `-` 前缀开头表示反转；以 `+` 前缀开头表示不反转（即使 `reverseToc` 为 true）。

### 10.7 变量覆盖警告

```kotlin
if (key == "bookName" || key == "title") {
    Debug.log("≡变量 $key 在特定情况下会被覆盖，建议使用其他键名")
}
```

`bookName` 和 `title` 有特殊含义，会被 book/chapter 覆盖，不建议用于 `@put`。

### 10.8 evalJS 的 bindings

每次 JS 执行时绑定的变量：
```javascript
// 所有 JS 规则中可用的变量：
java        // AnalyzeRule 实例（this）
cookie      // CookieStore 单例
cache       // CacheManager 单例
source      // 当前书源（BaseSource）
book        // 当前书籍（BaseBook，可能为 null）
result      // 当前处理的内容（即 for 循环中的 item）
baseUrl     // 当前基础 URL
chapter     // 当前章节（可能为 null）
title       // 当前章节标题（chapter?.title）
src         // 原始 content（未经过 setContent 修改）
nextChapterUrl  // 下一章节 URL（仅正文流）
rssArticle  // 当前 RSS 文章（RSS 流）
```
