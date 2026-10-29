#!/usr/bin/env node
/**
 * Legado 书源 JS 本地测试桩（无需打包 app / 无需 Android 环境）
 *
 * 用途：单独测试书源里 `@js:` / `<js>...</js>` / `{{...}}` 的 JS 逻辑
 *      （字符串处理、正则、JSON、加密解密、抓包后的数据处理等）。
 *      注意：CSS/XPath 规则引擎、WebView、cookie 持久化、跨规则变量存储
 *      等依赖 Android 的能力这里只做最小桩，完整走规则流水线请用 app 调试。
 *
 * 用法：
 *   node scripts/test_source_js.js <js文件>
 *       --src '页面源码...'            # 注入 src / result（不传则用 --result）
 *       --src@file path               # 从文件读页面源码
 *       --result '...'                # 注入 result
 *       --baseUrl 'https://...'       # 注入 baseUrl
 *       --book '{"name":"x"}'         # 注入 book（JSON）
 *       --chapter '{"title":"x"}'     # 注入 chapter（JSON）
 *       --js 'inline code'            # 直接给内联代码（代替文件）
 *       --print                       # 用 java.log 打印返回结果
 *
 * 示例：
 *   node scripts/test_source_js.js --js 'java.base64Encode("hello")' --print
 *   node scripts/test_source_js.js my.js --src@file page.html --baseUrl https://site.com --print
 *
 * 已实现的 java.* 桩：log, logType, strToBytes, bytesToStr,
 *   base64Encode/Decode/DecodeToByteArray, hexDecodeToByteArray,
 *   hexEncodeToString, hexDecodeToString, md5Encode, md5Encode16,
 *   createSymmetricCrypto (AES/DES/3DES/RC4), encodeURI, encodeURIComponent,
 *   getString/setContent(仅 JS 与 JSON 规则子集), ajax/get/post/connect(走真网络),
 *   put/get(内存变量)。
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------- args
function parseArgs(argv) {
  const o = { positionals: [], flags: new Set() };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--print') o.flags.add('print');
    else if (a.startsWith('--src=')) o.src = a.slice(6);
    else if (a.startsWith('--src@file=')) o.srcFile = a.slice(11);
    else if (a.startsWith('--result=')) o.result = a.slice(9);
    else if (a.startsWith('--baseUrl=')) o.baseUrl = a.slice(10);
    else if (a.startsWith('--book=')) o.book = a.slice(7);
    else if (a.startsWith('--chapter=')) o.chapter = a.slice(10);
    else if (a === '--js') o.inlineJs = argv[++i];
    else o.positionals.push(a);
  }
  return o;
}
const opts = parseArgs(process.argv.slice(2));

let jsCode;
if (opts.inlineJs) jsCode = opts.inlineJs;
else if (opts.positionals[0]) jsCode = fs.readFileSync(opts.positionals[0], 'utf8');
else {
  console.error('用法见脚本头部注释。需要 <js文件> 或 --js <代码>。');
  process.exit(1);
}
// 去掉 @js: / <js>...</js> 外壳
jsCode = jsCode.replace(/^@js:\s*/s, '').replace(/^<js>([\s\S]*?)<\/js>$/, '$1');

let src = opts.src;
if (opts.srcFile) src = fs.readFileSync(opts.srcFile, 'utf8');
let result = opts.result !== undefined ? opts.result : src;

// ---------------------------------------------------------------- helpers
const hexRe = /^(?:[0-9a-fA-F]{2})+$/;
const toBuffer = (k) => {
  if (Buffer.isBuffer(k)) return k;
  if (Array.isArray(k) || (k && k.buffer instanceof ArrayBuffer)) return Buffer.from(k);
  if (typeof k === 'string') return Buffer.from(k, 'utf8');
  return Buffer.from(k || []);
};

// ---------------------------------------------------------------- SymmetricCrypto 桩
function createSymmetricCrypto(transformation, key, iv) {
  const [algo, mode = 'ECB', pad = 'PKCS5Padding'] = String(transformation).split('/');
  const keyBuf = toBuffer(key);
  let nodeAlgo;
  const U = algo.toUpperCase();
  if (U === 'AES') nodeAlgo = `aes-${keyBuf.length * 8}-${mode.toLowerCase()}`;
  else if (U === 'DES') nodeAlgo = `des-${mode.toLowerCase()}`;
  else if (U === 'DESEDE' || U === '3DES' || U === 'TRIPLEDES') nodeAlgo = `des-ede3-${mode.toLowerCase()}`;
  else if (U === 'RC4') nodeAlgo = 'rc4';
  else throw new Error(`未支持的算法 ${algo}（桩仅支持 AES/DES/3DES/RC4）`);
  const ivBuf = iv ? toBuffer(iv) : null;
  const noPad = /nopadding/i.test(pad);
  const mkCipher = (enc) => {
    const args = [nodeAlgo, keyBuf];
    if (ivBuf) args.push(ivBuf);
    const c = crypto[enc ? 'createCipheriv' : 'createDecipheriv'](...args);
    if (noPad) c.setAutoPadding(false);
    return c;
  };
  const norm = (data) => {
    // 与 Legado SymmetricCryptoAndroid.decrypt 一致：合法 hex 当 hex，否则当 base64
    if (typeof data === 'string' && hexRe.test(data)) return Buffer.from(data, 'hex');
    return Buffer.isBuffer(data) ? data : Buffer.from(data || '', 'base64');
  };
  const padBlock = (b, size) => {
    const rem = size - (b.length % size);
    return Buffer.concat([b, Buffer.alloc(rem, rem % size === 0 ? 0 : rem)]);
  };
  return {
    decrypt(data) {
      let b = norm(data);
      if (noPad && nodeAlgo.includes('-ecb')) b = padBlock(b, 16); // ECB 需要整块
      const d = mkCipher(false);
      return Buffer.concat([d.update(b), d.final()]);
    },
    decryptStr(data) {
      return this.decrypt(data).toString('utf8');
    },
    encrypt(data) {
      let b = Buffer.isBuffer(data) ? data : Buffer.from(String(data), 'utf8');
      if (noPad && !ivBuf) b = padBlock(b, 16);
      const e = mkCipher(true);
      return Buffer.concat([e.update(b), e.final()]);
    },
    encryptBase64(data) {
      return this.encrypt(data).toString('base64');
    },
    encryptHex(data) {
      return this.encrypt(data).toString('hex');
    },
  };
}

// ---------------------------------------------------------------- java.* 桩
const java = {
  log(msg) {
    console.log('>>>', msg);
    return msg;
  },
  logType(v) {
    console.log('>>> type of', v, '=', typeof v);
  },
  strToBytes(str, charset) {
    return Buffer.from(str, charset || 'utf8');
  },
  bytesToStr(bytes, charset) {
    return Buffer.from(bytes).toString(charset || 'utf8');
  },
  base64Encode(str) {
    return Buffer.from(String(str), 'utf8').toString('base64');
  },
  base64Decode(str, charset) {
    return Buffer.from(String(str), 'base64').toString(charset || 'utf8');
  },
  base64DecodeToByteArray(str) {
    return Buffer.from(String(str), 'base64');
  },
  base64DecodeToByteArray(str, flags) {
    return Buffer.from(String(str), 'base64');
  },
  hexDecodeToByteArray(hex) {
    return Buffer.from(hex, 'hex');
  },
  hexDecodeToString(hex) {
    return Buffer.from(hex, 'hex').toString('utf8');
  },
  hexEncodeToString(utf8) {
    return Buffer.from(String(utf8), 'utf8').toString('hex');
  },
  md5Encode(str) {
    return crypto.createHash('md5').update(String(str), 'utf8').digest('hex');
  },
  md5Encode16(str) {
    return this.md5Encode(str).slice(8, 24);
  },
  createSymmetricCrypto,
  encodeURI,
  encodeURIComponent,
  // 规则子集：仅支持 JS 与 JSONPath；CSS/XPath 会明确报"请用 app 调试"
  setContent(content) {
    this._content = content;
  },
  getString(rule, content) {
    return getStringStub(rule, content === undefined ? this._content : content);
  },
  put(k, v) {
    vars[k] = v;
  },
  get(k) {
    return vars[k];
  },
  // 真实网络
  async ajax(url) {
    const r = await fetch(url);
    return r.text();
  },
  async connect(url, header) {
    const r = await fetch(url, header ? { headers: JSON.parse(header) } : {});
    return {
      code: () => r.status,
      body: () => r.text(),
      headers: () => Object.fromEntries(r.headers),
    };
  },
  async get(url, headers) {
    const r = await fetch(url, headers ? { headers: JSON.parse(headers) } : {});
    return r.text();
  },
  async post(url, body, headers) {
    const r = await fetch(url, {
      method: 'POST',
      body,
      headers: headers ? JSON.parse(headers) : {},
    });
    return r.text();
  },
};

// JSONPath 最小实现（$.a.b[0].c）
function jsonPath(obj, pathStr) {
  let cur = obj;
  const parts = pathStr
    .replace(/^\$\.?/, '')
    .split('.')
    .filter(Boolean);
  for (const p of parts) {
    const m = p.match(/^(.+?)\[(\d+)\]$/);
    if (m) {
      cur = cur?.[m[1]]?.[Number(m[2])];
    } else {
      cur = cur?.[p];
    }
    if (cur === undefined) return null;
  }
  return cur;
}

function getStringStub(rule, content) {
  rule = String(rule || '').trim();
  if (!rule) return '';
  if (rule.startsWith('@js:') || rule.startsWith('<js>') || rule.startsWith('{{')) {
    const code = rule.replace(/^@js:\s*/s, '').replace(/^<js>([\s\S]*?)<\/js>$/, '$1').replace(/^\{\{([\s\S]*)\}\}$/, '$1');
    return runJs(code, content);
  }
  if (rule.startsWith('@Json:') || rule.startsWith('$.') || rule.startsWith('$[')) {
    const p = rule.replace(/^@Json:\s*/, '');
    const c = typeof content === 'string' ? JSON.parse(content) : content;
    return String(jsonPath(c, p) ?? '');
  }
  return `【桩不支持该规则类型，请用 app 调试】${rule}`;
}

// ---------------------------------------------------------------- 全局环境
const vars = {};
const source = {
  getKey: () => 'test-source',
  getVariable: (k) => vars['v:' + k],
  setVariable: (k, v) => (vars['v:' + k] = v),
  put: (k, v) => (vars[k] = v),
  get: (k) => vars[k],
  getHeaderMap: () => ({}),
};
const cookie = {
  jar: {},
  getCookie: (url) => cookie.jar[url] || '',
  setCookie: (url, c) => (cookie.jar[url] = c),
};
const cache = {
  store: {},
  put: (k, v) => (cache.store[k] = v),
  get: (k) => cache.store[k],
  putMemory: (k, v) => (cache.store['m:' + k] = v),
  getFromMemory: (k) => cache.store['m:' + k],
};

let book = null, chapter = null, baseUrl = '', title = '', nextChapterUrl = '';
try { if (opts.book) book = JSON.parse(opts.book); } catch (e) { console.error('--book 不是合法 JSON'); process.exit(1); }
try { if (opts.chapter) chapter = JSON.parse(opts.chapter); } catch (e) { console.error('--chapter 不是合法 JSON'); process.exit(1); }
baseUrl = opts.baseUrl || '';
title = chapter && chapter.title;

// 参考 AnalyzeRule.evalJS 的注入变量
const env = {
  java,
  source,
  cookie,
  cache,
  book,
  chapter,
  result,
  src,
  baseUrl,
  title,
  nextChapterUrl,
};

function runJs(code, res) {
  const fn = new Function(
    ...Object.keys(env),
    `"use strict";\n(function(){\n${code}\n})()`
  );
  return fn(...Object.values(env).map((v, i) => {
    // result 用本次传入的 res 覆盖
    return i === Object.keys(env).indexOf('result') && res !== undefined ? res : v;
  }));
}

// ---------------------------------------------------------------- 执行
(async () => {
  const out = runJs(jsCode, result);
  if (out && typeof out.then === 'function') {
    const v = await out;
    if (opts.flags.has('print')) java.log(v);
  } else if (opts.flags.has('print')) {
    java.log(out);
  }
})().catch((e) => {
  console.error('执行出错:', e);
  process.exit(1);
});
