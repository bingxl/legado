/**
 * 复制文本到剪贴板。
 *
 * WebView 里 `navigator.clipboard` 不保证可用（非安全上下文、缺少权限时直接拒绝），
 * 所以失败后退回 `textarea + execCommand('copy')`——老 API 在 WebView 里反而稳。
 */
export async function copyText(text: string): Promise<boolean> {
  if (!text) return false;
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // 落到下面的兜底
  }

  const ta = document.createElement("textarea");
  ta.value = text;
  // 放在视口外，避免滚动跳动；不用 display:none，否则无法选中。
  ta.style.position = "fixed";
  ta.style.top = "-1000px";
  ta.style.opacity = "0";
  document.body.appendChild(ta);
  ta.select();
  let ok = false;
  try {
    ok = document.execCommand("copy");
  } catch {
    ok = false;
  }
  document.body.removeChild(ta);
  return ok;
}
