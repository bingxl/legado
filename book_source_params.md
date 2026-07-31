# Legado Book Source Injected Parameters Inventory

All variables/parameters injected into book source rules and the JS execution context, with source locations.

## 1. URL variables (`{{...}}` / `@js:` in `searchUrl`/`exploreUrl`/`nextTocUrl` etc.)

Injected in `AnalyzeUrl.evalJS` — `app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt:348-371`

| Variable | Value |
|---|---|
| `java` | the AnalyzeUrl instance (JsExtensions) |
| `baseUrl` | current request base URL |
| `cookie` | CookieStore |
| `cache` | CacheManager |
| `page` | page number |
| `key` | search keyword |
| `speakText` | TTS text (audio/TTS) |
| `speakSpeed` | TTS speech rate (audio/TTS) |
| `book` | current Book |
| `source` | current source |
| `result` | URL string built so far |

Constructor params populated by callers (`AnalyzeUrl.kt:77-92`): `mUrl`, `key`, `page`, `speakText`, `speakSpeed`, `baseUrl`, `source`, `ruleData`, `chapter`, `readTimeout`, `callTimeout`, `coroutineContext`, `headerMapF`, `hasLoginHeader`.

## 2. JS globals inside rule fields (`AnalyzeRule.evalJS` — `AnalyzeRule.kt:774-804`)

| Variable | Value |
|---|---|
| `java` | the AnalyzeRule instance |
| `cookie` | CookieStore |
| `cache` | CacheManager |
| `source` | current source |
| `book` | ruleData as? BaseBook (Book / SearchBook / null) |
| `result` | previous rule output |
| `baseUrl` | current parse base URL |
| `chapter` | BookChapter |
| `title` | `chapter?.title` |
| `src` | raw page content |
| `nextChapterUrl` | next chapter URL |
| `rssArticle` | RssArticle (RSS only) |

Prototype = source's `jsLib` shared scope (`getShareScope`).

## 3. `source.*` helpers (`BaseSource.kt:28-259`)

`getTag()`, `getKey()`, `getSource()`, `loginUi()`, `getLoginJs()`, `login()`, `getHeaderMap()`, `getLoginHeader(Map)`, `putLoginHeader()`, `removeLoginHeader()`, `getLoginInfo(Map)`, `putLoginInfo()`, `removeLoginInfo()`, `setVariable()/getVariable()`, `put(key,value)/get(key)` (persistent cache), `evalJS()`, plus all `java.*` below.

## 4. `java.*` API

From `app/src/main/java/io/legado/app/help/JsExtensions.kt`:

- Network: `ajax`, `ajaxAll`, `connect`, `post`, `get`, `head`, `downloadFile`, `getCookie`
- WebView: `webView`, `webViewGetSource`, `webViewGetOverrideUrl`, `getVerificationCode`, `startBrowser(Await)`
- Rules: `getString`, `getStringList`, `getElement`, `getElements`, `setContent`, `put`, `get`
- Encode/format: `strToBytes`, `bytesToStr`, `base64Encode/Decode(ToByteArray)`, `hexEncodeToString`, `hexDecodeToByteArray`, `hexDecodeToString`, `encodeURI`, `htmlFormat`, `t2s`/`s2t`, `getWebViewUA`
- Time: `timeFormat`, `timeFormatUTC`
- Files/archives: `getFile`, `readFile`, `readTxtFile`, `deleteFile`, `unzipFile`, `un7zFile`, `unrarFile`, `unArchiveFile`, `getTxtInFolder`, `getZipStringContent`, `getRarStringContent`, `get7zStringContent`, `getZipByteArrayContent`, `getRarByteArrayContent`, `get7zByteArrayContent`, `importScript`, `cacheFile`
- Fonts: `queryTTF`, `replaceFont`, `queryBase64TTF` (deprecated)
- Utils: `toNumChapter`, `toURL`, `toast`, `longToast`, `log`, `logType`, `randomUUID`, `androidId`, `openUrl`

Crypto from `app/src/main/java/io/legado/app/help/JsEncodeUtils.kt`: `md5Encode`, `md5Encode16`, `createSymmetricCrypto`, `createAsymmetricCrypto`, `createSign`, `digestHex`, `digestBase64Str`, `HMacHex`, `HMacBase64`, plus deprecated AES/DES/3DES helpers.

AnalyzeUrl/AnalyzeRule-only extras: `getStrResponse`, `getResponse`, `getByteArray`, `getInputStream`, `upload`, `getGlideUrl`, `getUserAgent`, `isPost`, `reGetBook`, `refreshTocUrl`, `ajax`.

## 5. Object fields

- **`book`** (`Book.kt:38-416`, `BaseBook.kt:9-13`): `.name`, `.author`, `.bookUrl`, `.kind`, `.wordCount`, `.intro`, `.coverUrl`, `.tocUrl`, `.origin`, `.originName`, `.latestChapterTitle`, `.variable`, `.variableMap`, `.infoHtml`, `.tocHtml`...
- **`chapter`** (`BookChapter.kt:42-175`): `.url`, `.title`, `.index`, `.bookUrl`, `.baseUrl`, `.isVolume`, `.isVip`, `.isPay`, `.resourceUrl`, `.variable`, `.variableMap`, `.titleMD5`
- **`cookie`** (`CookieStore.kt:19-123`): `getCookie(url)`, `getKey(url,key)`, `setCookie(url,cookie)`, `replaceCookie`, `removeCookie`, `cookieToMap`, `mapToCookie`, `clear`
- **`cache`** (`CacheManager.kt:51-123`): `put`, `get`, `getInt/Long/Double/Float`, `putMemory`, `getFromMemory`, `deleteMemory`, `putFile`, `getFile`, `delete`

## 6. Notes / non-existent params

- Older vars `catalog`, `nextTocUrl` (as JS var), and standalone `bookUrl`/`tocUrl`/`chapterUrl` no longer exist — they are rule-JSON field names or `book.*` properties.
- `console` is NOT defined (Rhino engine setup provides only standard ECMAScript built-ins).
- `@put:`/`@get:` storage backed by `RuleDataInterface` (`putVariable`/`getVariable`, values >=10000 chars via `RuleBigDataHelp`).
