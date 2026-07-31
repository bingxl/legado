---
name: legado-web-api
description: Use when writing scripts or automations that talk to a running Legado (阅读) instance over its web HTTP API, WebSocket API, Content Provider, or legado:// deep links — saving/querying book sources, bookshelf, chapter content, replace rules, or debugging sources. Use for curl/PowerShell/Python scripts against http://127.0.0.1:1234. Do NOT use for writing book source rule JSON (see book-source-author).
---

# Legado Web API

Legado exposes three integration surfaces for automation. All require enabling "Web 服务" (Web Service) in app settings. The default ports are HTTP `1234` and WebSocket `1235`; replace `127.0.0.1` with the phone IP for remote access.

## 1. HTTP API (port 1234)

All bodies are JSON. For "single" endpoints the body is one object; for "sources" endpoints the body is a JSON array. The app URL is the primary key (`bookSourceUrl` for sources, `url` for books).

| Endpoint | Method | Body / Query | Purpose |
|----------|--------|--------------|---------|
| `/saveBookSource` | POST | single BookSource object | Insert/update one source |
| `/saveBookSources` | POST | array of BookSource | Insert/update many |
| `/saveRssSources` | POST | array of RssSource | Insert/update RSS subscriptions |
| `/getBookSource?url=xxx` | GET | — | Fetch one source |
| `/getRssSource?url=xxx` | GET | — | Fetch one RSS source |
| `/getBookSources` | GET | — | All book sources |
| `/getRssSources` | GET | — | All RSS sources |
| `/deleteBookSources` | POST | array | Delete sources |
| `/deleteRssSources` | POST | array | Delete RSS sources |
| `/getReplaceRules` | GET | — | All replace/cleanup rules |
| `/saveReplaceRule` | POST | array of ReplaceRule | Insert/update |
| `/deleteReplaceRule` | POST | array | Delete |
| `/testReplaceRule` | POST | `{"rule": <ReplaceRule>, "text": "<test text>"}` | Returns replacement result |
| `/saveBook` | POST | Book object | Add book to bookshelf (enables content caching) |
| `/deleteBook` | POST | Book object | Remove from bookshelf |
| `/getBookshelf` | GET | — | All books on the shelf |
| `/getChapterList?url=xxx` | GET | book url | Chapter list of a book |
| `/getBookContent?url=xxx&index=1` | GET | book url + 0-based chapter index | Chapter text |
| `/cover?path=xxxxx` | GET | cover path | Cover image |
| `/image?url=${bookUrl}&path=${picUrl}&width=${width}` | GET | book url + image path | Content image |
| `/saveBookProgress` | POST | BookProgress object | Persist reading progress |

BookSource shape reference: `app/src/main/java/io/legado/app/data/entities/BookSource.kt`. ReplaceRule shape: `app/src/main/java/io/legado/app/data/entities/ReplaceRule.kt`.

Workflow note from `api.md`: after `/searchBook`, call `/saveBook` to cache chapters before reading `/getChapterList` + `/getBookContent`; call `/deleteBook` if you decide not to keep it.

## 2. WebSocket API (port 1235)

| Endpoint | Message | Purpose |
|----------|---------|---------|
| `ws://127.0.0.1:1235/bookSourceDebug` | `{"key": "search keyword", "tag": "<bookSourceUrl>"}` | Live-debug a book source's search |
| `ws://127.0.0.1:1235/rssSourceDebug` | `{"key": "...", "tag": "<rssSourceUrl>"}` | Live-debug an RSS source |
| `ws://127.0.0.1:1235/searchBook` | `{"key": "<keyword>"}` | Search online books across enabled sources |

Implementation reference: `app/src/main/java/io/legado/app/web/socket/` and `app/src/main/java/io/legado/app/api/controller/`.

## 3. Content Provider

Requires declaring `io.legado.READ_WRITE` permission. Provider host is `<packageName>.readerProvider`, e.g. `io.legado.app.release.readerProvider` — it varies per build, so it must be substituted dynamically.

Use `ContentValues` with key `json` for inserts/deletes. Use `Cursor.getString(0)` for query results.

| URI (`content://providerHost/...`) | Method |
|------------------------------------|--------|
| `bookSource/insert` / `rssSource/insert` | insert (single, key `json`) |
| `bookSources/insert` / `rssSources/insert` | insert (array) |
| `bookSource/query?url=xxx` / `rssSource/query?url=xxx` | query |
| `bookSources/query` / `rssSources/query` | query (all) |
| `bookSources/delete` / `rssSources/delete` | delete (array) |
| `book/insert` | insert |
| `books/query` | query (all) |
| `book/chapter/query?url=xxx` | query |
| `book/content/query?url=xxx&index=1` | query |
| `book/cover/query?path=xxxx` | query |

Implementation: `app/src/main/java/io/legado/app/api/ReaderProvider.kt`.

## 4. Deep links (legado://)

One-tap import on a device that has Legado installed:

```
legado://import/{path}?src={url}
```

`path` is one of: `bookSource`, `rssSource`, `replaceRule`, `textTocRule` (local TXT toc rules), `httpTTS` (online TTS engines), `theme`, `readConfig` (reading layout), `dictRule`, `addToBookshelf`. Entry point: `app/src/main/java/io/legado/app/ui/association/`.

## Usage examples

```powershell
# Import a source file
curl.exe -X POST http://127.0.0.1:1234/saveBookSources -H "Content-Type: application/json" --data-binary "@source.json"

# List the bookshelf
curl.exe http://127.0.0.1:1234/getBookshelf

# Get a book's chapters, then read chapter 0
curl.exe "http://127.0.0.1:1234/getChapterList?url=<encoded-book-url>"
curl.exe "http://127.0.0.1:1234/getBookContent?url=<encoded-book-url>&index=0"
```

Reference docs: `api.md` (repo root).
