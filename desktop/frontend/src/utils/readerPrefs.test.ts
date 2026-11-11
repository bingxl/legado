/**
 * 阅读偏好的读写契约。
 *
 * 这里守两条容易回归的线：
 *  1. 「返回时提示加入书架」默认关闭，且老版本存的偏好（没有该字段）必须落到关闭；
 *  2. `saveReaderPrefs` 是增量写入——改字号不能顺手把开关重置。
 *     阅读器的字号滑块与设置页各调一次，漏传字段就会静默丢设置。
 */
import { beforeEach, describe, expect, it } from "vitest";

import { loadReaderPrefs, readerPrefsDefaults, saveReaderPrefs } from "./readerPrefs";

const KEY = "legado.reader.prefs";

describe("readerPrefs", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it("没有存储时用默认值，开关为关闭", () => {
    const prefs = loadReaderPrefs();
    expect(prefs).toEqual(readerPrefsDefaults);
    expect(prefs.promptAddToShelf).toBe(false);
  });

  it("老版本的偏好（无开关字段）读出来仍是关闭", () => {
    localStorage.setItem(KEY, JSON.stringify({ fontSize: 20, lineHeight: 2.2 }));
    const prefs = loadReaderPrefs();
    expect(prefs.fontSize).toBe(20);
    expect(prefs.lineHeight).toBe(2.2);
    expect(prefs.promptAddToShelf).toBe(false);
  });

  it("开关打开后能读回", () => {
    saveReaderPrefs({ promptAddToShelf: true });
    expect(loadReaderPrefs().promptAddToShelf).toBe(true);
  });

  it("只改字号不会把开关冲回默认", () => {
    saveReaderPrefs({ promptAddToShelf: true });
    saveReaderPrefs({ fontSize: 22 });
    const prefs = loadReaderPrefs();
    expect(prefs.fontSize).toBe(22);
    expect(prefs.promptAddToShelf).toBe(true);
  });

  it("只改开关不会动字号与行距", () => {
    saveReaderPrefs({ fontSize: 19, lineHeight: 2.4 });
    saveReaderPrefs({ promptAddToShelf: true });
    const prefs = loadReaderPrefs();
    expect(prefs.fontSize).toBe(19);
    expect(prefs.lineHeight).toBe(2.4);
  });

  it("脏数据退回默认值", () => {
    localStorage.setItem(KEY, "{not json");
    expect(loadReaderPrefs()).toEqual(readerPrefsDefaults);
  });

  it("越界/非数字的数值按区间夹取", () => {
    localStorage.setItem(
      KEY,
      JSON.stringify({ fontSize: 999, lineHeight: "x", promptAddToShelf: "yes" }),
    );
    const prefs = loadReaderPrefs();
    expect(prefs.fontSize).toBe(28);
    expect(prefs.lineHeight).toBe(readerPrefsDefaults.lineHeight);
    // 只有严格的 true 才算打开，字符串不算
    expect(prefs.promptAddToShelf).toBe(false);
  });
});
