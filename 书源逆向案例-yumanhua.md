# 案例：yumanhua.com 漫画源逆向全记录

> 站点：`http://yumanhua.com`（漫画客）
> 目标：为 Legado 编写 `bookSourceType = 2` 的漫画源
> 产出：`yumanhua_comic_source.json`
> 难度：中高——图片地址不在 HTML 里，需先解 packer 再解两层编码
> 日期：2026-10-20

---

## 0. 案例速览

| 项目 | 内容 |
|---|---|
| 站点框架 | 自研 PHP SSR + jQuery，列表/详情由服务端渲染 |
| 反爬手段 | 正文图片列表用 Dean Edwards Packer 打包后内联，数据本身再经 2 层 base64 + 1 层 XOR |
| 密钥来源 | 页面 `<div class="readerContainer" data-id="N">` 的 `N`，从 10 个硬编码常量里取 |
| 破解耗时 | 主要成本在「确认图片不在 HTML 里」和「推断 key 与 data-id 的对应关系」 |
| 最终方案 | 纯 HTTP 规则，不依赖 WebView；`chapterList` 与 `content` 两条 `@js:` 规则 |
| 遗留限制 | 搜索接口不返回作者；图片是 7 天签名直链 |

---

## 1. 侦察：先建立页面基线

按「首页 → 分类 → 详情 → 章节」四层抓一遍，每层只关心三件事：**列表在哪、分页怎么翻、详情字段叫什么**。

```bash
UA="Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"

curl -sL -A "$UA" "http://yumanhua.com/"                       -o home.html
curl -sL -A "$UA" "http://yumanhua.com/sort/1"                 -o sort1.html
curl -sL -A "$UA" "http://yumanhua.com/XuzVzjo/"               -o detail.html
curl -sL -A "$UA" "http://yumanhua.com/XuzVzjo/OAQNOuY.html"   -o chapter.html
```

观察到的事实：

| 层 | 事实 | 对写源的意义 |
|---|---|---|
| 首页/分类 | 服务端直出 `<ol>` 列表，每页 20 条 | 但发现功能优先用 JSON 接口，省去解析 DOM |
| 详情 | `h1.name`、`p:contains(作者)`、`.comic-tags span`、`.cartoon-introduction`、`.book-cover img[data-src]` | 全部可用 CSS 规则，无需 JS |
| 详情-目录 | `.chaplist-box` 里只有 **20 章** | 必须找全量目录接口 |
| 章节 | **`<img>` 只有占位图，没有一张真实图片** | ← 本案例的核心难点 |

章节页里实际只有这种标签：

```html
<img src="/static/images/load.gif" data-src="" alt="第1页">
```

`src` 是统一的加载动画，`data-src` 为空。**图片地址是运行时才填进去的**，说明数据在 JS 里。

---

## 2. 定位载荷：从外链 JS 到内联脚本

### 2.1 先看外链脚本

章节页引用了：

```html
<script src="/static/js/all.js?v=17120006"></script>
<script src="/static/js/all2.js?v=2.3"></script>
```

`all2.js` 是控制流平坦化 + 字符串表混淆（`_0x3363` 数组 + `_0x3e45(idx, key)` 解码函数），直接读没有可读性。

处理这类混淆的正确姿势不是逐行读，而是**让它自己跑起来**：在 Node 里 mock 掉 `document` / `$`，`eval` 整个文件，把解密函数暴露出来，遍历所有调用点替换成明文。本项目用的 `reverse_tools/deob_strings.js` 就是干这个的。

解码后得到的关键线索是一批常量，其中 10 个是 base64：

```
c21raHkyNTg=  c21rZDk1ZnY=  bWQ0OTY5NTI=  Y2Rjc2R3cQ==  dmJmc2EyNTY=
Y2F3ZjE1MWM=  Y2Q1NmN2ZGE=  OGtpaG50OQ==  ZHNvMTV0bG8=  NWtvNnBsaHk=
```

此时还不知道它们是干什么用的，先记下。

### 2.2 再看内联脚本

同一页还有一段内联脚本，形式是经典的 Dean Edwards Packer：

```js
eval(function(p,a,c,k,e,d){ ... }('...',62,378,'...'.split('|') ...))
```

`eval` 包着，浏览器能跑，但内容不可读。**Packer 是完全可逆的**，不需要执行，按它的编码规则反查字典即可。解包后（见 `reverse_tools/unpack_packer.js`）露出真身：

```js
var __c0rst96 = "eyJ...（约 3KB 的长串）";
$(function () {
    // ... 用 __c0rst96 渲染阅读器
});
```

变量名带随机后缀（`__c0rst96`），每次改版可能变。**这说明规则里不能把变量名写死**，要接受任意 `__\w+` 形式，或直接匹配 `var __(\w+)="（长 base64）"`。

同时在 DOM 里注意到：

```html
<div class="readerContainer" data-id="9" data-sign="..." data-time="...">
```

`data-id` 每章不同（实测覆盖 0~9），跟上面那 10 个 base64 常量的数量刚好对上。

---

## 3. 算法还原：三层结构

把 `__c0rst96` 和 `data-id` 放进 Python 试，很快就试出结构：

```
__c0rst96 (base64 文本)
   │  base64 解码
   ▼
bytes
   │  与 base64(K) 逐字节循环 XOR，K = KEYS[data-id]
   ▼
bytes
   │  再 base64 解码（这次结果是 UTF-8 文本）
   ▼
JSON: ["https://.../001.jpg", "https://.../002.jpg", ...]
```

Python 验证（`data-id = 9`）：

```python
import base64, json, re

KEYS = ["c21raHkyNTg=", "c21rZDk1ZnY=", "bWQ0OTY5NTI=", "Y2Rjc2R3cQ==", "dmJmc2EyNTY=",
        "Y2F3ZjE1MWM=", "Y2Q1NmN2ZGE=", "OGtpaG50OQ==", "ZHNvMTV0bG8=", "NWtvNnBsaHk="]

h   = open('chapter.html', encoding='utf-8', errors='ignore').read()
idx = int(re.search(r'readerContainer"\s*data-id="(\d+)"', h).group(1))
# 先解包：node reverse_tools/unpack_packer.js chapter.html -o chapter.unpacked.js
rst = re.search(r'__\w+\s*=\s*"([^"]+)"', open('chapter.unpacked.js', encoding='utf-8').read()).group(1)

raw = base64.b64decode(rst + '=' * (-len(rst) % 4))
key = base64.b64decode(KEYS[idx])
xor = bytes(b ^ key[i % len(key)] for i, b in enumerate(raw))
imgs = json.loads(base64.b64decode(xor + '=' * (-len(xor) % 4)).decode())
print(idx, len(imgs), imgs[0])
# 9 10 https://shimolife.com/.../001.jpg?x-expires=...
```

10 个 key 解码后的明文（便于排查，规则里仍用原 base64）：

| data-id | base64 常量 | 明文 |
|---|---|---|
| 0 | `c21raHkyNTg=` | smkhy258 |
| 1 | `c21rZDk1ZnY=` | smkd95fv |
| 2 | `bWQ0OTY5NTI=` | md496952 |
| 3 | `Y2Rjc2R3cQ==` | cdcsdwq |
| 4 | `dmJmc2EyNTY=` | vbfsa256 |
| 5 | `Y2F3ZjE1MWM=` | cawf151c |
| 6 | `Y2Q1NmN2ZGE=` | cd56cvda |
| 7 | `OGtpaG50OQ==` | 8kihnt9 |
| 8 | `ZHNvMTV0bG8=` | dso15tlo |
| 9 | `NWtvNnBsaHk=` | 5ko6plhy |

**为什么 key 不是固定一个？** 站点把 XOR 密钥按章节轮换，`data-id` 就是轮换槽位号。所以每章都要先读 `data-id` 才能解。

> 试错记录：一开始按 `secretData`、`data-sign`、时间戳当密钥全部失败，直到把 `data-id` 与「10 个 base64 常量」的**数量巧合**对上才转向。**遇到「N 个常量 + 一个 N 值域的下标」时，先假设它们是查表关系。**

### 3.1 交叉验证：让混淆脚本自己招供

算法是靠试出来的，但可以用 `deob_strings.js` 反查原文来验证推断是否完整。对 `all2.js` 跑一遍，还原出的 58 个字符串里包含：

```
"charCodeAt"  "fromCharCode"  "parse"  "data"  ".readerContainer"  ".main_img"
"<div class=\"chapter-img-box\"><img data-src=\""   "\" src=\"/static/images/load.gif\"></div>"
以及 10 个 base64 常量中的 8 个
```

这些词恰好拼出完整链路：`readerContainer` 取 `data`-id → 取 key → `charCodeAt`/`fromCharCode` 做 XOR → `parse` 出数组 → 渲染成 `data-src` 的 `<img>`。

**这是逆向里性价比最高的一步**：不用读懂控制流，只要拿到字符串表，算法骨架基本自解释。同时也确认了「页面里没有真 `src`」的原因——站点自己也是先渲染 `data-src` 再由懒加载替换。

---

## 4. 章节列表：详情页只给 20 章

详情页 `.chaplist-box` 只有最新 20 章，全量在接口里。抓 XHR 得到：

```
POST /morechapter
body: id=XuzVzjo
→ {"code":0,"data":[{"chaptername":"第1话 ...","chapterid":"XXXXXXX"}, ...]}
```

实测 833 条，顺序是**从旧到新**，且与详情页那 20 章**零重合**（详情页给的是最新 20 章，接口给的是全集，两者不重叠）。

另外发现两个边界：

- 没有更多数据时返回 `{"code":-1,"msg":"没有更多数据了","data":""}` —— `data` 是**空字符串**不是数组，JS 里直接 `.length` 会拿到 0，但如果按数组遍历会报错，必须 try/catch。
- 短篇（5 章那种）接口直接返回空串，此时只能靠详情页那 20 章兜底。

所以 `chapterList` 规则要做三件事：**解析详情页兜底 → 调接口补全 → 去重后倒序**。

---

## 5. 落成 Legado 规则

### 5.1 目录规则（`ruleToc.chapterList`）

```js
@js:
var s = String(result);
var host = "http://yumanhua.com";
var hm = String(baseUrl).match(/^(https?:\/\/[^\/]+)/);
if (hm) host = hm[1];
var id = "";
var mm = String(baseUrl).match(/\/([A-Za-z0-9]+)\/?$/);
if (mm) id = mm[1];
if (!id) {                                  // baseUrl 取不到时从页面反推
    var mu = s.match(/href="\/([A-Za-z0-9]+)\/[A-Za-z0-9]+\.html"/);
    if (mu) id = mu[1];
}
var list = [], seen = {};
var add = function (name, url) {
    if (!name || !url || seen[url]) return;
    seen[url] = 1; list.push({ name: name, url: url });
};
var box = s.match(/<div class="chaplist-box">([\s\S]*?)<\/ul>/);
if (box) {
    var re = /<a href="([^"]+)"[^>]*>([^<]+)<\/a>/g, r;
    while ((r = re.exec(box[1])) !== null) add(r[2], r[1]);
}
if (id) {
    var res = java.ajax(host + "/morechapter,{\"method\":\"POST\",\"body\":\"id=" + id + "\"}");
    if (res) {
        try {
            var d = JSON.parse(String(res)).data;
            for (var i = 0; i < d.length; i++)
                add(d[i].chaptername, "/" + id + "/" + d[i].chapterid + ".html");
        } catch (e) { }
    }
}
list.reverse();
list;
```

三个要点：

- `java.ajax()` 内部会 `AnalyzeUrl(url, source = getSource())`，**自动继承书源 header**，并且支持 `,{...}` 完整 URL 选项语法，所以 POST 可以一行写完（`JsExtensions.kt:93`）。
- 去重靠 URL 而不是章节名——站点存在同名章节（不同卷重名）。
- 接口失败不能抛错，否则整个目录空掉，所以 try/catch 包住，退回页面 20 章。

### 5.2 正文规则（`ruleContent.content`）

Legado 的 Rhino **没有 `atob`**，必须手写 base64：

```js
@js:
var s = String(result);
// 1) 解 packer，取出 __xxxx="..."
var rst = "";
var bi = s.indexOf("eval(function(p,a,c,k,e,d)");
if (bi > -1) {
    var m = s.substring(bi).match(/eval\(function\(p,a,c,k,e,d\)[\s\S]*?\}\('([^']*)',(\d+),(\d+),'([\s\S]*?)'\.split\('\|'\)/);
    if (m) {
        var P = m[1], A = parseInt(m[2]), C = parseInt(m[3]), K = m[4].split("|");
        var D = {}, I = C;
        var fnE = function (x) {
            return (x < A ? "" : fnE(Math.floor(x / A))) +
                   (x % A > 35 ? String.fromCharCode(x % A + 29) : (x % A).toString(36));
        };
        while (I--) { D[fnE(I)] = K[I] || fnE(I); }
        P = P.replace(/\b\w+\b/g, function (w) { return D[w] !== undefined ? D[w] : w; });
        var rm = P.match(/__\w+\s*=\s*"([^"]+)"/);
        if (rm) rst = rm[1];
    }
}
if (!rst) { var rm2 = s.match(/__\w+\s*=\s*"([^"]+)"/); if (rm2) rst = rm2[1]; }

// 2) 手写 base64（Rhino 无 atob）
var CH = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
var b64 = function (str) {
    var out = "", i = 0, L = str.length;
    while (i < L) {
        var c1 = CH.indexOf(str.charAt(i++)); if (c1 < 0) c1 = 64;
        var c2 = CH.indexOf(str.charAt(i++)); if (c2 < 0) c2 = 64;
        var c3 = CH.indexOf(str.charAt(i++)); if (c3 < 0) c3 = 64;
        var c4 = CH.indexOf(str.charAt(i++)); if (c4 < 0) c4 = 64;
        var n = (c1 << 18) | (c2 << 12) | (c3 << 6) | c4;
        out += String.fromCharCode((n >> 16) & 255);
        if (c3 != 64) out += String.fromCharCode((n >> 8) & 255);
        if (c4 != 64) out += String.fromCharCode(n & 255);
    }
    return out;
};

// 3) 取 data-id 与 key，base64 -> XOR -> base64 -> JSON
var im = s.match(/readerContainer[^>]*data-id="(\d+)"/);
var idx = im ? parseInt(im[1]) : 9;
var KEYS = ["c21raHkyNTg=", "c21rZDk1ZnY=", "bWQ0OTY5NTI=", "Y2Rjc2R3cQ==", "dmJmc2EyNTY=",
            "Y2F3ZjE1MWM=", "Y2Q1NmN2ZGE=", "OGtpaG50OQ==", "ZHNvMTV0bG8=", "NWtvNnBsaHk="];
var arr = null;
var tryKey = function (k) {
    try {
        var key = b64(k), data = b64(rst), x = "";
        for (var j = 0; j < data.length; j++)
            x += String.fromCharCode(data.charCodeAt(j) ^ key.charCodeAt(j % key.length));
        var r = JSON.parse(b64(x));
        if (r && r.length) { arr = r; return true; }
    } catch (e) { }
    return false;
};
if (idx >= 0 && idx < KEYS.length) tryKey(KEYS[idx]);   // 先按 data-id
if (!arr) for (var q = 0; q < KEYS.length; q++) {       // 失败则逐个试
    if (tryKey(KEYS[q])) break;
}

// 4) 产出；彻底失败时回退页面 <img>
var html = "";
if (arr) {
    for (var n = 0; n < arr.length; n++) html += '<img src="' + arr[n] + '">';
} else {
    var re2 = /<img[^>]+>/g, t;
    while ((t = re2.exec(s)) !== null) {
        var u = (t[0].match(/data-src="([^"]+)"/) || t[0].match(/src="([^"]+)"/) || [])[1];
        if (!u || u.indexOf("load.gif") > -1 || u.indexOf("/static/") > -1 || u.indexOf("data:image") == 0) continue;
        html += '<img src="' + u + '">';
    }
}
html;
```

配套 `ruleContent.imageStyle = "FULL"`（Webtoon 满宽）。

### 5.3 其余规则

| 规则 | 写法 | 备注 |
|---|---|---|
| `searchUrl` | `/s,{"method":"POST","headers":{"Content-Type":"application/x-www-form-urlencoded; charset=UTF-8","Referer":"http://yumanhua.com/","Origin":"http://yumanhua.com"},"body":"k={{java.encodeURI(key)}}"}` | 写了 Content-Type 就不会自动编码，body 必须手动 encodeURI |
| `ruleSearch.bookList` | `$.data` | 空结果时 `data` 是空串，`getList` 容错成空列表 |
| `ruleSearch.bookUrl` | `/{{$.id}}/` | `{{$.x}}` 是 JSON 规则而非 JS |
| `exploreUrl` | `冒险::/data/sort,{"method":"POST","body":"s=1&p={{page}}"}` | 16 个分类，每类 5 页 |
| `ruleBookInfo.*` | 纯 CSS | 见 1. 的观察表 |

---

## 6. 验证矩阵

写完不能只看字符串对不对，按「多本书 × 多章节 × 边界」跑：

| 验证项 | 方法 | 结果 |
|---|---|---|
| 目录完整性 | 3 本书对比详情页 + 接口 | 833 / 253 / 5 章，顺序正确 |
| 目录去重 | 比对详情页 20 章与接口 | 零重合，去重逻辑生效 |
| 正文解密 | 随机抽 24 章 | 24/24 成功，`data-id` 覆盖 0~9 全部值 |
| 图片可下载 | HEAD 首图 | 200，`image/jpeg` |
| 封面 | 直链请求 | 200，无需 Referer |
| 详情字段 | 10 部抽样 | 6 个字段全命中 |
| 发现 | 16 分类 × 5 页 = 640 条 | 字段齐全，仅 4 条无 intro |
| 搜索 | 修仙/斗破苍穹/100%/a&b=c | 42 / 8 / 42 / 空，编码正常 |
| 边界 | 1 字关键词 | `code=-1`，无空书籍 |

---

## 7. 三个致命坑（按代价排序）

### 坑 1：`bookUrlPattern` 把搜索地址匹配了

现象：发现正常，搜索也有响应，但日志显示 `≡链接为详情页`，所有字段为空，最后「未获取到书籍」。

根因（`webBook/BookList.kt:62`）：

```kotlin
if (isSearch) bookSource.bookUrlPattern?.let {
    if (baseUrl.matches(it.toRegex())) { getInfoItem(...); return bookList }   // 命中即走详情页
}
```

搜索地址是 `http://yumanhua.com/s`，而正则写的是 `/[A-Za-z0-9]+/?$`，`s` 被当成了书籍 ID。

修复（书籍 ID 实测全为 7 位字母数字）：

```
^https?://(www\.)?yumanhua\.com/(?!s/?$|sort/?$|data/?$|static/?$|morechapter/?$|search/?$)[A-Za-z0-9]{5,}/?$
```

**教训：`bookUrlPattern` 必须排除 `searchUrl` / `exploreUrl` 自身的路径。**

### 坑 2：JS 规则缺 `@js:`

`AppPattern.JS_PATTERN` 只认 `<js>…</js>` 和 `@js:…`。裸 JS 会被当 CSS 选择器丢给 Jsoup，结果是目录空、正文空，且**不报错**。

### 坑 3：JS 里不能出现 `##` 和 `{{`

`SourceRule.makeUpRule` 会先按 `##` 切出替换规则、按 `{{}}` 切出参数。JS 代码里一旦出现这两个序列（哪怕是注释），整段会被撕开。

- 注释只用 `//`，不要用 `#`
- 需要连续大括号时写成 `"{" + "{"`

---

## 8. 失效预案

| 症状 | 可能原因 | 处理 |
|---|---|---|
| 全书图片读不出，页面结构没变 | 算法/密钥表改了 | 重跑 `unpack_packer.js`，比对 `KEYS` 数量与明文 |
| 只有老章节读不出 | `data-id` 值域变大越界 | 已内置遍历全部 key，若仍失败说明 key 表新增，补进 `KEYS` |
| 图片 403 | 签名 `x-expires` 过期（约 7 天） | 清该章缓存重载，已下载的不受影响 |
| 目录变回 20 章 | `/morechapter` 改了参数名 | 抓一次 XHR，改 body |
| 搜索全空但响应正常 | `bookUrlPattern` 被改坏 | 用 `/s` 复测正则 |

---

## 9. 本次可复用的动作清单

这套流程里有 7 个动作是**跟站点无关**的，已抽到 `书源逆向SOP.md`：

1. 四层抓页面，先确认「数据是否在 HTML 里」
2. 找内联 `eval(function(p,a,c,k,e,d)` → 直接反查字典
3. 找外链混淆 JS → Node mock 跑起来 + 暴露解码函数
4. 「N 个常量 + 一个 N 值域下标」→ 先假设查表
5. Python 里先跑通算法，再考虑移植
6. 移植时按 ES5 写，手写 base64，避开 `##` / `{{`
7. 用「多本书 × 多章节 × 边界」矩阵验收，而不是看一条成功
