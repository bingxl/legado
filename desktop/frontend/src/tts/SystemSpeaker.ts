/**
 * 系统朗读（`speechSynthesis`）实现。
 *
 * 这个 API 的坑比接口本身多，全部在这里兜住，上层只看到
 * 「说一段、说完了回调、失败回调」三个信号：
 *
 * - **`pause()` 不可用**：Chromium 长文本 pause 后常常再也恢复不了。
 *   暂停 = `cancel()` + 记住当前段；继续 = 从该段重读（store 负责记位置）。
 * - **`cancel()` 与 `speak()` 同 tick 会丢句子**：间隔 60ms 再发。
 * - **`onend` 偶发不触发**：看门狗兜底，否则播放条会永远停在"正在播放"。
 * - **启动失败是静默的**：`speak()` 不抛错也不触发事件，1.5 秒没 `onstart` 判失败。
 */

import { findSystemVoice, speechSupported } from "./voice";

export interface SpeakRequest {
  text: string;
  /** 系统音色 id（voiceURI 或 name）。 */
  voiceId?: string;
  /** 1 = 常速。 */
  rate?: number;
  onStart?: () => void;
  onEnd?: () => void;
  onError?: (message: string) => void;
}

/** 失败原因 → 可读提示。 */
function errorText(code: string): string {
  switch (code) {
    case "not-allowed":
      return "朗读被拒绝：当前环境不允许自动发声";
    case "synthesis-failed":
      return "语音合成失败，所选音色可能不可用";
    case "synthesis-unavailable":
      return "本机没有可用的语音合成引擎";
    case "voice-unavailable":
      return "所选音色不可用，请换一个音色";
    case "audio-busy":
      return "音频设备忙，请稍后重试";
    case "network":
      return "语音服务网络异常";
    default:
      return `朗读失败：${code || "未知错误"}`;
  }
}

/** 粗略估计朗读时长（毫秒）。中速约 4–5 字/秒，留足余量。 */
function estimateMs(text: string, rate: number): number {
  return Math.round((text.length * 240) / Math.max(0.5, rate)) + 5000;
}

function clamp(n: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, n));
}

export class SystemSpeaker {
  private token = 0;
  private utter: SpeechSynthesisUtterance | null = null;
  private watchdog = 0;
  private deadline = 0;
  private started = false;
  private cancelledAt = 0;

  get available(): boolean {
    return speechSupported();
  }

  get speaking(): boolean {
    return speechSupported() && window.speechSynthesis.speaking;
  }

  speak(req: SpeakRequest): void {
    if (!speechSupported()) {
      req.onError?.("当前环境不支持系统朗读");
      return;
    }
    const synth = window.speechSynthesis;
    const token = ++this.token;
    let ended = false;

    this.clearWatchdog();
    this.started = false;
    this.utter = null;

    const finish = (): boolean => {
      if (ended) return false;
      ended = true;
      this.clearWatchdog();
      this.utter = null;
      return true;
    };

    const run = () => {
      if (token !== this.token) return;
      const u = new SpeechSynthesisUtterance(req.text);
      const voice = findSystemVoice(req.voiceId);
      if (voice) {
        u.voice = voice;
        if (voice.lang) u.lang = voice.lang;
      } else {
        u.lang = "zh-CN";
      }
      u.rate = clamp(req.rate ?? 1, 0.5, 3);

      u.onstart = () => {
        if (token !== this.token) return;
        this.started = true;
        req.onStart?.();
      };
      u.onend = () => {
        if (token !== this.token) return;
        if (!finish()) return;
        req.onEnd?.();
      };
      u.onerror = (e) => {
        if (token !== this.token) return;
        const code = (e as SpeechSynthesisErrorEvent).error ?? "";
        // 自己 cancel 引起的，不是错误
        if (code === "interrupted" || code === "canceled") return;
        if (!finish()) return;
        req.onError?.(errorText(code));
      };

      this.utter = u;
      this.deadline = Date.now() + estimateMs(req.text, u.rate);
      this.armWatchdog(token, req, finish);
      try {
        synth.speak(u);
      } catch (err) {
        if (finish()) req.onError?.(String(err));
      }
    };

    const since = Date.now() - this.cancelledAt;
    if (synth.speaking || synth.pending) synth.cancel();
    if (since < 60) window.setTimeout(run, 60 - since);
    else run();
  }

  /** 停止发声（暂停也走这里，见文件头的说明）。 */
  cancel(): void {
    this.token += 1;
    this.clearWatchdog();
    this.utter = null;
    this.started = false;
    this.cancelledAt = Date.now();
    if (!speechSupported()) return;
    try {
      window.speechSynthesis.cancel();
    } catch {
      // 忽略
    }
  }

  private clearWatchdog() {
    if (this.watchdog) {
      window.clearInterval(this.watchdog);
      this.watchdog = 0;
    }
  }

  /**
   * 看门狗：补两件 `speechSynthesis` 不做的事——启动失败检测、结束事件兜底。
   */
  private armWatchdog(
    token: number,
    req: SpeakRequest,
    finish: () => boolean,
  ) {
    const startedAt = Date.now();
    this.watchdog = window.setInterval(() => {
      if (token !== this.token) {
        this.clearWatchdog();
        return;
      }
      const synth = window.speechSynthesis;
      const elapsed = Date.now() - startedAt;

      if (!this.started) {
        if (!synth.speaking && !synth.pending && elapsed > 1500) {
          if (finish()) req.onError?.("系统朗读未能启动，请检查系统语音包");
        }
        return;
      }

      // 已经不说话超过 800ms 但 onend 没来：当作读完。
      if (!synth.speaking && !synth.pending && elapsed > 800) {
        if (finish()) req.onEnd?.();
        return;
      }
      // 远超预估时长还在"说"：判定卡死，别让播放条永远转圈。
      if (elapsed > this.deadline + 15000) {
        try {
          synth.cancel();
        } catch {
          // 忽略
        }
        if (finish()) req.onEnd?.();
      }
    }, 250);
  }
}
