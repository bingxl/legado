#!/usr/bin/env node
/**
 * manwame.com 章节图片解密取证脚本
 *
 * 用法:
 *   node scripts/manwame_decrypt.js [章节页URL]
 *   默认使用 https://manwame.com/book/yinghuochongzhihun-2KXAw/1.html
 *
 * 流程:
 *   1. 抓章节页 HTML，提取内联 <script> 里的 params
 *   2. 下载站点同源 crypto-js.min.js 和 cms-2.0.1.min.js
 *   3. 在 vm 沙箱里执行原版 cms.js，hook CryptoJS.enc.*.parse / AES.decrypt / JSON.parse
 *   4. 打印密钥字符串、解密 JSON 的键、图片数量与域名，并校验 KYE_HEX
 *
 * 依赖: node >= 16（用内置 fetch / http，无需 npm 包）
 */
const fs = require('fs');
const http = require('http');
const https = require('https');
const os = require('os');
const path = require('path');
const vm = require('vm');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'manwame-'));
const DEFAULT_URL = 'https://manwame.com/book/yinghuochongzhihun-2KXAw/1.html';
const CMS_JS = 'https://manwame.com/static/js/cms-2.0.1.min.js?v=1.0.1';
const CRYPTO_JS = 'https://manwame.com/static/libs/crypto-js/4.1.1/crypto-js.min.js';
const KYE_HEX = '355626526f52254a6640704a50796446';

function fetch(url) {
  return new Promise((resolve, reject) => {
    const lib = url.startsWith('https:') ? https : http;
    const req = lib.get(url, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    });
    req.on('error', reject);
    req.setTimeout(30000, () => req.destroy(new Error('timeout ' + url)));
  });
}

function extractParams(html) {
  const m = html.match(/var config\s*=\s*\{[^}]*\}\s*,\s*params\s*=\s*'([^']+)'/s);
  if (!m) throw new Error('未在页面 HTML 中找到 params');
  return m[1];
}

(async () => {
  const chapterUrl = process.argv[2] || DEFAULT_URL;
  console.log('[1/4] 抓取章节页:', chapterUrl);
  const pageHtml = await fetch(chapterUrl);
  const params = extractParams(pageHtml);
  console.log('[2/4] params 长度:', params.length, '字节');

  const cryptoJsSrc = await fetch(CRYPTO_JS);
  const cmsSrc = await fetch(CMS_JS);
  console.log('[3/4] 已下载 cms-2.0.1.min.js 与 crypto-js.min.js');

  const hostJSON = JSON;
  const sandbox = {
    window: {},
    console,
    JSON: {
      parse: function (txt) {
        const obj = hostJSON.parse(txt);
        console.log('\n[4/4] 解密成功! JSON 键:', Object.keys(obj));
        if (obj.chapter_images) console.log('     章节图片数:', obj.chapter_images.length);
        if (obj.chapter_images) console.log('     前 3 张:', JSON.stringify(obj.chapter_images.slice(0, 3)));
        console.log('     图片域名:', JSON.stringify(obj.images_hosts) || obj.images_domain || obj.cdnurl);
        return obj;
      },
      stringify: hostJSON.stringify,
    },
  };
  sandbox.window.window = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(cryptoJsSrc, sandbox);

  const cjs = sandbox.CryptoJS;
  const origUtf8Parse = cjs.enc.Utf8.parse;
  cjs.enc.Utf8.parse = function (...args) {
    console.log('>>> AES 密钥(Utf8) =', JSON.stringify(args[0]));
    return origUtf8Parse.apply(this, args);
  };
  const origHexParse = cjs.enc.Hex.parse;
  cjs.enc.Hex.parse = function (...args) {
    console.log('>>> Hex.parse 入参长度 =', String(args[0]).length, '(IV/密文相关)');
    return origHexParse.apply(this, args);
  };
  const origAes = cjs.AES.decrypt;
  cjs.AES.decrypt = function (...args) {
    console.log('>>> AES.decrypt 密文长度 =', String((args[0] && args[0].ciphertext && args[0].ciphertext.sigBytes)));
    return origAes.apply(this, args);
  };

  vm.runInContext(cmsSrc, sandbox);
  sandbox.params = params;

  try {
    vm.runInContext('CMS.chapter.decrypt(params)', sandbox);
  } catch (e) {
    // 站点解密末尾有一次 window[字段] 校验，沙箱里 window 为空会抛错，但 AES 已解密完成
    console.log('(预期内) 末尾校验错误(不影响解密):', e.message);
  }

  const bytes = KYE_HEX.match(/.{2}/g).map((b) => String.fromCharCode(parseInt(b, 16))).join('');
  console.log('\nKYE_HEX 还原 =', JSON.stringify(bytes));
  console.log('校验(应与上面 AES 密钥一致):', bytes === '5V&RoR%Jf@pJPydF');
})();
