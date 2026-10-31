<script setup lang="ts">
import { computed, reactive, ref, watch } from "vue";
import { ElMessage, ElMessageBox } from "element-plus";
import { Browser } from "@wailsio/runtime";

import {
  LOGIN_KIND,
  SOURCE_TYPE,
  sourceLoginApi,
  type LoginFieldView,
  type LoginForm,
  type LoginProbeView,
  type SourceLoginView,
} from "@/api/sourceLogin";

const props = defineProps<{
  modelValue: boolean;
  sourceId: number;
  sourceName?: string;
}>();

const emit = defineEmits<{
  (e: "update:modelValue", v: boolean): void;
  (e: "changed"): void;
}>();

const open = computed({
  get: () => props.modelValue,
  set: (v: boolean) => emit("update:modelValue", v),
});

const loading = ref(false);
const busy = ref(false);
const checking = ref(false);
const profile = ref<SourceLoginView | null>(null);
const form = reactive<LoginForm>({});
/** 手动粘贴区的内容（不清空，方便用户改）。 */
const headerText = ref("");
const resultMsg = ref("");
const logs = ref<string[]>([]);
const probe = ref<LoginProbeView | null>(null);
const clearForm = ref(false);
const savedHeader = ref("");

/** 表单里真正要填的字段（按钮单独渲染）。 */
const formFields = computed<LoginFieldView[]>(
  () => profile.value?.fields.filter((f) => f.type !== "button") ?? [],
);
const actionButtons = computed<LoginFieldView[]>(
  () => profile.value?.fields.filter((f) => f.type === "button") ?? [],
);
const isComic = computed(() => profile.value?.sourceType === SOURCE_TYPE.image);
const loggedIn = computed(() => !!profile.value?.hasCookie);

async function load() {
  if (!props.sourceId) return;
  loading.value = true;
  try {
    const p = await sourceLoginApi.profile(props.sourceId);
    profile.value = p;
    // 回填上次填过的账号：换号登录时不用重新敲。
    for (const k of Object.keys(form)) delete form[k];
    for (const [k, v] of Object.entries(p.info ?? {})) form[k] = v ?? "";
    resultMsg.value = "";
    logs.value = [];
    probe.value = null;
    savedHeader.value = "";
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    loading.value = false;
  }
}

watch(
  () => props.modelValue,
  (v) => {
    if (v) void load();
  },
);

/** 统一处理一次登录类动作的结果：提示、日志、需要打开的地址。 */
async function applyResult(res: {
  ok?: boolean;
  message?: string;
  logs?: string[] | null;
  output?: string;
  openUrl?: string;
}) {
  logs.value = res.logs ?? [];
  if (res.openUrl) {
    await Browser.OpenURL(res.openUrl);
    resultMsg.value = res.message || "已在浏览器中打开登录页";
    return;
  }
  resultMsg.value = res.message || (res.ok ? "完成" : "未完成");
  if (res.ok) {
    ElMessage.success("登录信息已保存");
    await load();
    emit("changed");
  } else if (res.output) {
    resultMsg.value += `（${res.output}）`;
  }
}

async function submit() {
  if (!props.sourceId) return;
  busy.value = true;
  try {
    const res = await sourceLoginApi.login(props.sourceId, { ...form });
    await applyResult(res);
  } catch (e) {
    resultMsg.value = (e as Error).message;
    ElMessage.error((e as Error).message);
  } finally {
    busy.value = false;
  }
}

async function runButton(b: LoginFieldView) {
  if (!props.sourceId) return;
  busy.value = true;
  try {
    const res = await sourceLoginApi.runAction(props.sourceId, b.action, { ...form });
    await applyResult(res);
  } catch (e) {
    resultMsg.value = (e as Error).message;
    ElMessage.error((e as Error).message);
  } finally {
    busy.value = false;
  }
}

async function openPage() {
  const url = profile.value?.loginUrl;
  if (!url) return;
  await Browser.OpenURL(url);
}

async function saveHeader() {
  if (!props.sourceId) return;
  const text = headerText.value.trim();
  if (!text) {
    ElMessage.warning("请先粘贴 Cookie 或登录头");
    return;
  }
  busy.value = true;
  try {
    const res = await sourceLoginApi.saveHeader(props.sourceId, text);
    headerText.value = "";
    await applyResult(res);
  } catch (e) {
    resultMsg.value = (e as Error).message;
    ElMessage.error((e as Error).message);
  } finally {
    busy.value = false;
  }
}

async function runCheck() {
  if (!props.sourceId) return;
  checking.value = true;
  try {
    probe.value = await sourceLoginApi.check(props.sourceId, "");
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    checking.value = false;
  }
}

async function showHeader() {
  if (!props.sourceId) return;
  try {
    savedHeader.value = await sourceLoginApi.header(props.sourceId);
    if (!savedHeader.value) ElMessage.info("还没有保存登录头");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function clear() {
  if (!props.sourceId) return;
  const extra = clearForm.value ? "，并删除已保存的账号密码" : "";
  try {
    await ElMessageBox.confirm(`确定清除该书的登录信息${extra}？`, "清除登录", {
      confirmButtonText: "清除",
      cancelButtonText: "取消",
      type: "warning",
    });
  } catch {
    return;
  }
  try {
    await sourceLoginApi.clear(props.sourceId, clearForm.value);
    ElMessage.success("已清除");
    await load();
    emit("changed");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/** 复制保存的登录头：排查问题时经常要给别处贴一份。 */
async function copyHeader() {
  try {
    await navigator.clipboard.writeText(savedHeader.value);
    ElMessage.success("已复制");
  } catch {
    ElMessage.warning("复制失败，请手动选中复制");
  }
}
</script>

<template>
  <el-dialog
    v-model="open"
    width="600"
    :title="`登录 · ${profile?.sourceName || sourceName || ''}`"
    class="source-login"
  >
    <div v-loading="loading" class="body" data-login="panel">
      <div class="head">
        <el-tag v-if="isComic" size="small" type="warning" data-login="comic">
          漫画源
        </el-tag>
        <el-tag
          size="small"
          :type="loggedIn ? 'success' : 'info'"
          data-login="state"
        >
          {{ loggedIn ? "已登录" : "未登录" }}
        </el-tag>
        <span v-if="profile?.cookieMask" class="mask" data-login="cookie-mask">
          {{ profile.cookieMask }}
        </span>
      </div>

      <!-- 表单登录：loginUrl 是脚本，loginUi 描述要填什么 -->
      <template v-if="profile?.kind === LOGIN_KIND.js">
        <el-form label-width="96px" class="form" @submit.prevent>
          <el-form-item
            v-for="(f, i) in formFields"
            :key="f.name"
            :label="f.name"
          >
            <el-input
              v-model="form[f.name]"
              :type="f.type === 'password' ? 'password' : 'text'"
              :show-password="f.type === 'password'"
              :placeholder="f.name"
              :data-login="`field-${i}`"
            />
          </el-form-item>
        </el-form>
        <div class="actions">
          <el-button
            type="primary"
            :loading="busy"
            data-login="submit"
            @click="submit"
          >
            登录
          </el-button>
          <el-button
            v-for="b in actionButtons"
            :key="b.name"
            data-login="action"
            @click="runButton(b)"
          >
            {{ b.name }}
          </el-button>
        </div>
      </template>

      <!-- 网页登录：桌面端拿不到 WebView 的 HttpOnly Cookie，走浏览器 + 粘贴 -->
      <template v-else-if="profile?.kind === LOGIN_KIND.page">
        <p class="tip">
          该书源使用网页登录。请在浏览器里完成登录，然后把 Cookie 粘贴到下方输入框。
        </p>
        <el-button data-login="open-page" @click="openPage">
          在浏览器打开登录页
        </el-button>
        <p class="url">{{ profile.loginUrl }}</p>
      </template>

      <el-alert
        v-else
        type="info"
        :closable="false"
        show-icon
        title="该书源没有声明登录地址"
        description="支持直接粘贴浏览器里的 Cookie；不需要登录的书源可以忽略这里。"
        data-login="no-login"
      />

      <!-- 手动 Cookie：三条路都归一到这里 -->
      <el-collapse class="cookie">
        <el-collapse-item name="cookie">
          <template #title>
            <span data-login="cookie-title">手动粘贴 Cookie / 登录头</span>
          </template>
          <el-input
            v-model="headerText"
            type="textarea"
            :rows="4"
            placeholder="sid=xxx; token=yyy&#10;也可以粘贴整段请求头或 {&quot;Cookie&quot;:&quot;...&quot;}"
            data-login="cookie-input"
          />
          <div class="cookie-actions">
            <el-button
              type="primary"
              plain
              :loading="busy"
              data-login="save-cookie"
              @click="saveHeader"
            >
              保存
            </el-button>
            <el-button data-login="show-header" @click="showHeader">
              查看已保存
            </el-button>
          </div>
          <template v-if="savedHeader">
            <el-input
              :model-value="savedHeader"
              type="textarea"
              :rows="3"
              readonly
              data-login="header-view"
            />
            <el-button link type="primary" data-login="copy-header" @click="copyHeader">
              复制
            </el-button>
          </template>
        </el-collapse-item>
      </el-collapse>

      <div v-if="resultMsg" class="result" data-login="result">{{ resultMsg }}</div>
      <pre v-if="logs.length" class="logs" data-login="logs">{{ logs.join("\n") }}</pre>
      <div v-if="probe" class="probe" :class="{ bad: probe.needLogin }" data-login="probe">
        {{ probe.detail }}
        <span v-if="probe.url" class="probe-url">（{{ probe.url }}）</span>
      </div>
    </div>

    <template #footer>
      <el-checkbox v-model="clearForm" class="clear-form" data-login="clear-form">
        连账号密码一起删除
      </el-checkbox>
      <el-button data-login="check" :loading="checking" @click="runCheck">
        检测登录
      </el-button>
      <el-button
        v-if="loggedIn || profile?.header"
        type="danger"
        plain
        data-login="clear"
        @click="clear"
      >
        清除登录
      </el-button>
      <el-button @click="open = false">关闭</el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.body {
  min-height: 180px;
}
.head {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 12px;
}
.mask {
  font-size: 12px;
  color: var(--el-text-color-secondary);
  word-break: break-all;
}
.form {
  margin-bottom: 4px;
}
.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-bottom: 8px;
}
.tip {
  margin: 0 0 8px;
  font-size: 13px;
  color: var(--el-text-color-regular);
  line-height: 1.6;
}
.url {
  margin: 8px 0 0;
  font-size: 12px;
  color: var(--el-text-color-secondary);
  word-break: break-all;
}
.cookie {
  margin-top: 12px;
}
.cookie-actions {
  display: flex;
  gap: 8px;
  margin: 8px 0;
}
.result {
  margin-top: 12px;
  font-size: 13px;
  color: var(--el-color-success);
}
.logs {
  margin: 8px 0 0;
  padding: 8px;
  max-height: 140px;
  overflow: auto;
  font-size: 12px;
  line-height: 1.5;
  background: var(--el-fill-color-light);
  border-radius: 4px;
  white-space: pre-wrap;
  word-break: break-all;
}
.probe {
  margin-top: 8px;
  font-size: 13px;
  color: var(--el-color-success);
}
.probe.bad {
  color: var(--el-color-danger);
}
.probe-url {
  color: var(--el-text-color-secondary);
  font-size: 12px;
}
.clear-form {
  margin-right: 8px;
  float: left;
}
</style>
