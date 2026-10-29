/**
 * 后端调用的公共工具。
 *
 * 所有对 Wails 绑定的调用都经由本文件的 `call` 包装，
 * 目的是把后端的错误统一转换成前端可直接展示的消息，
 * 避免每个页面重复写 try/catch。
 */

/** 把未知错误规整为可展示的中文消息。 */
export function toMessage(err: unknown): string {
  if (err == null) return "未知错误";
  if (typeof err === "string") return err;
  if (err instanceof Error) return err.message || "请求失败";
  if (typeof err === "object" && "message" in err) {
    return String((err as { message: unknown }).message);
  }
  return String(err);
}

/**
 * 执行后端调用并规整错误。
 *
 * 不吞掉异常：调用方仍需自行决定是否提示用户，
 * 这里只保证异常一定是 Error 且消息可读。
 */
export async function call<T>(promise: Promise<T>): Promise<T> {
  try {
    return await promise;
  } catch (err) {
    throw new Error(toMessage(err));
  }
}

/**
 * 执行返回列表的后端调用。
 *
 * Go 的 nil slice 经 JSON 序列化成 null，绑定层因此把返回类型标成 `T[] | null`。
 * 页面只关心「有没有数据」，所以统一收敛成空数组，省掉每处 `?? []`。
 */
export async function callList<T>(
  promise: Promise<T[] | null>,
): Promise<T[]> {
  try {
    const res = await promise;
    return res ?? [];
  } catch (err) {
    throw new Error(toMessage(err));
  }
}
