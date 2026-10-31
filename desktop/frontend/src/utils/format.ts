/** 展示格式化工具（容量、时间）。 */

/** 把字节数格式化成人类可读的容量。 */
export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  // 小于 10 的保留一位小数（整数则不带小数点），其余取整——缓存大小读起来够用即可。
  const text =
    value >= 10 || i === 0
      ? String(Math.round(value))
      : Number.isInteger(value)
        ? String(value)
        : value.toFixed(1);
  return `${text} ${units[i]}`;
}

/** 把 RFC3339 字符串格式化成「MM-DD HH:mm」；无效值返回空串。 */
export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/**
 * 从 AI 引用摘录里取一段「能在正文里定位」的片段。
 *
 * 为什么要单独处理：摘录是切片的开头若干字，可能含换行。阅读器把正文按段
 * 渲染成多个节点，`indexOf` 无法跨节点匹配，带换行的片段永远高亮不上。
 * 取第一行、去空白、限长，落到单个段落里才能命中。
 */
export function citeFragment(excerpt: string, limit = 24): string {
  if (!excerpt) return "";
  const firstLine = excerpt
    .split(/\r?\n/)
    .map((s) => s.trim())
    .find((s) => s.length > 0);
  if (!firstLine) return "";
  return Array.from(firstLine).slice(0, limit).join("");
}
