/**
 * 纯文本正文按行渲染成段落。
 *
 * 为什么需要：部分书源的正文规则直接返回**一段带换行的纯文本**（本地实测
 * `langrenxiaoshuo.com` 就是），不带任何 `<p>`。直接塞进 `v-html` 时，
 * 浏览器在 `white-space: normal` 下把换行全折叠成空格 —— 读者看到的是一整面墙，
 * 朗读切段也只能切出一整块（高亮等于整章）。
 *
 * 处理策略非常保守：**只有整段 HTML 里一个标签都没有时才转换**，
 * 有标签的一律原样返回（EPUB、漫画、绝大多数书源都不受影响）。
 */

/** 是否含有真正的 HTML 标签（`<p>`、`<br/>`、`<!-- -->` 都算）。 */
const HAS_TAG = /<\/?[a-zA-Z][^>]*>|<!--/;

/** HTML 转义，避免把正文里的 `<` `&` 当标签。 */
function escapeHTML(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

/**
 * 纯文本 → `<p>` 段落。含标签的 HTML 原样返回。
 *
 * 每行开头的全角空格是书源自带的缩进，会与 CSS 的 `text-indent` 叠加成双倍缩进，
 * 所以一并去掉。
 */
export function wrapPlainTextAsParagraphs(html: string): string {
  if (!html) return "";
  if (HAS_TAG.test(html)) return html;

  const lines = html.split(/\r?\n/);
  const out: string[] = [];
  for (const line of lines) {
    const text = line.replace(/^[\s\u3000]+/, "").trimEnd();
    if (!text) continue;
    out.push(`<p>${escapeHTML(text)}</p>`);
  }
  return out.join("");
}
