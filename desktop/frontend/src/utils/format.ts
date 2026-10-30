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
