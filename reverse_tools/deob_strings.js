#!/usr/bin/env node
/**
 * deob_strings.js —— 混淆 JS 的字符串表还原器
 *
 * 用途：站点把逻辑做成控制流平坦化 + 字符串表（形如 _0x3363 = [...]），
 *      真正的文本由一个解码函数（形如 _0x3e45(index, key)）在运行时算出。
 *      逐行硬读几乎不可行，本脚本 mock 掉浏览器环境让脚本自己跑起来，
 *      再把每个解码调用替换成明文。
 *
 * 用法：
 *   node deob_strings.js obfuscated.js [-o deob.js]
 *
 * 输出：
 *   1) 所有还原出的字符串（去重，仅可打印的）
 *   2) 替换后的文件（若给 -o）
 *   3) 无法还原的调用（需要手动插桩时会提示）
 *
 * 说明：脚本对 DOM/jQuery 做了宽松 stub，混淆代码里的 UI 逻辑不会真的执行，
 *      只是为了让解码函数完成初始化。若目标代码是 IIFE 闭包包裹导致函数取不到，
 *      脚本会报 NO_GLOBAL_DECODER，此时改用「注入 hook」的方式（见 SOP §4.3）。
 */

const fs = require('fs');
const path = require('path');

function buildMocks() {
  const noop = () => chain;
  const chain = new Proxy(
    {
      length: 0,
      each() { return chain; },
      attr: (k) => (k === 'length' ? 0 : ''),
      data: () => '',
      val: () => '',
      text: () => '',
      html: () => '',
      append: () => chain,
      on: () => chain,
      click: () => chain,
      css: () => chain,
      find: () => chain,
      parent: () => chain,
      children: () => chain,
      eq: () => chain,
      prop: () => chain,
      show: () => chain,
      hide: () => chain,
      remove: () => chain,
      animate: () => chain,
    },
    { get: (t, k) => (k in t ? t[k] : noop) }
  );

  const $ = function (sel) {
    if (typeof sel === 'function') {
      try { sel(); } catch (e) { /* 忽略 UI 初始化错误 */ }
    }
    return chain;
  };
  $.post = () => ({ done: () => ({ fail: () => ({}) }), fail: () => ({}) });
  $.get = $.post;
  $.ajax = $.post;
  $.each = (a, f) => { if (a && a.length) for (let i = 0; i < a.length; i++) f(i, a[i]); return a; };
  $.extend = Object.assign;
  $.trim = (s) => String(s).trim();
  $.isEmptyObject = (o) => !o || !Object.keys(o).length;

  const store = {};
  const storage = {
    getItem: (k) => (k in store ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); },
    removeItem: (k) => { delete store[k]; },
  };

  global.window = global;
  global.self = global;
  global.$ = $;
  global.jQuery = $;
  global.document = {
    location: { href: 'https://example.com/', host: 'example.com', protocol: 'https:' },
    cookie: '',
    referrer: '',
    title: '',
    createElement: () => ({ style: {}, appendChild() {}, setAttribute() {} }),
    getElementById: () => chain,
    querySelector: () => chain,
    querySelectorAll: () => [],
    getElementsByTagName: () => [],
    getElementsByClassName: () => [],
    addEventListener() {},
    body: { appendChild() {}, style: {} },
  };
  global.location = global.document.location;
  global.navigator = { userAgent: 'Mozilla/5.0 (iPhone) AppleWebKit/605.1.15' };
  global.localStorage = storage;
  global.sessionStorage = storage;
  global.atob = (s) => Buffer.from(String(s), 'base64').toString('binary');
  global.btoa = (s) => Buffer.from(String(s), 'binary').toString('base64');
  global.CryptoJS = {
    MD5: (x) => ({ toString: () => '' }),
    enc: { Utf8: { parse: (x) => x, stringify: (x) => x }, Base64: { parse: (x) => x, stringify: () => '' } },
    AES: { decrypt: () => ({ toString: () => '' }), encrypt: () => ({ toString: () => '' }) },
    mode: { ECB: 0, CBC: 0 }, pad: { Pkcs7: 0, ZeroPadding: 0 },
  };
  global.setTimeout = (f) => { try { f(); } catch (e) {} return 0; };
  global.setInterval = () => 0;
  global.clearInterval = () => {};
}

function main() {
  const args = process.argv.slice(2);
  const file = args.find((x) => !x.startsWith('-'));
  if (!file) {
    console.error('用法: node deob_strings.js <obfuscated.js> [-o deob.js]');
    process.exit(1);
  }
  const outIdx = args.indexOf('-o');
  const outFile = outIdx > -1 ? args[outIdx + 1] : null;

  let code = fs.readFileSync(file, 'utf8');
  buildMocks();

  // 1) 让它跑起来（间接 eval → 全局作用域，var/function 会挂到 global）
  let evalErr = null;
  try {
    (0, eval)(code);
  } catch (e) {
    evalErr = e.message;
  }
  if (evalErr) console.log(`[!] 执行告警（可忽略，通常是无害的 DOM 调用）: ${evalErr}`);

  // 2) 找所有「两参字符串」调用，尝试求值
  const CALL = /(_0x[0-9a-fA-F]{3,})\(\s*(['"])([\s\S]{0,40}?)\2\s*,\s*(['"])([\s\S]{0,40}?)\4\s*\)/g;
  const results = new Map();
  let translated = 0, failed = 0;

  const replaced = code.replace(CALL, (whole, fn) => {
    if (results.has(whole)) {
      const v = results.get(whole);
      translated += v === null ? 0 : 1;
      return v === null ? whole : JSON.stringify(v);
    }
    // 直接对整个调用表达式求值：既覆盖全局函数，也覆盖挂到 window 上的情况
    let val = null;
    try { val = (0, eval)(whole); } catch (e) { val = null; }
    results.set(whole, typeof val === 'string' ? val : null);
    if (typeof val === 'string') { translated++; return JSON.stringify(val); }
    failed++;
    return whole;
  });

  const readable = [...new Set([...results.values()].filter((v) => v && /^[\x20-\x7e\u4e00-\u9fa5]{1,120}$/.test(v)))];
  console.log(`[+] 解码调用: 成功 ${translated}，失败 ${failed}，去重可读字符串 ${readable.length}`);
  if (!readable.length) {
    console.log('[!] NO_GLOBAL_DECODER：解码函数在闭包里取不到。');
    console.log('    改用注入 hook：在 eval 前包一层 atob/String.fromCharCode/split 打日志，见 SOP §4.3');
  }
  readable.slice(0, 300).forEach((s) => console.log('  ' + JSON.stringify(s)));

  // 3) 报出候选密钥表：短 base64 字符串
  //    来源 = 已解码字符串 ∪ 原文里的字面量（有些常量没走解码函数）
  //    判据：含 padding/加号，或同时含大小写与数字（排除 fromCharCode 这类驼峰词）
  const isB64ish = (s) =>
    /^[A-Za-z0-9+/]{6,16}={0,2}$/.test(s) && (s.includes('=') || s.includes('+') || /\d/.test(s));
  const literal = [...code.matchAll(/"([A-Za-z0-9+/]{6,16}={0,2})"/g)].map((m) => m[1]);
  const b64s = [...new Set([...readable.filter(isB64ish), ...literal.filter(isB64ish)])];
  if (b64s.length >= 3) console.log(`[+] 可疑 base64 常量 ${b64s.length} 个（可能是密钥表）: ${b64s.join(' ')}`);

  if (outFile) {
    fs.writeFileSync(outFile, replaced, 'utf8');
    console.log(`[+] 已写入 ${path.basename(outFile)} (${replaced.length} chars)`);
  }
}

main();
