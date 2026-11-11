// 书源校验的运行时状态。
//
// 为什么单列一个 store 而不是塞进 SourceView 的局部状态：
//  1. 校验是长任务（几十秒到几分钟），用户可能中途切到别的页面再回来；
//     状态放在 store 里，页面重建后行内消息还在。
//  2. 事件是全局广播的，订阅点放页面里会在卸载时漏掉「最后一条」导致
//     进度条卡在进行中；store 里只订阅一次，生命周期与 App 一致。
//
// 与原生一致：消息按 sourceId 落在行上，整体进度给顶部的进度条用。
import { defineStore } from "pinia";
import { computed, ref } from "vue";

import { onSourceCheckProgress } from "@/api/events";

/** 单个书源的校验消息。 */
export interface CheckMessage {
  ok: boolean;
  text: string;
}

export const useSourceCheckStore = defineStore("sourceCheck", () => {
  const running = ref(false);
  const total = ref(0);
  const done = ref(0);
  const current = ref("");
  /** sourceId → 结论。 */
  const messages = ref<Record<number, CheckMessage>>({});

  /** 校验关键词：原生会记住上次输入的值，这里用 localStorage 达到同样效果。 */
  const keyword = ref(localStorage.getItem(CHECK_KEYWORD_KEY) || "我的");
  function setKeyword(v: string) {
    keyword.value = v;
    localStorage.setItem(CHECK_KEYWORD_KEY, v);
  }

  const progressText = computed(() =>
    total.value > 0 ? `${done.value}/${total.value}` : "",
  );

  let subscribed = false;
  /** 订阅后端事件；重复调用无副作用。 */
  function attach() {
    if (subscribed) return;
    subscribed = true;
    onSourceCheckProgress((p) => {
      if (p.total > 0) total.value = p.total;
      if (p.done > 0) done.value = p.done;
      if (p.current) current.value = p.current;
      if (p.sourceId) {
        messages.value[p.sourceId] = {
          ok: Boolean(p.ok),
          text: p.message || (p.ok ? "成功" : "失败"),
        };
      }
      // 进度追平即视为本轮结束：后端不再单发「完成」事件，
      // 而 ValidateWith 的 Promise 也可能因为页面切换而丢了引用。
      if (total.value > 0 && done.value >= total.value) running.value = false;
    });
  }

  /** 开始一轮校验：清掉上一轮的行内消息。 */
  function begin(targetCount: number) {
    attach();
    running.value = true;
    total.value = targetCount;
    done.value = 0;
    current.value = "";
    messages.value = {};
  }

  /** 主动结束（调用失败或用户取消）。 */
  function finish() {
    running.value = false;
  }

  function clear() {
    messages.value = {};
    total.value = 0;
    done.value = 0;
    current.value = "";
    running.value = false;
  }

  function messageOf(sourceId: number): CheckMessage | undefined {
    return messages.value[sourceId];
  }

  return {
    running,
    total,
    done,
    current,
    messages,
    keyword,
    progressText,
    attach,
    begin,
    finish,
    clear,
    messageOf,
    setKeyword,
  };
});

const CHECK_KEYWORD_KEY = "legado.sourceCheck.keyword";
