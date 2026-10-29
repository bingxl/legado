# 书源逆向 SOP（可复用）

> 适用：目标站点的正文/目录/列表数据不是直出的 HTML，而是经 JS 计算、编码、加密或接口二次请求才能拿到。
> 配套：`reverse_tools/` 三个脚本、案例 `书源逆向案例-yumanhua.md`、规则语法见 `书源知识库.md`。
> 原则：**先证明数据在哪，再研究怎么解；先在 Python 跑通，再移植到 Rhino。**

---

## 0. 何时需要走这套流程

写源时先按普通流程试一遍 CSS/JSON 规则，出现以下任一现象再进入逆向：

| 现象 | 说明 |
|---|---|
| 正文 `<img>` 只有 `load.gif` / 空白 `data-src` | 图片地址运行时注入 |
| 正文容器是空的 `<div id="content"></div>` | 内容由 XHR 拉取 |
| 目录只有最近 N 章，末尾有「查看更多」 | 需要调分页接口 |
| 页面里有 `eval(function(p,a,c,k,e,d)` | Packer 打包 |
| 页面里有 `_0x` 开头的变量/函数 | 字符串表混淆 |
| 请求带 `sign` / `token` / `timestamp` 参数 | 需要签名算法 |

**不要一上来就猜加密。** 先确认是「接口直出 JSON」还是「真加密」——前者只需要找 XHR，成本差一个数量级。

---

## 1. 环境准备

```bash
# 目录约定：脚本放 reverse_tools/，中间产物放 /tmp/rev/
mkdir -p reverse_tools /tmp/rev

# 统一 UA，避免移动版/桌面版结构不一致
UA="Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
```

依赖：Node ≥ 18（跑解包/反混淆）、Python ≥ 3.10（跑解码试探）。无第三方库。

---

## 2. 步骤 1：四层基线抓取

**每层都存成独立文件**，后面所有分析都基于这些快照，避免反复请求导致结果不一致。

```bash
curl -sL -A "$UA" "$HOST/"                        -o /tmp/rev/00-home.html
curl -sL -A "$UA" "$HOST/list/1"                  -o /tmp/rev/01-list.html
curl -sL -A "$UA" "$HOST/<bookId>/"               -o /tmp/rev/02-detail.html
curl -sL -A "$UA" "$HOST/<bookId>/<chapId>.html"  -o /tmp/rev/03-chapter.html
```

每层只问三个问题，写进一张表：

| 层 | 列表容器 | 分页方式 | 字段选择器 |
|---|---|---|---|
| 列表 | ？ | `?page=N` / POST body / 滚动加载 | ？ |
| 详情 | — | — | 书名/作者/分类/简介/封面/最新章 |
| 目录 | ？ | 一次给全 or 需接口 | — |
| 正文 | ？ | — | 文本节点 or `<img>` |

**判据**：正文层用 `grep -c '<img' 03-chapter.html` 看真实图片数。若是 0 或只有占位图，进入步骤 3。

---

## 3. 步骤 2：判定数据来源

按成本从低到高排查，命中即停：

| 模式 | 特征 | 成本 | 处理方式 |
|---|---|---|---|
| A. HTML 直出 | `<img src="真实地址">` | 极低 | CSS 规则，不需要逆向 |
| B. 懒加载属性 | `<img data-src="真实地址">` | 低 | 规则写 `@data-src`；注意 `imgPattern` 只认 `src`，漫画需自行拼 `<img src>` |
| C. 独立 JSON 接口 | Network 里有 `ajax/fetch` 返回列表 | 低 | 直接写 URL + `$.` 规则 |
| D. JSON 接口 + 签名 | 带 `sign`/`token`/`_t` | 中 | 找签名函数移植（见 §5.4） |
| E. 内联编码数据 | 页面有长 base64 / hex 变量 | 中 | `try_decrypt.py` 试链 |
| F. 运行时解密 | 页面有 packer + 外链混淆 JS | 高 | 本 SOP 全流程 |

**技巧**：先用浏览器 DevTools 的「Network → XHR」跑一遍章节页，如果图片 URL 是以 XHR 响应形式出现的，直接走 C/D；只有纯前端解密才会落到 E/F。

---

## 4. 步骤 3：定位载荷

### 4.1 内联原文（最快）

```bash
grep -oE 'var [A-Za-z_$][A-Za-z0-9_$]* *= *"[A-Za-z0-9+/=]{80,}"' 03-chapter.html | head
```

命中长 base64 变量 → 直接跳到 §6。

### 4.2 内联 Packer

特征：`eval(function(p,a,c,k,e,d){...}('...',62,378,'...'.split('|')...))`

```bash
node reverse_tools/unpack_packer.js /tmp/rev/03-chapter.html
```

输出会顺带报出「可疑的长 base64 变量」，通常就是载荷所在。**Packer 是可逆的，不要费劲在浏览器里打断点。**

注意两个变化：

- `e` 参数可能是 `e` 或 `r`（radix 变体），脚本已兼容。
- 变量名是随机的（`__c0rst96`），规则里用 `__\w+` 匹配，不要写死。

### 4.3 外链混淆 JS

特征：文件名如 `all2.js`、`app.min.js`，内容是 `_0x3363=[...]` + `_0x3e45(idx,key)`。

```bash
node reverse_tools/deob_strings.js /tmp/rev/all2.js -o /tmp/rev/all2.deob.js
```

原理：mock 完整 DOM/jQuery 环境 → `eval` 让脚本自己初始化 → 把每个 `_0x….('a','b')` 调用替换成实际返回值。

输出三样东西最有用：

1. **全部字符串**：能看到 `charCodeAt`、`fromCharCode`、`JSON.parse`、`data-id` 这类算法骨架词；
2. **候选 base64 常量**：很可能就是密钥表；
3. **DOM 模板**：如 `<div class="chapter-img-box"><img data-src="`，直接暴露渲染逻辑。

若报 `NO_GLOBAL_DECODER`（解码函数在 IIFE 闭包里），改用手工插桩：

```js
// 在 eval 之前包一层，捕获 atob / fromCharCode / split 的入参出参
const origAtob = global.atob;
global.atob = (s) => { const r = origAtob(s); log('atob', s.length, r.slice(0, 40)); return r; };
```

### 4.4 XHR 接口

```bash
# 从 JS 里找请求路径
grep -oE '(url|ajax|post|get)[^;]{0,80}["'"'"']/[a-zA-Z0-9_/]+' /tmp/rev/all.js | head -20
```

拿到候选后直接 `curl` 试，看返回是 JSON 还是空。这一步常能省掉整个解密流程。

---

## 5. 步骤 4：识别算法

### 5.1 特征速查

| 特征 | 判断 | 验证方式 |
|---|---|---|
| 只含 `A-Za-z0-9+/=`，长度为 4 的倍数 | base64 | 解一次看是否可打印 |
| 有填充但夹杂不可读字节，长度与原串相近 | XOR | 用 `key` 试，看是否出现 `[` `{` `http` |
| 首字节分布均匀、长度是 16 的倍数 | AES | 需要 key + iv，且明文通常带 padding |
| 密钥是 4~16 字节可打印串 | RC4 / XOR | 两种都试 |
| 两段数据异或后得到明文 | 固定 key XOR | 已知明文攻击：明文 ^ 密文 = key |
| 请求参数含 `sign`/`_sign`/`token` | 签名 | 找 `md5(`/`sha1(` 附近代码 |

### 5.2 已知明文攻击（XOR 快速定位）

如果密文解出来是乱码但长度合理，且知道明文开头（如 `https://` 或 `[{"`），直接：

```python
key = bytes(c ^ p for c, p in zip(cipher[:8], b'https://'))
```

得到 key 前缀后，再用它去 XOR 全文，看是否出现重复周期 → 确认是循环 XOR。

### 5.3 密钥来源的三种模式

| 模式 | 特征 | 处理 |
|---|---|---|
| 固定常量 | JS 里只有一个候选 key | 直接写进规则 |
| **下标查表** | N 个常量 + 一个值域恰为 0..N-1 的字段（`data-id`、`type`、`vid`） | 读下标 → 取 `KEYS[i]`；**这是最常见也最容易漏的一类** |
| 时间/请求派生 | key 由 `md5(timestamp + salt)` 生成 | 移植签到函数，注意时区与秒/毫秒 |

判断「下标查表」的信号：**常量个数与某个 DOM 属性的取值范围刚好吻合**。yumanhua 案例就是 10 个常量对 `data-id` 的 0~9。

### 5.4 签名移植

签名函数常见形态：

```js
sign = md5(params.sort().join('&') + secret).toUpperCase()
```

移植要点：

- Rhino 里 `java.md5Encode(str)` 可用（Legado 的 `JsExtensions`），无需自己实现；
- 参数拼接顺序、是否 URL 编码、大小写必须逐字对齐；
- 时间戳用 `java.timeFormatUTC()` 或 `Date.now()`，注意站点要秒还是毫秒。

---

## 6. 步骤 5：链式试探

不要手写一堆 `if`，用脚本把所有常见链一次跑完：

```bash
# 先从反混淆输出里抽出候选密钥表
node reverse_tools/deob_strings.js /tmp/rev/all2.js \
  | grep -oE '"[A-Za-z0-9+/]{6,16}={0,2}"' | tr -d '"' > /tmp/rev/keys.txt

python reverse_tools/try_decrypt.py \
  --html /tmp/rev/03-chapter.html \
  --keys "$(paste -sd, /tmp/rev/keys.txt)" \
  --chain b64,xor,b64 \
  --index 9
```

- `--html` 会**自动先解 packer**，再抽长 base64 变量；
- `--index` 对应页面里的 `data-id`，把该下标的 key 提到第一个试；
- 命中后直接打印 JSON（若是 URL 数组，就是漫画图片列表）。

支持的链元素：`b64` / `xor` / `hex` / `url` / `rev`，可任意组合。常见组合：

| 组合 | 场景 |
|---|---|
| `b64` | 单纯 base64 |
| `b64,xor` | base64 后再 XOR（yumanhua） |
| `b64,xor,b64` | 双层 base64 夹 XOR（yumanhua 实际形态） |
| `rev,b64` | 反转后 base64 |
| `hex,xor,b64` | hex 编码 + XOR |

**跑通后立刻记下三件事**：链顺序、key 来源、输出结构。这三样决定了 Legado 规则怎么写。

---

## 7. 步骤 6：移植到 Legado

### 7.1 硬约束（每条都踩过）

| # | 约束 | 后果 | 正确写法 |
|---|---|---|---|
| 1 | JS 规则必须以 `@js:` 或 `<js>` 开头 | 整段被当 CSS 选择器，**静默返回空** | `"content": "@js:\nvar s = ..."` |
| 2 | 规则体内不能出现 `##` | 被 `makeUpRule` 当成「替换规则」截断 | 注释用 `//`，绝不用 `#` |
| 3 | 规则体内不能出现 `{{` | 被当成参数分隔符切开 | 需连续大括号写 `"{" + "{"` |
| 4 | Rhino 无 `atob`/`btoa` | 报错 | 手写 base64（见下） |
| 5 | 按 ES5 写 | 箭头函数/模板串/`let` 可能不识别 | `var` + `function` |
| 6 | 没有 `console` | 报错中断 | `java.log(x)` |
| 7 | 正则需要 `[\s\S]` | `.` 不匹配换行，且不一定支持 `s` 标志 | `/a[\s\S]*?b/` |
| 8 | 返回值是**最后一个表达式** | 写 `return` 反而出错或用 `new Function` 模拟时会丢值 | 末尾直接写变量名 `html;` |
| 9 | `java.ajax` 是**同步**的 | 循环里调 N 次会卡死 | 能批量就批量，只调一次 |
| 10 | 超长字符串处理慢 | 几百 KB 页面正则回溯爆炸 | 先 `substring` 截到目标区间 |

### 7.2 手写 base64（必须有）

```js
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
```

### 7.3 XOR

```js
var xorStr = function (data, key) {
    var x = "";
    for (var j = 0; j < data.length; j++)
        x += String.fromCharCode(data.charCodeAt(j) ^ key.charCodeAt(j % key.length));
    return x;
};
```

### 7.4 规则骨架

```js
@js:
var s = String(result);

// ① 取载荷：优先解 packer，失败则直接找长变量
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

// ② 取上下文（下标、token 等），③ 解密，④ 产出
// ... 见案例 5.2 的完整实现

html;
```

### 7.5 产出方式

| 目标 | 返回 |
|---|---|
| 文本正文 | 字符串（或 `<p>` 包裹的 HTML） |
| 漫画图片 | `<img src="URL">` 拼接串，配 `imageStyle: "FULL"` |
| 目录 | `[{name, url}]` 数组（Rhino 自动转 NativeArray） |
| 列表 | 同上，元素为 `{name, author, bookUrl, ...}` |

---

## 8. 步骤 7：验收矩阵

**一条成功不算成功。** 按下面四维抽样，每维都要过：

| 维度 | 抽样量 | 检查点 |
|---|---|---|
| 多本书 | ≥ 3 本（含长篇/短篇） | 目录条数、首末章名、顺序 |
| 多章节 | ≥ 10 章，覆盖下标全值域 | 解密成功率 100% |
| 边界 | 越界下标、空数据、无 packer | 不抛错，能降级 |
| 下游 | 图片/封面 HEAD | 200 + 正确 content-type |

记录成表格（参考案例 §6），失败项必须定位到是「算法错」还是「兜底没写」。

---

## 9. 步骤 8：加固与降级

逆向规则天生脆弱，必须写兜底：

```js
// 1) 下标越界 → 遍历全部 key
if (idx >= 0 && idx < KEYS.length) tryKey(KEYS[idx]);
if (!arr) for (var q = 0; q < KEYS.length; q++) if (tryKey(KEYS[q])) break;

// 2) 解密失败 → 退回页面里能拿到的 <img>
if (!arr) { /* 抽 <img>，优先 data-src，过滤占位图 */ }

// 3) 接口失败 → 退回页面列表
try { /* ajax 补全目录 */ } catch (e) { }

// 4) 所有降级都不改变对外契约：始终返回可用的字符串/数组
```

过滤占位图的关键词：`load.gif`、`/static/`、`data:image`、`blank.gif`、`placeholder`。

---

## 10. 失效诊断表

| 症状 | 优先怀疑 | 定位动作 |
|---|---|---|
| 突然全书空白，页面正常 | 算法/密钥表变更 | 重跑 `unpack_packer.js` + `try_decrypt.py` |
| 部分章节正常、部分空白 | 下标值域扩大 | 打印 `data-id` 分布，补 key |
| 图片 403 | 签名过期 | 看 URL 里的 `x-expires`/`expires` |
| 目录变少 | 接口参数变了 | 重抓 XHR 对比 body |
| 搜索全空但响应 200 | `bookUrlPattern` 误匹配搜索地址 | 用 `searchUrl` 复测正则（案例坑 1） |
| 正文有内容但 App 显示空白 | 规则缺 `@js:`，或返回了数组而非字符串 | 看调试日志的规则命中情况 |
| 规则保存后自动被截断 | JS 里含 `##` 或 `{{` | `grep -c '##\|{{'` 规则体 |

---

## 11. 附录：脚本用法

```bash
# ① 解 packer（输出可疑长变量）
node reverse_tools/unpack_packer.js page.html [-o out.js] [--all]

# ② 还原混淆字符串（输出全部明文 + 候选密钥表 + DOM 模板）
node reverse_tools/deob_strings.js all2.js [-o deob.js]

# ③ 链式解码（自动解 packer，按 data-id 优先试 key）
python reverse_tools/try_decrypt.py --html page.html \
       --keys "k1,k2,k3" --chain b64,xor,b64 --index 9

# ③' 只列页面里的候选常量，不试解密
python reverse_tools/try_decrypt.py --html page.html --dump-keys
```

三个脚本都不依赖第三方库，也不发网络请求，只处理本地文件。

---

## 12. 附录：Rhino / ES5 写法对照

| 想写 | 不能写 | 改写为 |
|---|---|---|
| 箭头函数 | `arr.map(x => x.id)` | `arr.map(function(x){return x.id})` |
| 模板字符串 | `` `${a}-${b}` `` | `a + "-" + b` |
| 块级作用域 | `let` / `const` | `var` |
| 解构 | `var {a} = o` | `var a = o.a` |
| 展开 | `[...arr]` | `for` 循环 `push` |
| `includes` | `arr.includes(x)` | `arr.indexOf(x) > -1` |
| `padStart` | `s.padStart(4,'0')` | `while (s.length < 4) s = "0" + s;` |
| `Object.assign` | `Object.assign(a,b)` | `for (var k in b) a[k] = b[k];` |
| 异步 | `await` | 用同步的 `java.ajax` |
| 调试 | `console.log` | `java.log(...)` |

---

## 13. 一页纸流程

```
抓四层页面
   │
   ├─ 数据在 HTML？ ──是──> 直接写 CSS/JSON 规则（结束）
   │
   └─ 否
      │
      ├─ XHR 里有 JSON？ ──是──> 写 URL 规则；带签名则移植签名（结束）
      │
      └─ 否
         │
         ├─ 有 eval(function(p,a,c,k,e,d) ──> unpack_packer.js
         ├─ 有 _0x 混淆 ──> deob_strings.js（拿密钥表 + DOM 模板）
         │
         ├─ try_decrypt.py 试链（b64 / xor / hex / rev）
         │      │
         │      └─ 命中 ──> 记录：链顺序 + key 来源 + 输出结构
         │
         ├─ Python 复现 100% 成功
         │
         ├─ 移植 @js 规则（ES5 + 手写 base64 + 避开 ## 和 {{）
         │
         ├─ 加固（越界遍历 key、失败回退 <img>、接口失败回退页面）
         │
         └─ 验收（3 本书 × 10 章 × 边界 × 下游下载）──> 交付
```
