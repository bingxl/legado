/** 书源（含漫画源）登录 API。 */
import * as binding from "@bindings/github.com/legado/desktop/api/sourceloginapi";
import type {
  LoginFieldView,
  LoginProbeView,
  LoginResult,
  SourceLoginView,
} from "@bindings/github.com/legado/desktop/internal/app/dto/models";
import { call } from "./client";

export type { LoginFieldView, LoginProbeView, LoginResult, SourceLoginView };

/** 登录方式：没有声明 / 表单+脚本 / 网页登录。 */
export const LOGIN_KIND = {
  none: "none",
  js: "js",
  page: "page",
} as const;

/**
 * 书源类型（bookSourceType）。
 *
 * 与 Kotlin 原版 constant/BookSourceType.kt 一致：0 文本 / 1 音频 / 2 图片 / 3 文件。
 * 漫画源就是 2——它和文本源共用同一套登录流程，这里只用于界面提示。
 */
export const SOURCE_TYPE = {
  text: 0,
  audio: 1,
  image: 2,
  file: 3,
} as const;

/**
 * 登录表单的值。
 *
 * 后端签名是 `{ [_ in string]?: string }`（Go 的 map 允许缺省值），
 * 前端构造时用完整 Record，避免每处都写可选链。
 */
export type LoginForm = Record<string, string>;

export const sourceLoginApi = {
  /** 读取登录面板所需的全部信息。 */
  profile: (sourceId: number) => call(binding.Profile(sourceId)),

  /** 执行登录（表单登录）。 */
  login: (sourceId: number, form: LoginForm) => call(binding.Login(sourceId, form)),

  /** 执行 loginUi 里自定义按钮的动作。 */
  runAction: (sourceId: number, action: string, form: LoginForm) =>
    call(binding.RunAction(sourceId, action, form)),

  /** 保存手动粘贴的登录头（JSON / 请求头行 / 裸 Cookie 都认）。 */
  saveHeader: (sourceId: number, header: string) =>
    call(binding.SaveHeader(sourceId, header)),

  /** 读取已保存的登录头原文。 */
  header: (sourceId: number) => call(binding.Header(sourceId)),

  /** 清除登录；withForm 为 true 时连账号密码一起删。 */
  clear: (sourceId: number, withForm: boolean) =>
    call(binding.Clear(sourceId, withForm)),

  /** 探测登录态；probeUrl 为空时由后端挑地址。 */
  check: (sourceId: number, probeUrl = "") =>
    call(binding.Check(sourceId, probeUrl)),
};
