<script setup lang="ts">
/**
 * 问答面板：会话列表 + 消息流 + 输入框。
 *
 * 详情页（AI 页）和阅读器抽屉共用这一个组件，区别只在 compact：
 * 抽屉里没有空间放会话列表，只显示当前会话。
 *
 * 流式渲染不在这里做：状态归 stores/aiChat 管理（回答跨页面存活），
 * 本组件只负责把 messages 画出来。
 */
import { computed, nextTick, onMounted, ref, watch } from "vue";
import { ElMessage, ElMessageBox } from "element-plus";

import type { AIRefPayload } from "@/api/events";
import { useAIChatStore } from "@/stores/aiChat";
import type { ChatMessageView } from "@/stores/aiChat";

const props = defineProps<{
  bookId: number;
  /** 抽屉模式：隐藏会话列表，只显示对话。 */
  compact?: boolean;
}>();

const emit = defineEmits<{ (e: "cite", ref: AIRefPayload): void }>();

const store = useAIChatStore();

const chatId = ref(0);
const input = ref("");
const loading = ref(false);
const listEl = ref<HTMLElement | null>(null);

const chats = computed(() => store.chats[props.bookId] ?? []);
const messages = computed<ChatMessageView[]>(() =>
  chatId.value ? store.messagesOf(chatId.value) : [],
);
const streaming = computed(() => store.isStreaming(chatId.value));
const status = computed(() => store.statusOf(chatId.value));
const canSend = computed(
  () => input.value.trim().length > 0 && !streaming.value,
);

/** 打开会话：拉消息并滚到底部。 */
async function openChat(id: number) {
  chatId.value = id;
  loading.value = true;
  try {
    await store.loadMessages(id);
    await scrollToEnd();
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    loading.value = false;
  }
}

async function newChat() {
  try {
    const chat = await store.createChat(props.bookId, "新的对话");
    await openChat(chat.id);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function removeChat(id: number) {
  try {
    await ElMessageBox.confirm("删除后这轮对话不会被保留。", "删除这轮对话？", {
      type: "warning",
      confirmButtonText: "删除",
      cancelButtonText: "算了",
    });
  } catch {
    return;
  }
  try {
    await store.removeChat(props.bookId, id);
    if (chatId.value === id) {
      const next = chats.value[0];
      if (next) await openChat(next.id);
      else {
        chatId.value = 0;
        await newChat();
      }
    }
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/** 没有会话时用一个临时会话承接第一条提问。 */
async function ensureChat(): Promise<number> {
  if (chatId.value) return chatId.value;
  const chat = await store.createChat(props.bookId, input.value.trim().slice(0, 20) || "新的对话");
  chatId.value = chat.id;
  return chat.id;
}

async function send() {
  const text = input.value.trim();
  if (!text || streaming.value) return;
  try {
    const id = await ensureChat();
    input.value = "";
    await store.ask(id, text);
    await scrollToEnd();
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function stop() {
  try {
    await store.stop(chatId.value);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function scrollToEnd() {
  await nextTick();
  if (!listEl.value) return;
  // 即时滚动：流式输出时用平滑滚动会一直追不上，观感反而卡。
  listEl.value.scrollTop = listEl.value.scrollHeight;
}

/** 输入框回车发送（Shift+Enter 换行）。 */
function onKeydown(e: KeyboardEvent) {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
    e.preventDefault();
    send();
  }
}

watch(messages, scrollToEnd, { deep: true });

async function bootstrap() {
  if (!props.bookId) return;
  try {
    const list = await store.loadChats(props.bookId);
    if (list.length) await openChat(list[0].id);
  } catch {
    // 会话列表拉不到不影响提问：第一条提问会自动建会话。
  }
}

watch(() => props.bookId, bootstrap);
onMounted(bootstrap);

defineExpose({ focus: () => chatId.value });
</script>

<template>
  <div class="chat" :class="{ compact: props.compact }">
    <aside v-if="!props.compact" class="side">
      <div class="side-head">
        <span class="side-title">对话</span>
        <button class="ghost" data-ai="chat-new" @click="newChat">新建</button>
      </div>
      <p v-if="!chats.length" class="side-empty">还没有对话</p>
      <ul v-else class="side-list">
        <li
          v-for="c in chats"
          :key="c.id"
          class="side-item"
          :class="{ active: c.id === chatId }"
          @click="openChat(c.id)"
        >
          <span class="side-name">{{ c.title }}</span>
          <button
            class="ghost tiny"
            title="删除"
            @click.stop="removeChat(c.id)"
          >×</button>
        </li>
      </ul>
    </aside>

    <section class="main">
      <div ref="listEl" class="messages" v-loading="loading">
        <p v-if="!messages.length" class="hint">
          就这本书提问，例如「第三章讲了什么」「这个结论的依据在哪」。
          回答会标注出处，点引用可直接跳到原文。
        </p>

        <div
          v-for="m in messages"
          :key="m.id"
          class="msg"
          :class="m.role"
          data-ai="chat-message"
          :data-role="m.role"
        >
          <div class="bubble">
            <span class="text">{{ m.content }}</span>
            <span v-if="m.pending" class="caret" />
          </div>

          <div v-if="m.refs?.length" class="refs">
            <button
              v-for="(r, i) in m.refs"
              :key="r.chunkId"
              class="ref"
              data-ai="chat-ref"
              :title="r.excerpt"
              @click="emit('cite', r)"
            >
              [{{ i + 1 }}] {{ r.title }}
            </button>
          </div>
        </div>
      </div>

      <p v-if="status?.error" class="status error" data-ai="chat-error">
        {{ status.error }}
      </p>
      <p v-else-if="status?.note" class="status note" data-ai="chat-note">
        {{ status.note }}
      </p>

      <div class="composer">
        <el-input
          v-model="input"
          type="textarea"
          :rows="2"
          resize="none"
          placeholder="问点什么…（Enter 发送，Shift+Enter 换行）"
          data-ai="chat-input"
          @keydown="onKeydown"
        />
        <div class="composer-actions">
          <el-button
            v-if="streaming"
            type="danger"
            plain
            size="small"
            data-ai="chat-stop"
            @click="stop"
          >停止</el-button>
          <el-button
            v-else
            type="primary"
            size="small"
            data-ai="chat-send"
            :disabled="!canSend"
            @click="send"
          >发送</el-button>
        </div>
      </div>
    </section>
  </div>
</template>

<style scoped>
.chat {
  display: flex;
  height: 100%;
  min-height: 0;
  gap: 12px;
}
.side {
  width: 180px;
  flex: none;
  display: flex;
  flex-direction: column;
  border-right: 1px solid #eef0f3;
  padding-right: 8px;
}
.side-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 6px;
}
.side-title {
  font-size: 13px;
  font-weight: 600;
  color: rgba(0, 0, 0, 0.75);
}
.side-empty {
  font-size: 12px;
  color: rgba(0, 0, 0, 0.4);
}
.side-list {
  list-style: none;
  margin: 0;
  padding: 0;
  overflow-y: auto;
}
.side-item {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 6px 8px;
  border-radius: 6px;
  font-size: 13px;
  color: rgba(0, 0, 0, 0.7);
  cursor: pointer;
}
.side-item:hover {
  background: #f5f7fa;
}
.side-item.active {
  background: #ecf5ff;
  color: #409eff;
}
.side-name {
  flex: 1;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.ghost {
  border: none;
  background: transparent;
  color: #409eff;
  font-size: 12px;
  cursor: pointer;
  padding: 0 2px;
}
.ghost.tiny {
  color: rgba(0, 0, 0, 0.35);
  font-size: 14px;
}
.main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}
.messages {
  flex: 1;
  min-height: 120px;
  overflow-y: auto;
  padding: 4px 2px;
}
.hint {
  font-size: 12px;
  line-height: 1.7;
  color: rgba(0, 0, 0, 0.45);
  margin: 8px 0;
}
.msg {
  display: flex;
  flex-direction: column;
  margin-bottom: 12px;
}
.msg.user {
  align-items: flex-end;
}
.msg.assistant {
  align-items: flex-start;
}
.bubble {
  max-width: 86%;
  padding: 8px 12px;
  border-radius: 10px;
  font-size: 13px;
  line-height: 1.75;
  white-space: pre-wrap;
  word-break: break-word;
}
.msg.user .bubble {
  background: #409eff;
  color: #fff;
}
.msg.assistant .bubble {
  background: #f5f7fa;
  color: rgba(0, 0, 0, 0.8);
}
.caret {
  display: inline-block;
  width: 6px;
  height: 13px;
  margin-left: 2px;
  vertical-align: text-bottom;
  background: #409eff;
  animation: blink 1s steps(2, start) infinite;
}
@keyframes blink {
  to {
    visibility: hidden;
  }
}
.refs {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 6px;
  max-width: 86%;
}
.ref {
  border: 1px solid #dcdfe6;
  background: #fff;
  border-radius: 12px;
  padding: 2px 10px;
  font-size: 12px;
  color: #409eff;
  cursor: pointer;
}
.ref:hover {
  background: #ecf5ff;
}
.status {
  margin: 0 0 6px;
  font-size: 12px;
  line-height: 1.6;
}
.status.error {
  color: #f56c6c;
}
.status.note {
  color: rgba(0, 0, 0, 0.45);
}
.composer {
  flex: none;
  border-top: 1px solid #eef0f3;
  padding-top: 8px;
}
.composer-actions {
  display: flex;
  justify-content: flex-end;
  margin-top: 6px;
}
.compact .messages {
  max-height: 46vh;
}
</style>
