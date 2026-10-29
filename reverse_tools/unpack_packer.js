#!/usr/bin/env node
/**
 * unpack_packer.js —— Dean Edwards Packer 解包器
 *
 * 用途：站点把关键逻辑/数据用 eval(function(p,a,c,k,e,d){...}(...)) 打包后内联，
 *      浏览器可执行但人不可读。本脚本不解密、不执行，纯粹按 packer 的编码规则
 *      反查字典还原明文（与浏览器执行结果完全等价）。
 *
 * 用法：
 *   node unpack_packer.js <input.html|input.js>            # 打印第一个 packer 块的明文
 *   node unpack_packer.js <input> -o out.js                # 写入文件
 *   node unpack_packer.js <input> --all                    # 解出文件内所有 packer 块
 *
 * 原理：
 *   p = 压缩后的代码模板，a = 进制，c = 字典长度，k = 字典（按 | 切分）
 *   字典下标 i 的字符串形式由 e(i) 计算（a 进制，>35 用 chr(i+29)，否则 base36）
 *   最后把 p 中的每个 \b\w+\b 按字典替换。
 */

const fs = require('fs');

function dec(c, a) {
  // packer 的下标编码：小于 a 时递归，>35 走 fromCharCode，否则 base36
  const f = (x) =>
    (x < a ? '' : f(Math.floor(x / a))) +
    (x % a > 35 ? String.fromCharCode((x % a) + 29) : (x % a).toString(36));
  return f(c);
}

const PATTERN =
  /eval\(function\(p,a,c,k,e,[dr]\)\{[\s\S]*?\}\('([\s\S]*?)',(\d+),(\d+),'([\s\S]*?)'\.split\('([^']*)'\)/g;

function unpackOne(m) {
  const p = m[1];
  const a = parseInt(m[2], 10);
  const c = parseInt(m[3], 10);
  const k = m[4].split(m[5] || '|');
  const dict = {};
  for (let i = c - 1; i >= 0; i--) {
    const key = dec(i, a);
    dict[key] = k[i] && k[i].length ? k[i] : key;
  }
  return p.replace(/\b\w+\b/g, (w) => (dict[w] !== undefined ? dict[w] : w));
}

function main() {
  const args = process.argv.slice(2);
  const file = args.find((x) => !x.startsWith('-'));
  if (!file) {
    console.error('用法: node unpack_packer.js <input> [-o out.js] [--all]');
    process.exit(1);
  }
  const outIdx = args.indexOf('-o');
  const outFile = outIdx > -1 ? args[outIdx + 1] : null;
  const all = args.includes('--all');

  const src = fs.readFileSync(file, 'utf8');
  const blocks = [];
  let m;
  PATTERN.lastIndex = 0;
  while ((m = PATTERN.exec(src)) !== null) blocks.push(unpackOne(m));

  if (!blocks.length) {
    console.error('[!] 未找到 packer 块。检查特征串: eval(function(p,a,c,k,e,d)');
    process.exit(2);
  }
  console.log(`[+] 找到 ${blocks.length} 个 packer 块`);
  const result = all ? blocks.join('\n\n/* ===== 下一块 ===== */\n\n') : blocks[0];

  // 顺手把可疑的长变量/长字符串报出来，方便下一步找载荷
  const longVars = [...result.matchAll(/var\s+(\w+)\s*=\s*"([A-Za-z0-9+/=]{80,})"/g)].map(
    (x) => `  ${x[1]}  (${x[2].length} chars)`
  );
  if (longVars.length) {
    console.log('[+] 可疑的长 base64 变量:');
    longVars.forEach((l) => console.log(l));
  }

  if (outFile) {
    fs.writeFileSync(outFile, result, 'utf8');
    console.log(`[+] 已写入 ${outFile} (${result.length} chars)`);
  } else {
    console.log('----- 解包结果 -----');
    console.log(result);
  }
}

main();
