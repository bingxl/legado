# 进度 · M2 书源规则引擎（rules）

> 独占目录：`packages/legado_core/lib/src/rules/`、`lib/src/util/`、`test/rules/`。
> 状态：**完成**。`dart test test/rules` → 184 例全绿；本目录 `dart analyze` 零 issue。

## 一、交付物

| 文件 | 作用 |
| --- | --- |
| `lib/src/rules/source_rules.dart` | 书源规则值对象：`SearchRule` / `BookInfoRule` / `TocRule` / `ContentRule` / `ExploreRule` / `UrlRule` / `UrlOption`，全部 `fromJson` + `toJson` |
| `lib/src/rules/rule_splitter.dart` | 按嵌套深度/引号切分规则（`&&`/`||`/`%%`/`@`），`{{}}` 与 `{$.x}` 内嵌替换 |
| `lib/src/rules/html_rule.dart` | CSS 选择引擎（jsoup 语义）+ `@text/@html/...` 取值 + jsoup 文本归一化 + HTML4 反转义 |
| `lib/src/rules/xpath_rule.dart` | XPath 子集（在 `package:html` 的 DOM 上自研） |
| `lib/src/rules/json_path_rule.dart` | JSONPath 子集（语义对齐 Go 版） |
| `lib/src/rules/regex_rule.dart` | 多级正则 + `##regex##repl` 替换（含 `$1`） |
| `lib/src/rules/rule.dart` | `RuleContext` / `SourceRule`（模式识别、`@put`/`@get`/`{{}}`、`##`）、`splitSourceRule` |
| `lib/src/rules/analyze_rule.dart` | 统一入口 `AnalyzeRule`（`getString` / `getStringList` / `getElements` / `getElement` / `getStringEx`） |
| `lib/src/rules/url_rule.dart` | `UrlRuleAnalyzer`（对齐 `AnalyzeUrl.kt`）：`<js>`/`@js:`、`{{key}}`、`<1,2,3>` 分页、`,{...}` 选项、query/form 编码 |
| `lib/src/util/url.dart` | `isAbsUrl` / `getBaseUrl` / `getAbsoluteUrl` / `joinUrl`（对齐 `java.net.URL(base, spec)`，不做百分号转义） |
| `lib/src/rules/rules.dart` | barrel（门面接入口，**没有**改 `lib/legado_core.dart`） |

测试：`test/rules/{html,xpath,json_path,regex,url,analyze,source_rules}_test.dart`，
共 184 例，含 `_fixtures.dart` 的真实结构 HTML/JSON 与 `FakeJsEngine`。

## 二、语法覆盖表

### CSS（`html_rule.dart`）

| 语法 | 状态 | 说明 |
| --- | --- | --- |
| `tag` `#id` `.class` `*` `tag.class` | ✅ | `ul#list li.book` |
| 后代 / `>` / `+` / `~` / 逗号并集 | ✅ | 并集按文档顺序去重 |
| `[attr]` `[= ~= |= ^= $= *= !=]`，裸值 | ✅ | `a[href^=/1]`（值为 `/`、数字开头）也支持 |
| `@text` `@ownText` `@textNodes` `@html` `@all` `@attr` `@abs:attr` | ✅ | `@text` 做 jsoup 空白归一化；`@html` 去 script/style |
| 位置 `[0]` `[-1]` `[a,b]` `[s:e]` `[s:e:step]` `[!0]` | ✅ | 区间含两端，支持反向 `[-1:0]` |
| 旧写法 `.0` `!0:1` `.-1` | ✅ | 只认**规则末尾**的索引（与 Kotlin 一致） |
| `class./tag./id./text./children` 前缀 | ✅ | `chapterUrl: "href"` 这类单段属性名 |
| `:eq :lt :gt :first :last :even :odd :nth-child(n)` | ✅ | `:eq` 等按**兄弟下标**（jsoup `elementSiblingIndex`） |
| `:contains :containsOwn :matches :has :not :empty :root` | ✅ | `:not` 支持选择器列表 |
| `&&`（拼接）/ `\|\|`（首个非空）/ `%%`（交错） | ✅ | `%%` 以第 1 段长度为界 |
| `@CSS:` 前缀 | ✅ | 强制 CSS（此时 `[0]` 按属性选择器解析，与 jsoup 相同） |

**未做**：`:nth-child(2n+1)` 等 An+B 语法、`:nth-of-type`、伪元素、命名空间 `svg|a`、`@media`。
原因：真实书源几乎不用；`package:html` 也不支持 An+B。

### XPath（`xpath_rule.dart`）

| 语法 | 状态 |
| --- | --- |
| `//` `/` `.` `..` `*` `@attr` `/@attr` | ✅ |
| `[n]` `[last()]` `[position()>n]` `[@a]` `[@a='v']` | ✅ |
| `[contains()]` `[starts-with()]` `[text()='v']` `[normalize-space()]` | ✅ |
| `string-length()` `concat()` `substring-before/after()` `not()` `count()` `ends-with()` `floor()/ceiling()` | ✅ |
| `and` / `or` / `(` `)` / 数值比较 | ✅ |
| `//a \|\| //b`、`&&`、`%%` | ✅ |

**未做**：`following-sibling`、`ancestor`、`preceding` 等轴，`translate()`、`sum()`、位置函数 `[position()=last()-1]` 的算术表达式（`last()-1` 这类），变量 `$x`，`|` 并集运算符。
原因：低频；实现成本高，且真实书源基本只用上述子集。

### JSONPath（`json_path_rule.dart`）

| 语法 | 状态 |
| --- | --- |
| `$.a.b` `$['a']` `$[0]` `$[-1]` `$[*]` `$.*` | ✅ |
| `$..a` `$..*` 递归下降 | ✅ |
| 切片 `[a:b:c]`、联合 `[0,2]` | ✅ |
| 过滤 `[?(@.k)]` `[?(@.k=='v')]` `[?(@.k>n)]` `[?(@.k=~/re/)]` | ✅ |
| `&&` `\|\|` `!` 括号、省略 `?` 的 `[@.k=~/re/]` | ✅ |
| 自动补 `$`；`.[?()]` → `$..[?()]`（递归下降）；`$.[*]` → `$[*]` | ✅ |
| 聚合 `.length() .min() .max() .sum() .avg()` | ✅ |
| 内嵌规则 `{$.x}` | ✅ |

**未做**：`$..[*]` 与函数组合的边界（如 `$..book.length()`）、脚本表达式 `[(...)]`、`@.length` 在过滤外的用法。

### 正则 / URL / 统一入口

| 能力 | 状态 |
| --- | --- |
| `##regex##repl`、`##regex##`（删除）、`###`（仅首个）、`$1`/`${1}` | ✅ |
| Java 正则兼容：`\A` `\Z`、内联 `(?i)` | ✅ |
| 多级正则 `&&`（前级缩范围、末级取分组） | ✅ |
| `<js>` / `@js:` / `@put:` / `@get:` / `{{}}` | ✅ |
| URL 绝对化、`{{key}}`、`<1,2,3>`、`,{...}` 选项、query/form 编码、宽松 JSON | ✅ |
| 模式自动识别（`@css:` `@@` `@XPath:` `@Json:` `$.` `//` / 内容是否 JSON） | ✅ |

**未做**：URL 的 `charset` 实际转码（gbk → 需要 `gbk_codec`，留给 net 层，`AnalyzedUrl.charset` 已透出）、
`webView` / `webJs` 的实际渲染（执行环境没有 WebView）、`proxy` / `serverID` 的落地。

## 三、留给谁 / 怎么接

1. **service 层（下一阶段）**：
   - 把 `domain.BookSource` 转成 `source_rules.dart` 的值对象（字段名一致，直接 `fromJson` 也行）。
   - 调 `AnalyzeRule(ctx).getString(rule, content)`；`RuleContext` 用 `SimpleRuleContext` 或自己实现（只要求 4 个 getter）。
   - 分页/搜索 URL 用 `UrlRuleAnalyzer(ctx, key:, page:).analyze()`，返回的 `AnalyzedUrl` 直接喂 net 层。
2. **门面**：`lib/src/rules/rules.dart` 已经收好了所有公开类型，主控在 `lib/legado_core.dart` 里
   `export 'src/rules/rules.dart';` 即可（我没改门面文件）。
3. **JS agent**：我只依赖 `JsEngine` 接口（`eval(script, {bindings})`），没有改 `lib/src/js/`。
   绑定约定见 `RuleContext.evalJs`：`result` / `baseUrl` / `source` / 全部变量。
4. **net agent**：`lib/src/util/url.dart` 是我写的（契约里 net 可读不可写）。需要新增 URL 工具请找我，
   或放到 `lib/src/net/` 下自成一份。

## 四、踩的坑（给后来人）

1. **`package:html` 的 `querySelectorAll` 不能直接用**：
   csslib 遇到 `:eq()` 直接抛 `UnimplementedError`，遇到 `a[href^=/1]`（裸值）解析失败。
   所以自己在 DOM 上写了选择器引擎（`_parseComplex`/`_matchesCompound`）。
2. **jsoup 的 `:eq(n)` 不是「结果集下标」**，是「兄弟节点下标」。照结果集下标实现会全错位。
3. **`Element.text` 不是 jsoup 的 `text()`**：`package:html` 只拼接文本，不做块级补空格、
   不折叠空白、不排除 `<script>`。必须自己实现 `_collectText` + `_normalizeWhitespace`。
4. **JSONPath 补 `$` 是补 `$.` 而不是 `$`**：`.[?(@.title)]` → `$..[?(@.title)]`（递归下降）。
   如果先补 `$` 再做 `$.[` → `$[` 归一化，会变成只在根数组上过滤，规则静默返回 0 条。
5. **索引只认规则末尾**：`li[0] a@text` 在 Kotlin 里也是**不生效**的（`[0]` 被当成属性选择器）。
   正确写法是 `li[0]@text`，或在链中用 `li:eq(0) a@text`。写测试时被这一点坑过。
6. **`{{}}` 出现在规则中间会把模式改成 `Regex`**（Kotlin/Go 都这样），此时返回值就是展开后的字面串，
   不会再走选择器。所以 `{{}}` 只适合「整条规则就是一个模板」的写法；要拼接请用 `<js>`。
   这条我保留了一致行为，没有"修"，因为改了对真实书源是另一种破坏。
7. **Dart 的 `String.replaceAll` 不认 `$1`**：所有带分组的替换必须 `replaceAllMapped`。
   （`lenientJson` 里清多余逗号时就栽过一次，`$1` 被当字面量插进 JSON。）
8. **`dart:convert` 的 `jsonDecode` 不宽松**：书源里单引号、裸键、多余逗号很常见，
   统一走 `source_rules.dart` 的 `lenientJson`。
9. **URL 不能交给 `Uri.resolve`**：它会把 `{}`、中文做百分号转义，书源模板会被改坏；
   `java.net.URL(base, spec)` 只做路径归一化，所以手写了 `joinUrl`/`normalizeUrlPath`。

## 五、已知缺陷

1. **XML 书源**（`<?xml` 的 RSS/ATOM）走 HTML5 解析：标签名会被小写化，`<item>`/`<title>` 大小写不敏感。
   自闭合标签与 CDATA 基本可用，但严格 XML 语义（命名空间、大小写敏感）不保证。
   如果后续要支持，建议在 `parseHtmlDocument` 里换 `package:xml` 并适配一层 DOM 接口。
2. **`getStringList` 对 JSON 对象的字符串化**用 JSON 编码（`{"a":1}`），Java 是 `{a=1}`。
   只影响"直接把对象当字符串输出"的调试场景，列表解析都用 `getElements`。
3. **`AnalyzeRule` 不做 NativeObject 分支**（JS 返回对象按 key 直接取值那套）：
   那是 Rhino 类型特有行为，Dart 侧 JS 引擎的对象就是 `Map`，走正常 JSONPath 即可。
4. **过滤表达式与 `@.length` 的边界**：`[?(@.length)]` 会把字符串/数组长度当值，jayway 不是这个语义。
5. **`%%` 只支持两段以上的同类型组合**，`&&`/`||`/`%%` 混用时按"最先出现的分隔符"切分（与 Kotlin 一致，不是错误）。
6. **`getString` 的 HTML 反转义只覆盖常见实体**（`&amp;` `&nbsp;` `&hellip;` 等 16 个 + 全部数字实体），
   不是完整的 HTML4 命名实体表（约 250 个）。
