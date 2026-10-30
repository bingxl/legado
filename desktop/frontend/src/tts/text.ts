/**
 * 朗读文本的净化与切分（纯函数，不碰 DOM）。
 *
 * 书源正文里混着大量「念出来很荒谬」的东西：站点广告、页码、分隔线、
 * 还有些排版导致的汉字之间莫名多一个空格（PDF 抽取尤其常见）。
 * 全部在此处收敛，文本类与 PDF 两条路径共用，避免各写一份。
 */

/** 单段最多字符数；超过就在句末标点处二次切句。 */
export const MAX_SEGMENT_CHARS = 180;

/** 零宽字符、软连字符、方向控制符：肉眼不可见，但会让 TTS 停顿或读出怪音。 */
const INVISIBLE = /[\u200b-\u200f\u202a-\u202e\u2060\ufeff\u00ad]/g;

/**
 * CJK 字符区段：部首、假名/标点、扩展 A、基本区、兼容汉字、全角符号。
 * 用于「两个 CJK 字符之间的空格一定是排版噪音」这条判断。
 */
const CJK_RANGES =
  "\\u2e80-\\u303f\\u3040-\\u30ff\\u3400-\\u4dbf\\u4e00-\\u9fff\\uf900-\\ufaff\\uff00-\\uffef";

/** 两个 CJK 字符之间夹的空白：直接删掉（`中 文` → `中文`）。 */
const CJK_GAP = new RegExp(`([${CJK_RANGES}])[ \\t]+(?=[${CJK_RANGES}])`, "g");

/** 整行都是噪音时，该段没有朗读价值。 */
const NOISE_LINES: RegExp[] = [
  /^请收藏本站.*$/,
  /^本章未完.*$/,
  /^最新网址.*$/,
  /^手机用户请浏览.*$/,
  /^本站[^，。]{0,12}(网址|域名|地址)[^，。]*$/,
  /^[（(【[]?\s*本章完\s*[）)】\]]?$/,
  /^[（(【[]?(未完待续|求推荐票|求月票|求收藏)[）)】\]]?$/,
  /^[（(【[]?[^（）()【】[\]]{0,20}(本章由|本站首发|网友上传)[^（）()【】[\]]{0,20}[）)】\]]$/,
  /^[-=*_—–~·+.]{3,}$/,
  /^\d{1,4}\s*\/\s*\d{1,4}$/,
  /^第?\s*\d{1,4}\s*页$/,
  /^https?:\/\/\S+$/i,
  /^www\.[^\s]+$/i,
];

/** 纯标点/纯符号行（`***`、单独的 `……`）念出来只有杂音。 */
const PUNCT_ONLY = /^[\p{P}\p{S}\s]+$/u;

/**
 * 归一化：去不可见字符、空白归一、修 CJK 粘连、修标点。
 *
 * 顺序有讲究：先清不可见字符，再归一空白（否则 `\u00a0` 会绕过压缩），
 * 最后才处理标点（`……` → `，` 之后可能出现 `，，` 需要去重）。
 */
export function normalizeSpeechText(raw: string): string {
  if (!raw) return "";
  let s = raw.replace(INVISIBLE, "");
  // 不间断空格、全角空格一律当普通空格，后面统一压缩。
  s = s.replace(/[\u00a0\u3000]/g, " ");
  s = s.replace(/\s+/g, " ");
  // 反复替换直到稳定：`中 文 字` 这类连在一起的多个空隙会跨过前一次匹配。
  for (let i = 0; i < 3; i++) {
    const next = s.replace(CJK_GAP, "$1");
    if (next === s) break;
    s = next;
  }
  // 标点前不该有空格。
  s = s.replace(/ +([，。！？；：、）】」』”’])/g, "$1");
  // 省略号/破折号念起来是长停顿，统一成逗号更自然。
  s = s.replace(/(?:…\s*){2,}/g, "，").replace(/—{2,}/g, "，");
  // 重复标点归一（`，，` → `，`，`！！` → `！`）。
  s = s.replace(/([，。！？；：、])\1+/g, "$1");
  // `，。` 这种残渣只保留句末标点。
  s = s.replace(/[，、；：]+([。！？])/g, "$1");
  // 再清一次「标点前空格」，因为上一步替换可能留下。
  s = s.replace(/ +([，。！？；：、）】」』”’])/g, "$1");
  return s.trim();
}

/** 是否整行噪音（站点广告、页码、分隔线、纯符号）。 */
export function isNoiseLine(line: string): boolean {
  const s = line.trim();
  if (!s) return true;
  if (PUNCT_ONLY.test(s)) return true;
  return NOISE_LINES.some((re) => re.test(s));
}

/**
 * 送进 TTS 前的一道净化：归一化 + 丢弃噪音行。
 * 返回空串表示这段不该念，调用方应跳过。
 */
export function purifyForSpeech(raw: string): string {
  const s = normalizeSpeechText(raw);
  if (!s || isNoiseLine(s)) return "";
  return s;
}

/** 按标点把文本切成「原子片段」，标点留在前一片段的末尾。 */
function atoms(text: string, re: RegExp): string[] {
  const out: string[] = [];
  let last = 0;
  for (const m of text.matchAll(re)) {
    const end = (m.index ?? 0) + m[0].length;
    out.push(text.slice(last, end));
    last = end;
  }
  if (last < text.length) out.push(text.slice(last));
  return out.filter((s) => s.length > 0);
}

/** 贪心装箱：拼到不超过 maxLen；单个原子仍超长就硬切。 */
function pack(parts: string[], maxLen: number): string[] {
  const out: string[] = [];
  let buf = "";
  for (const p of parts) {
    if (buf && buf.length + p.length > maxLen) {
      out.push(buf);
      buf = "";
    }
    buf += p;
    while (buf.length > maxLen) {
      out.push(buf.slice(0, maxLen));
      buf = buf.slice(maxLen);
    }
  }
  if (buf) out.push(buf);
  return out;
}

/**
 * 超长段落按句末标点二次切句。
 *
 * 为什么要切：Chromium 对超长 utterance 有截断/卡死的已知问题，
 * 而且切句之后「上一段/下一段」的粒度也更符合直觉。
 * 切句**不影响高亮粒度**（切出来的几段共享同一个元素）。
 */
export function splitLongText(
  text: string,
  maxLen: number = MAX_SEGMENT_CHARS,
): string[] {
  if (!text) return [];
  if (text.length <= maxLen) return [text];
  let parts = atoms(text, /[。！？；!?;…]+/g);
  // 单句仍超长：退到逗号级再切一次。
  parts = parts.flatMap((p) => (p.length > maxLen ? atoms(p, /[，,、：:]/g) : [p]));
  return pack(parts, maxLen);
}
