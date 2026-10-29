# 漫蛙漫画 (manwame.com) 章节图片加密分析与破解

> 用途：给 Legado 书源作者/维护者参考。下次碰到同类"章节图被混淆 JS 加密"的漫画站，直接照这个流程走。
> 关联站点：https://manwame.com（图片漫画站），示例章节页 `https://manwame.com/book/yinghuochongzhihun-2KXAw/1.html`

## 1. 结论（速查）

- 章节页 HTML 里没有图片，只有一段加密的 `params`（base64）+ `comic_state='1'`，图片由前端 JS 解密后加载。
- 解密脚本：`/static/js/cms-2.0.1.min.js?v=1.0.1` 里的 `CMS.chapter.decrypt(params)`，整段是 **jsjiami.v7 混淆**（字符串表用 base64+RC4 编码）。
- 算法：**AES/CBC/PKCS7**（CryptoJS 默认补齐）。
- **密钥**：`CryptoJS.enc.Utf8.parse("5V&RoR%Jf@pJPydF")`，16 字节 = AES-128。
  - 十六进制字节形式（书源里用这个）：`KYE_HEX = 355626526f52254a6640704a50796446`
  - 还原验证：hex 解码 `35 56 26 52 6f 52 25 4a 66 40 70 4a 50 79 64 46` == `"5V&RoR%Jf@pJPydF"`。
- **IV**：`Base64.decode(params)` 结果的前 **16 字节**。
- **密文**：`Base64.decode(params)` 结果去掉前 16 字节后的剩余部分。
- 解密成功后 JSON 结构：`host`、`comic_id`、`comic_name`、`chapter_title`、`chapter_images[]`、`images_hosts[]`（如 `https://s1.gimg.top`）等。
- 示例：`params`（1.html 内 `var config = {...}, params = '<...>'`，取值见正文验证脚本）。

## 2. 破解过程（可复现）

### 2.1 观察页面

1. `webfetch` 章节页 HTML → 只有 `#chapter-images` 占位、导航、以及一个巨大的 `params` 变量。
2. 页面引用了 `crypto-js.min.js` → 说明图片数据在浏览器端用 CryptoJS 解密。
3. 找到负责渲染的解密函数：`CMS.chapter.decrypt(params)`（在 `cms-2.0.1.min.js`）。

### 2.2 关键思路：别手撕混淆，让它自己跑

`cms.js` 被 jsjiami.v7 混淆：字符串表 `d()` 是一堆 base64 串，靠 `s(index, key)`（base64 + RC4 按 key 解码）取出来，索引从 236 开始（`a[t-=236]`）。手动还原 `c(273,"GpdQ")` 之类很费劲。

**正确做法**：把站点原版 `cms.js` + 它引用的 `crypto-js.min.js` 一起放进 Node 的 `vm` 沙箱，然后给 `CryptoJS` 的方法挂钩子，打印它收到的 key / iv / 密文。这样无需理解混淆逻辑，直接拿到 AES 参数。

### 2.3 挂钩点

- `CryptoJS.enc.Utf8.parse` → 打印密钥字符串（本站在这里暴露 `"5V&RoR%Jf@pJPydF"`）
- `CryptoJS.enc.Hex.parse` / `enc.Hex.stringify` → 看 IV、密文的 hex
- `CryptoJS.AES.decrypt` → 确认算法、密文长度
- `JSON.parse` → 拿到解密后的章节 JSON（图片列表、域名）

### 2.4 验证脚本

可复用脚本：`scripts/manwame_decrypt.js`（同一技能目录下）。

```bash
cd .opencode/skills/book-source-author
node scripts/manwame_decrypt.js   # 从站点自动下载 JS 并跑钩子，打印 key / 解密结果
```

脚本干的事：
1. `curl` 下载 `https://manwame.com/static/js/cms-2.0.1.min.js` 和 `crypto-js.min.js`。
2. 把页面的 `params`（可从任意章节页 HTML 里抓）注入沙箱。
3. vm 沙箱里 `window={}`、`JSON` 包一层打印，执行 `CMS.chapter.decrypt(params)`。
4. 输出：密钥、解密 JSON 的键、图片数量、前几张图、图片域名，并校验 `KYE_HEX`。

## 3. Legado 书源里的用法

图片源 `bookSourceType: 2`。`ruleContent.content` 用 `@js:` 解密后输出 `<img>` 标签：

```js
function getImgs() {
  var json = JSON.parse(src);            // 页面变量 params 在正文页的 JS 里，正文规则可先用 :regex 或 @js 抠出来
  var raw = java.base64Decode(params);   // 还原字节
  var iv = raw.slice(0, 16);             // 前 16 字节 = IV
  var data = raw.slice(16);              // 其余 = 密文
  var txt = java.createSymmetricCrypto(
    "AES/CBC/PKCS5Padding",
    hexToBytes("355626526f52254a6640704a50796446"),  // KYE_HEX，按字节喂，勿用 UTF-8 字符串
    iv
  ).decrypt(data);
  var obj = JSON.parse(txt);
  var host = obj.images_hosts[0];        // 或 obj.images_domain / obj.cdnurl
  var html = "";
  obj.chapter_images.forEach(function (im) {
    html += '<img src="' + host + '/' + im + '">';
  });
  return html;
}
getImgs();
```

要点：
- **密钥必须按字节给**。站点用的是 `Utf8.parse("5V&RoR%Jf@pJPydF")`，等价于把 `KYE_HEX` hex 解码成 16 字节。若直接把 `"5V&RoR%Jf@pJPydF"` 当 UTF-8 字符串传，等价结果相同；但用 `KYE_HEX` 十六进制形式最稳妥。
- `imageStyle` 设 `FULL`；如需防盗链可给 `<img>` 加 `referrerpolicy`/headers。
- `params` 位于章节页内联 `<script>` 的 `var config = {...}, params = '...'`，规则里用 `:regex@js` 提取。

## 4. 通用套路（其它站复用）

1. 章节页有加密 blob + 引用了 crypto-js / 自定义解密 js → 解密在浏览器端。
2. 下载它引用的所有 JS，**在 Node 沙箱里跑原版并 hook CryptoJS**，比手撕混淆快得多。
3. CryptoJS 常见坑：
   - `WordArray` 没有 `.salt` 属性——混淆名 `u.salt.slice(4)` 实际是 `u.words.slice(4)`（砍掉前 4 个 32 位字 = 16 字节 IV）。
   - key 常用 `enc.Utf8.parse`（字节即 ASCII 字符串）或 `enc.Hex.parse`（32 位 hex）。
   - IV 常取密文 blob 前 16 字节（"随机盐"模式）。
4. jsjiami.v7 特征：`jsjiami.com.v7` 出现在字符串表首位；字符串表索引偏移 236；解码 = base64（小写字母优先的自定义顺序）+ RC4(key=调用时第二个参数)。
5. 拿到的 key 存 hex 形式（如 `355626...`），下次直接复用。

## 5. 相关文件

- 技能目录下可复用脚本：`scripts/manwame_decrypt.js`
- 站点解密脚本：`https://manwame.com/static/js/cms-2.0.1.min.js`
- 示例章节页：`https://manwame.com/book/yinghuochongzhihun-2KXAw/1.html`
