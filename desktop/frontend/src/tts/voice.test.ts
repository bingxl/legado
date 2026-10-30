import { describe, expect, it } from "vitest";

import type { Voice } from "./types";
import { langLabel, listSystemVoices, pickDefaultVoice, speechSupported } from "./voice";

function v(id: string, lang: string, local = true): Voice {
  return { id, name: id, lang, engineId: "system", local };
}

describe("voice", () => {
  it("jsdom 没有 speechSynthesis 时不装作能用", () => {
    expect(speechSupported()).toBe(false);
    expect(listSystemVoices()).toEqual([]);
  });

  it("优先用指定音色", () => {
    const list = [v("a", "en-US"), v("b", "zh-CN")];
    expect(pickDefaultVoice(list, "a")?.id).toBe("a");
    // 传的是名字而不是 id 也能命中
    expect(pickDefaultVoice(list, "b")?.id).toBe("b");
  });

  it("未指定时优先中文，且本机合成优先于远程音色", () => {
    const list = [v("en", "en-US"), v("zh-remote", "zh-CN", false), v("zh-local", "zh-CN")];
    expect(pickDefaultVoice(list)?.id).toBe("zh-local");
  });

  it("没有中文时退回第一个可用音色", () => {
    expect(pickDefaultVoice([v("en", "en-US")])?.id).toBe("en");
  });

  it("空列表返回 null（调用方据此引导去用 HTTP 引擎）", () => {
    expect(pickDefaultVoice([])).toBeNull();
  });

  it("语言标签用于下拉分组", () => {
    expect(langLabel("zh-CN")).toBe("中文");
    expect(langLabel("en-GB")).toBe("英文");
    expect(langLabel("ja-JP")).toBe("日文");
    expect(langLabel(undefined)).toBe("其它");
  });
});
