import { Clipboard } from "@wailsio/runtime";

/**
 * 复制文本到剪贴板。
 *
 * 顺序有讲究：WebView2 里 `navigator.clipboard` 与 `textarea + execCommand('copy')`
 * 都可能被直接拒绝（非安全上下文、缺少用户手势），所以先走 Wails 运行时的
 * `Clipboard.SetText`——它落到 Go 侧的操作系统剪贴板，不受 WebView 权限影响。
 * 后两条只在前者不可用时兜底（例如在浏览器里单独调试前端）。
 */
export async function copyText(text: string): Promise<boolean> {
  if (!text) return false;

  try {
    await Clipboard.SetText(text);
    return true;
  } catch {
    // 落到下面的浏览器实现
  }

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
