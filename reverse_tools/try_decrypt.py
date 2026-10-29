#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
try_decrypt.py —— 链式解码试探器

用途：遇到「密文 + 疑似密钥表」时，不要手写一堆 if，用本脚本把常见链一次跑完，
      命中后打印可读结果。跑通链式算法后再考虑移植到 Legado 的 JS 规则。

用法：
  # 单条密文，密钥表用逗号分隔，逐个试
  python try_decrypt.py "eyJhbGci..." --keys "c21raHkyNTg=,c21rZDk1ZnY=" --chain b64,xor,b64

  # 从 HTML 里抓长 base64 变量，配合 index（如 data-id）只试第 N 个
  python try_decrypt.py --html page.html --keys-file keys.txt --chain b64,xor,b64 --index 9

  # 显式给密钥明文（脚本会自动判断是否需要先解 base64）
  python try_decrypt.py "cipher" --key "5ko6plhy" --chain b64,xor,b64

支持的链元素：
  b64    base64 解码
  xor    与 key 逐字节循环异或（key 会自动尝试 base64 解码后的形式）
  hex    hex 解码
  url    URL 解码
  rev    字符串反转

判定：解出的 bytes 能被 UTF-8 解码，且 80% 以上字符可打印 → 视为命中；
      若还能 json.loads，直接格式化输出。
"""

import argparse
import base64
import binascii
import json
import re
import sys
import urllib.parse


def try_b64(data: bytes) -> bytes:
    s = data.strip()
    s += b"=" * (-len(s) % 4)
    return base64.b64decode(s, validate=False)


def try_xor(data: bytes, key: bytes) -> bytes:
    if not key:
        raise ValueError("empty key")
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))


def printable_ratio(data: bytes) -> float:
    if not data:
        return 0.0
    ok = sum(1 for b in data if 32 <= b < 127 or b in (9, 10, 13) or b >= 0xE0 or 0x80 <= b < 0xC0)
    return ok / len(data)


def run_chain(data: bytes, chain, key: bytes | None):
    cur = data
    for step in chain:
        if step == "b64":
            cur = try_b64(cur)
        elif step == "xor":
            if key is None:
                raise ValueError("xor 需要 --key")
            cur = try_xor(cur, key)
        elif step == "hex":
            cur = binascii.unhexlify(cur.strip())
        elif step == "url":
            cur = urllib.parse.unquote_to_bytes(cur).decode("latin-1").encode("utf-8", "ignore")
        elif step == "rev":
            cur = cur[::-1]
        else:
            raise ValueError(f"未知步骤: {step}")
    return cur


PACKER_RE = re.compile(
    r"eval\(function\(p,a,c,k,e,[dr]\)\{.*?\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split\('([^']*)'\)",
    re.S,
)
_B36 = "0123456789abcdefghijklmnopqrstuvwxyz"


def _packer_index(c: int, a: int) -> str:
    head = "" if c < a else _packer_index(c // a, a)
    r = c % a
    return head + (chr(r + 29) if r > 35 else _B36[r])


def unpack_packer(text: str) -> str:
    """把页面里的 Dean Edwards Packer 块还原为明文，拼回原文本（原地替换）"""
    def one(m):
        p, a, c, k, sep = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4), m.group(5) or "|"
        words = k.split(sep)
        table = {}
        for i in range(c - 1, -1, -1):
            key = _packer_index(i, a)
            table[key] = words[i] if i < len(words) and words[i] else key
        return re.sub(r"\b\w+\b", lambda mo: table.get(mo.group(0), mo.group(0)), p)

    return PACKER_RE.sub(one, text)


def report(out: bytes, key_label: str, chain_label: str) -> bool:
    """命中判定：JSON 可解析 > 含 http/尖括号 > 高可打印率的长 ASCII"""
    if printable_ratio(out) < 0.9:
        return False
    try:
        text = out.decode("utf-8")
    except UnicodeDecodeError:
        return False
    looks_json = text.lstrip()[:1] in "[{"
    looks_url = "http" in text or "<img" in text
    if not ((looks_json and len(text) > 8) or looks_url):
        return False
    print(f"\n[命中] chain={chain_label}  key={key_label}  len={len(out)}")
    try:
        obj = json.loads(text)
        print(json.dumps(obj, ensure_ascii=False, indent=2)[:2000])
    except Exception:
        print(text[:2000])
    return True


def extract_candidates(html: str):
    """从页面里抓候选：长 base64 串、data-id、以及一批短 base64 常量"""
    longs = []
    for m in re.finditer(r'var\s+(\w+)\s*=\s*"([A-Za-z0-9+/=%]{80,})"', html):
        longs.append((m.group(1), m.group(2)))
    for m in re.finditer(r'([A-Za-z0-9+/]{80,}={0,2})', html):
        if not any(m.group(1) in v for _, v in longs):
            longs.append(("inline", m.group(1)))
    idx = None
    m = re.search(r'data-id="(\d+)"', html) or re.search(r'data-id=\'(\d+)\'', html)
    if m:
        idx = int(m.group(1))
    short = sorted({m.group(0) for m in re.finditer(r'"[A-Za-z0-9+/]{6,12}={0,2}"', html)})
    return longs, idx, [s.strip('"') for s in short]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cipher", nargs="?", help="密文字符串")
    ap.add_argument("--html", help="从 HTML 文件里自动提取长 base64 变量")
    ap.add_argument("--keys", help="密钥列表，逗号分隔（通常是 base64）")
    ap.add_argument("--keys-file", help="每行一个密钥")
    ap.add_argument("--key", help="单个密钥（明文或 base64）")
    ap.add_argument("--chain", default="b64,xor,b64", help="解码链，默认 b64,xor,b64")
    ap.add_argument("--index", type=int, help="只试密钥表第 N 个（对应页面里的 data-id）")
    ap.add_argument("--dump-keys", action="store_true", help="只打印从 HTML 抽到的候选常量")
    args = ap.parse_args()

    chain = [s.strip() for s in args.chain.split(",") if s.strip()]

    keys = []
    if args.key:
        keys = [args.key]
    if args.keys:
        keys += [k.strip() for k in args.keys.split(",") if k.strip()]
    if args.keys_file:
        with open(args.keys_file, encoding="utf-8") as f:
            keys += [ln.strip() for ln in f if ln.strip()]

    payloads = []
    if args.html:
        raw = open(args.html, encoding="utf-8", errors="ignore").read()
        html = unpack_packer(raw)
        if html != raw:
            print("[i] 检测到 packer 块，已自动解包后再提取载荷")
        longs, idx, short = extract_candidates(html)
        if args.dump_keys:
            print("[长 base64 变量]")
            for n, v in longs:
                print(f"  {n}  ({len(v)} chars)  {v[:40]}...")
            print(f"[data-id] {idx}")
            print(f"[短 base64 常量] {len(short)} 个: {' '.join(short)}")
            return
        if args.index is not None:
            idx = args.index
        payloads = [(n, v) for n, v in longs]
        if not keys:
            keys = short
            print(f"[i] 未给密钥，改用页面内的 {len(short)} 个短 base64 常量")
        if idx is not None and 0 <= idx < len(keys):
            keys = keys[idx:] + keys[:idx]   # 把 data-id 指向的那个提前
            print(f"[i] data-id={idx} → 优先试 {keys[0]}")
    elif args.cipher:
        payloads = [("cli", args.cipher)]
    else:
        ap.error("需要 cipher 或 --html")

    if not keys:
        print("[!] 没有密钥，无法试 xor。用 --keys 或 --keys-file 提供。")
        sys.exit(1)

    hit = 0
    for name, payload in payloads:
        data = payload.encode()
        for ki, k in enumerate(keys):
            # 密钥可能以 base64 形式给出（如 yumanhua 的 KEYS），明文与原样都要试
            candidates = [k.encode()]
            try:
                candidates.append(try_b64(k.encode()))
            except Exception:
                pass
            for key_bytes in candidates:
                try:
                    out = run_chain(data, chain, key_bytes)
                except Exception:
                    continue
                label = k if len(k) < 30 else k[:20] + "..."
                if report(out, f"[{ki}] {label}", ",".join(chain)):
                    hit += 1
                    break
            if hit:
                break
        if hit:
            break

    if not hit:
        print("[x] 全部未命中。建议：确认 chain 顺序、换 --chain 组合（如 b64,rev,b64）、"
              "或密钥需要先做 md5/时间戳派生。")


if __name__ == "__main__":
    main()
