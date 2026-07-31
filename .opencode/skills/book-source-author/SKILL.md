---
name: book-source-author
description: Use when writing, editing, debugging, or explaining Legado book sources (书源), book source rules, search/explore/detail/toc/content rules, rule syntax (@css @xpath @json @js @@ ## &&), URL variables ({{key}} {{page}} {{bookUrl}}), or BookSource JSON files. Also use when fixing a failing source or creating sources for shenqimanhua-like image/comic sites. Do NOT use for Android app code or the web UI module.
---

# Legado Book Source Authoring

Legado (开源阅读) is a rule-driven novel/manga reader. A "book source" (书源) is a JSON document describing how to scrape one website: which URLs to request and which rules extract data from the response.

## BookSource JSON shape

Full field reference: `app/src/main/java/io/legado/app/data/entities/BookSource.kt`. Key fields:

| Field | Type | Meaning |
|-------|------|---------|
| `bookSourceUrl` | String | Source website URL. **PrimaryKey, required.** |
| `bookSourceName` | String | Display name. **Required.** |
| `bookSourceType` | Int | `0`=text, `1`=audio, `2`=image (comic), `3`=file download site |
| `bookSourceGroup` | String | Comma-separated group names |
| `bookUrlPattern` | String | Regex to decide if a search result URL is a detail-page URL |
| `enabled` | Boolean | Whether search uses this source |
| `enabledExplore` | Boolean | Whether it appears in 发现/Discover |
| `jsLib` | String | Shared JS lib injected before every rule runs (or `{"name":"https://...js"}` to reuse downloaded files) |
| `enabledCookieJar` | Boolean | Auto-save `Set-Cookie` per request (needed for session/verification-code sites) |
| `concurrentRate` | String | Rate limit: `1000` (ms between requests) or `20/60000` (20 req per 60s) |
| `header` | String | HTTP headers as JSON, e.g. `{"User-Agent":"...","Referer":"..."}`. Keys are case-sensitive. `proxy` key supported: `{"proxy":"http://user:pass@host:port"}` or `{"proxy":"socks5://127.0.0.1:1080"}` |
| `loginUrl` | String | Login URL or JS implementing `login()` + buttons (see 登录UI rules) |
| `loginCheckJs` | String | JS to verify login; return result triggers re-request |
| `coverDecodeJs` | String | JS to decrypt cover bytes |
| `exploreUrl` | String | Discover URLs, newline-separated, format `标题::url` |
| `ruleSearch` | Object | Search page parsing rules |
| `ruleExplore` | Object | Discover page parsing rules (same shape as search) |
| `ruleBookInfo` | Object | Detail-page rules |
| `ruleToc` | Object | Table-of-contents rules |
| `ruleContent` | Object | Chapter-content rules |
| `ruleReview` | Object | Paragraph comments (currently disabled) |

`bookSourceName` and `bookSourceUrl` must be non-empty; the web API and import reject otherwise.

## Rule field reference

`SearchRule`/`ExploreRule`: `bookList`, `name`, `author`, `intro`, `kind`, `lastChapter`, `updateTime`, `coverUrl`, `bookUrl`, `wordCount`, `checkKeyWord`.

`BookInfoRule`: `init`, `name`, `author`, `intro`, `kind`, `lastChapter`, `updateTime`, `coverUrl`, `tocUrl`, `wordCount`, `canReName`, `downloadUrls`.

`TocRule`: `preUpdateJs`, `chapterList`, `chapterName`, `chapterUrl`, `formatJs`, `isVolume`, `isVip`, `isPay`, `updateTime`, `nextTocUrl`.

`ContentRule`: `content`, `title`, `nextContentUrl`, `webJs`, `sourceRegex`, `replaceRegex`, `imageStyle`, `imageDecode`, `payAction`.

Entity classes: `app/src/main/java/io/legado/app/data/entities/rule/`.

## Rule syntax

Inside any rule field you can use selector modes. The mode is auto-detected, or forced with a prefix:

| Prefix | Mode | Notes |
|--------|------|-------|
| (none) / `@@` | CSS (jsoup) | `@@` is the explicit form |
| `@XPath:` or leading `/` | XPath | |
| `@Json:` or leading `$.` | JSONPath | |
| `@js:` , `<js>...</js>` , or `{{...}}` | JavaScript | |
| `:regex` | Regex | Only valid for `bookList`/`chapterList` (all-in-one mode) |

Operator precedence/combining:

- `&&` — try next rule if the previous returned empty (fallback chain).
- `||` — in list extraction, if previous returned empty keep collecting into the same list item.
- `%%` — similar fallback separator for lists.
- `##` — regex replacement suffix: `@css:div@text##广告##` replaces matches of regex `广告` with ``. `###` = replace only the first match, and returns the matched group.

Inline element modifiers inside a rule (jsoup mode):

- `@text` — element own text
- `@textNodes` — all text nodes
- `@ownText` — own text excluding children
- `@html` — inner HTML
- `@outerHtml` — outer HTML
- `@href` / `@src` — attribute values
- `@all` — concatenate all matched
- `@css:` — nested CSS selector
- `@xpath:` — nested XPath
- `@json:` — nested JSONPath
- `@js:` — nested JS
- `@content` — the raw JSON content of a JSON node
- `@get:` — read a variable stored earlier via `@put:`

Extraction order flows left to right; for a field like `name` write one rule or a `&&` chain.

## URL variables

In `searchUrl`, `exploreUrl`, `ruleToc.nextTocUrl`, etc., `{{...}}` is executed as JS; the common variables:

- `{{key}}` — search keyword (search & discover)
- `{{page}}` — page number (starts at 1)
- `{{baseUrl}}` — current request base URL
- `{{bookUrl}}` — detail page URL
- `{{tocUrl}}` — TOC page URL
- `{{chapterUrl}}` — chapter URL
- `{{nextChapterUrl}}` — next chapter URL
- `{{title}}` — current chapter title
- `{{name}}`, `{{author}}`, `{{kind}}` — book metadata

`searchUrl` example: `/search?query={{key}}&page={{page}}`. For GET the URL is used as-is; for POST include the JSON config as the second part:
`https://site/search,{"method":"POST","body":"keyword={{key}}&page={{page}}"}`.

URLs may also carry a trailing `,{"js":"..."}` block that runs at request time, e.g. `https://www.baidu.com,{"js":"java.headerMap.put('x','y')"}`.

Discover URLs: newline separated `标题::url`, e.g. `最新::/comics?sort=latest`.

## JavaScript environment

Engine is Rhino (ES5-ish; no `const` in loops — use `var`). Available globals:

| Variable | Meaning |
|----------|---------|
| `java` | The AnalyzeRule/AnalyzeUrl extension object (see below) |
| `result` | Output of the previous rule step |
| `baseUrl` | Current URL |
| `src` | Raw response source |
| `book` | Current Book object (`.name`, `.author`, `.intro`, `.coverUrl`, `.origin`...) |
| `chapter` | Current chapter (`.url`, `.title`, `.index`, `.bookUrl`...) |
| `source` | Current source (`.getKey()`, `.getVariable()`/`.setVariable()`, login-header helpers, `put`/`get` storage) |
| `cookie` | `cookie.getCookie(url)`, `getKey(url,key)`, `setCookie(url,cookie)` |
| `cache` | `cache.put(key,value,saveTime)`, `get(key)`, `delete(key)`, `getFromMemory`/`putMemory` |

Useful `java.*` functions (full list in `app/src/main/java/io/legado/app/help/JsExtensions.kt`):

- `java.getString(rule, content)` / `java.getStringList(rule, content)` — run a rule string against content
- `java.setContent(content, baseUrl)` — change what subsequent rules parse
- `java.getElement(rule)` / `java.getElements(rule)`
- `java.get(key)` / `java.put(key, value)` — per-book variables
- `java.ajax(url)` → String; `java.connect(url)` → StrResponse (`.body()`, `.code()`, `.headers()`); `java.post(url, body, headers)`; `java.get(url, headers)`
- `java.webView(html, url, js)` — run a real WebView, return `js` result
- `java.webViewGetSource(html, url, js, regex)` — grab resource URLs from a rendered page
- `java.log(msg)` / `java.logType(v)` — debug logging
- `java.encodeURI(str)`, `java.base64Encode/Decode`, `java.strToBytes/bytesToStr`, `java.md5Encode`, `java.createSymmetricCrypto(transformation, key, iv).decrypt(data)`
- `java.toURL(url, baseUrl)` — resolve relative URLs
- `java.importScript(url)` — load and `eval` an external JS file
- `java.t2s(s)` / `java.s2t(s)` — simplified/traditional conversion

JS can return HTML fragments (e.g. `<a href="...">章名</a>`) which then continue through subsequent rules — a common pattern for `chapterList` when data lives in JSON/`__NEXT_DATA__` rather than DOM.

## Common patterns

- **JSON-in-page**: use `@js:` to `JSON.parse(result)` a `__NEXT_DATA__`/`self.__next_f` blob, walk it, and emit `<a href>` elements; then `chapterName: @text`, `chapterUrl: @href`.
- **Image/comic sources** (`bookSourceType: 2`): `ruleContent.content` should emit `<img src="...">` HTML, set `imageStyle` to `FULL`, and may include per-image headers via `<img src="url,{&quot;headers&quot;:{...}}">`.
- **Check-keyword**: `ruleSearch.checkKeyWord` overrides the search-check keyword.
- **Login**: fill `loginUrl` (URL or JS with `function login()`), optional `loginCheckJs`. In login JS, `source.getLoginInfoMap()` reads 登录UI field values.
- **Redirected search**: use `java.connect`/`java.post` and `source.put('surl', ...)` on page 1, then reuse `{{page}}` afterwards (see `ruleHelp.md`).

## Debugging workflow

1. Save the source via the app UI, the web API, or import the JSON file.
2. Use the in-app debugger (书源管理 → 调试) per-stage:
   - 调试搜索 → keyword (uses `searchUrl` + `ruleSearch`)
   - 调试发现 → `标题::url`
   - 调试详情页 → detail URL
   - 调试目录页 → prefix `++`
   - 调试正文页 → prefix `--`
3. Or automate via the WebSocket debug endpoint: `ws://<ip>:1235/bookSourceDebug` with message `{"key":"search keyword","tag":"<bookSourceUrl>"}` — requires Web 服务 enabled in settings.
4. Check `java.log` output in the app logcat / debug panel.

## Repository references

- Example working source: `shenqimanhua_source.json` (image/comic site: explore+search+bookInfo+toc via embedded JSON, content via `@js` img extraction).
- Architecture analysis: `book_source_analysis.txt`.
- Rule docs: `app/src/main/assets/web/help/md/ruleHelp.md` and `jsHelp.md`.
- Rule engine: `app/src/main/java/io/legado/app/model/analyzeRule/`.
- Rule entity shapes: `app/src/main/java/io/legado/app/data/entities/rule/`.
- Web source editor (Vue): `modules/web/src/config/bookSourceEditConfig.ts`.
