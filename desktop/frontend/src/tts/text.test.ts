import { describe, expect, it } from "vitest";

import {
  MAX_SEGMENT_CHARS,
  isNoiseLine,
  normalizeSpeechText,
  purifyForSpeech,
  splitLongText,
} from "./text";

describe("normalizeSpeechText", () => {
  it("去掉不可见字符与软连字符", () => {
    expect(normalizeSpeechText("人\u200b生\u00ad若只如初见")).toBe(
      "人生若只如初见",
    );
  });

  it("把不间断空格/全角空格当普通空格并压缩", () => {
    expect(normalizeSpeechText("a\u00a0b\u3000c   d")).toBe("a b c d");
  });

  it("修掉两个汉字之间的排版空格", () => {
    expect(normalizeSpeechText("人 生 若 只 如 初 见")).toBe("人生若只如初见");
    // 英文单词之间的空格要保留
    expect(normalizeSpeechText("hello world 世界")).toBe("hello world 世界");
  });

  it("省略号与破折号归一成逗号", () => {
    expect(normalizeSpeechText("他犹豫了……然后走了")).toBe("他犹豫了，然后走了");
    expect(normalizeSpeechText("他说——算了吧")).toBe("他说，算了吧");
  });

  it("去重连续标点、清理标点前的空格", () => {
    expect(normalizeSpeechText("真的吗？？太夸张了 。")).toBe("真的吗？太夸张了。");
  });
});

describe("isNoiseLine", () => {
  it.each([
    "请收藏本站最新网址",
    "本章未完，请点击下一页继续阅读",
    "手机用户请浏览 m.example.com 阅读",
    "***",
    "12/240",
    "第 3 页",
    "https://example.com/a?b=1",
  ])("把 %s 判为噪音", (line) => {
    expect(isNoiseLine(line)).toBe(true);
  });

  it.each(["他推开门，走了进去。", "第 3 章 夜行", "1984", "hello world"])(
    "不把 %s 判为噪音",
    (line) => {
      expect(isNoiseLine(line)).toBe(false);
    },
  );

  it("纯符号行返回空串", () => {
    expect(purifyForSpeech("……")).toBe("");
  });
});

describe("splitLongText", () => {
  it("短文本原样返回", () => {
    expect(splitLongText("一句话。")).toEqual(["一句话。"]);
    expect(splitLongText("")).toEqual([]);
  });

  it("按句末标点切，且每段不超过上限", () => {
    const sentences = Array.from({ length: 12 }, (_, i) => `第${i}句话在这里。`);
    const text = sentences.join("");
    const parts = splitLongText(text, 40);
    expect(parts.length).toBeGreaterThan(1);
    expect(parts.every((p) => p.length <= 40)).toBe(true);
    expect(parts.join("")).toBe(text);
  });

  it("单句超长时退到逗号级再切", () => {
    const clause = "在一个很长很长的从句里，";
    const text = clause.repeat(20) + "结束了。";
    const parts = splitLongText(text, MAX_SEGMENT_CHARS);
    expect(parts.length).toBeGreaterThan(1);
    expect(parts.every((p) => p.length <= MAX_SEGMENT_CHARS)).toBe(true);
    expect(parts.join("")).toBe(text);
  });

  it("没有任何标点的超长文本也能硬切，且不丢字符", () => {
    const text = "啊".repeat(500);
    const parts = splitLongText(text, 100);
    expect(parts.join("")).toBe(text);
    expect(parts.every((p) => p.length <= 100)).toBe(true);
  });
});
