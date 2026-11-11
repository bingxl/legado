<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { useRouter } from "vue-router";
import { ElMessage, ElMessageBox } from "element-plus";

import { aiApi } from "@/api/ai";
import { toMessage } from "@/api/client";
import type { AIConfigView, AITestResult } from "@/api/ai";
import {
  onPermissionChanged,
  openPermissionSettings,
  permissionAvailable,
  permissionStateLabel,
  permissionStatus,
  requestPermission,
} from "@/api/permissions";
import type { PermissionKind, PermissionState } from "@/api/permissions";
import { usePlatformStore } from "@/stores/platform";
import { useTtsStore } from "@/stores/tts";
import { useDictStore } from "@/stores/dict";
import type { DictPackageView } from "@/api/dict";
import { loadReaderPrefs, saveReaderPrefs } from "@/utils/readerPrefs";
import DictSourceDialog from "@/components/DictSourceDialog.vue";

const router = useRouter();
const platform = usePlatformStore();
const tts = useTtsStore();
const dict = useDictStore();

// ── 阅读排版 ────────────────────────────────────────────────
// 与阅读器共用同一份偏好：这里的改动立刻生效，
// 因为阅读器读取的是同一份 localStorage 值。
const fontSize = ref(17);
const lineHeight = ref(1.9);
/**
 * 退出阅读器时是否询问加入书架。
 *
 * 书籍与漫画共用同一个阅读器（ReaderView 按格式切渲染分支），所以一个开关
 * 同时管两者。默认关闭——弹窗拦人，只留给确实想要这个提醒的人。
 */
const shelfPrompt = ref(false);

// ── 朗读 ────────────────────────────────────────────────────
const rate = ref(100);
const voiceId = ref("");
const autoNext = ref(true);

/**
 * 子功能入口。
 *
 * 移动端底部 Tab 只有 5 个位置，替换规则/订阅/缓存/WebDAV 收在「我的」里；
 * 桌面端侧边栏已经直连，这里重复展示一次也无妨——它们是「设置」的自然归属，
 * 用户在设置页里找这些入口同样合理，两端因此保持一致。
 */
const entries = [
  { path: "/replace", label: "替换规则", desc: "阅读前净化正文" },
  { path: "/subscriptions", label: "书源订阅", desc: "定期拉取远程书源" },
  { path: "/cache", label: "离线缓存", desc: "下载章节与图片，离线可读" },
  { path: "/webdav", label: "WebDAV", desc: "备份同步与远程导入" },
];

const platformLabel = computed(() =>
  platform.isMobile ? "安卓端" : "桌面端",
);

// ── AI 配置 ─────────────────────────────────────────────────
// 与 WebDAV 同一套约定：密钥永不回传前端，保存时留空表示「保持原值」。
const aiForm = ref({
  baseURL: "",
  model: "",
  apiKey: "",
  clearKey: false,
  temperature: 0.7,
  contextWindow: 0,
  embeddingBaseURL: "",
  embeddingModel: "",
  embeddingDim: 0,
  maxConcurrent: 0,
});
const aiHasKey = ref(false);
const aiKeyHint = ref("");
const aiConfigured = ref(false);
const aiEmbeddingReady = ref(false);
const aiSaving = ref(false);
const aiTesting = ref(false);
const aiTestResult = ref<AITestResult | null>(null);

const aiStatus = computed(() => {
  if (!aiConfigured.value) return "未配置";
  return aiEmbeddingReady.value ? "已就绪（含向量检索）" : "已就绪（关键词检索）";
});

function applyAIConfig(v: AIConfigView) {
  aiForm.value.baseURL = v.baseURL;
  aiForm.value.model = v.model;
  aiForm.value.temperature = v.temperature > 0 ? v.temperature : 0.7;
  aiForm.value.contextWindow = v.contextWindow;
  aiForm.value.embeddingBaseURL = v.embeddingBaseURL;
  aiForm.value.embeddingModel = v.embeddingModel;
  aiForm.value.embeddingDim = v.embeddingDim;
  aiForm.value.maxConcurrent = v.maxConcurrent;
  // 密钥不回传，输入框保持空；hasKey/hint 只用于提示文案。
  aiForm.value.apiKey = "";
  aiForm.value.clearKey = false;
  aiHasKey.value = v.hasKey;
  aiKeyHint.value = v.keyHint;
  aiConfigured.value = v.configured;
  aiEmbeddingReady.value = v.embeddingReady;
}

async function loadAIConfig() {
  try {
    applyAIConfig(await aiApi.getConfig());
  } catch (err) {
    ElMessage.error(toMessage(err));
  }
}

async function saveAIConfig() {
  aiSaving.value = true;
  try {
    applyAIConfig(await aiApi.saveConfig(aiForm.value));
    ElMessage.success("AI 配置已保存");
  } catch (err) {
    ElMessage.error(toMessage(err));
  } finally {
    aiSaving.value = false;
  }
}

async function testAIConnection() {
  aiTesting.value = true;
  aiTestResult.value = null;
  try {
    const res = await aiApi.testConnection(aiForm.value);
    aiTestResult.value = res;
    // 维度由服务端返回，回填后保存，省得用户自己去查文档。
    if (res.embeddingOk && res.embeddingDim > 0) {
      aiForm.value.embeddingDim = res.embeddingDim;
    }
    ElMessage.success("对话服务可用");
  } catch (err) {
    ElMessage.error(toMessage(err));
  } finally {
    aiTesting.value = false;
  }
}

/** 标记清除密钥；真正生效要等保存。 */
function clearAIKey() {
  aiForm.value.clearKey = true;
  aiForm.value.apiKey = "";
  aiHasKey.value = false;
  aiKeyHint.value = "";
}

// ── 词典（英汉互译取词） ────────────────────────────────────
// 取词偏好与阅读器共用同一份 localStorage：这里改，阅读器立刻生效。
const dictEnabled = ref(dict.enabled);
const dictAutoLookup = ref(dict.autoLookup);
const dictDialog = ref(false);
/** 当前对话框针对的包。下载源的可选项要按包过滤（jsDelivr 20 MB 上限）。 */
const dictPack = ref({ id: "en-zh-full", name: "英文完整词库", bytes: 0 });

function onDictEnabled(v: boolean) {
  dictEnabled.value = v;
  dict.setEnabled(v);
}
function onDictAutoLookup(v: boolean) {
  dictAutoLookup.value = v;
  dict.setAutoLookup(v);
}

const dictPacks = computed(() => dict.status?.packages ?? []);
const builtinPack = computed(() => dictPacks.value.find((p) => p.builtin) ?? null);
const extPacks = computed(() => dictPacks.value.filter((p) => !p.builtin));

function openDictDialog(p: DictPackageView) {
  dictPack.value = { id: p.id, name: p.name, bytes: p.downloadBytes ?? 0 };
  dictDialog.value = true;
}

async function removeDictPack(p: DictPackageView) {
  try {
    await ElMessageBox.confirm(
      `删除「${p.name}」？删除后相关方向的查询会退回内置核心词库。`,
      "删除词库",
      { confirmButtonText: "删除", cancelButtonText: "取消", type: "warning" },
    );
  } catch {
    return;
  }
  try {
    await dict.remove(p.id);
    ElMessage.success("已删除");
  } catch (err) {
    ElMessage.error(toMessage(err));
  }
}

/** 体积格式化。 */
function fmtBytes(n: number): string {
  if (!n || n <= 0) return "—";
  return n < 1 << 20 ? `${Math.round(n / 1024)} KB` : `${(n / (1 << 20)).toFixed(1)} MB`;
}

/** 安装阶段的中文文案。 */
function phaseLabel(phase: string): string {
  switch (phase) {
    case "download":
      return "下载中";
    case "verify":
      return "校验中";
    case "convert":
      return "转换中";
    case "done":
      return "已完成";
    case "failed":
      return "失败";
    case "canceled":
      return "已取消";
    default:
      return "";
  }
}

/**
 * 一行进度摘要。
 *
 * 下载阶段带「已下 / 总量」：只给百分比的话，63 MB 的包卡在 12%
 * 时用户无法判断是慢还是死了。
 */
function installSummary(packId: string): string {
  const v = dict.installs[packId];
  if (!v) return "";
  const pct = v.percent === null ? "" : ` ${v.percent}%`;
  const head = `${phaseLabel(v.phase)}${pct}`;
  if (v.phase === "download" && v.totalBytes > 0) {
    return `${head} · ${fmtBytes(v.bytes)} / ${fmtBytes(v.totalBytes)}`;
  }
  return v.message ? `${head} · ${v.message}` : head;
}

/** 换源提示必须显示出来：速度突然变了不能没有解释。 */
function switchedNote(packId: string): string {
  const v = dict.installs[packId];
  return v?.switchedFrom ? `已从「${v.switchedFrom}」切换` : "";
}

// ── 权限（仅安卓端有） ──────────────────────────────────────
// 存储 / 相机的授权状态来自 Java 侧（见 api/permissions.ts）：桌面端这些
// 方法不存在，permAvailable 为 false，整张卡片不渲染。
const permAvailable = ref(false);
const permStorage = ref<PermissionState>("denied");
const permCamera = ref<PermissionState>("denied");
const permSdk = ref(0);
let permOff: (() => void) | null = null;

function refreshPermissions() {
  permAvailable.value = permissionAvailable();
  if (!permAvailable.value) return;
  const st = permissionStatus();
  if (!st) return;
  permStorage.value = st.storage;
  permCamera.value = st.camera;
  permSdk.value = st.sdk;
}

/**
 * 授权按钮。
 *
 * 「被永久拒绝」和「需去系统设置」这两种状态下再调 requestPermission 是白费
 * 力气——系统不会再弹框，必须跳设置页；其余状态才走正常申请。
 */
function fixPermission(kind: PermissionKind, state: PermissionState) {
  const needSettings = state === "blocked" || state === "settings_required";
  const ok = needSettings
    ? openPermissionSettings(kind)
    : requestPermission(kind);
  if (!ok) {
    ElMessage.warning("系统没有响应授权请求，请到系统设置里手动开启");
  }
}

onMounted(() => {
  const prefs = loadReaderPrefs();
  fontSize.value = prefs.fontSize;
  lineHeight.value = prefs.lineHeight;
  shelfPrompt.value = prefs.promptAddToShelf;
  rate.value = tts.rate;
  voiceId.value = tts.voiceId;
  autoNext.value = tts.autoNext;
  loadAIConfig();
  // 词典：订阅安装进度并刷新包状态（用户可能刚在别处下完一个包）。
  dict.attach();
  dictEnabled.value = dict.enabled;
  dictAutoLookup.value = dict.autoLookup;
  void dict.loadStatus();
  // 权限卡片只在安卓端出现；从系统设置页返回时 onResume 会重读状态并发事件，
  // 这里订阅后界面就能自动从「未开启」翻成「已授权」，不用手动刷新。
  refreshPermissions();
  permOff = onPermissionChanged(refreshPermissions);
});

onUnmounted(() => {
  permOff?.();
  permOff = null;
});

function onFontChange() {
  saveReaderPrefs({ fontSize: fontSize.value, lineHeight: lineHeight.value });
}

function onShelfPromptChange() {
  saveReaderPrefs({ promptAddToShelf: shelfPrompt.value });
}

function onRateChange() {
  tts.setRate(rate.value);
}

function onVoiceChange() {
  tts.setVoice(voiceId.value);
}

function onAutoNextChange() {
  tts.setAutoNext(autoNext.value);
}

/** 恢复默认：用户把字号调乱了要有退路。 */
function resetReader() {
  fontSize.value = 17;
  lineHeight.value = 1.9;
  onFontChange();
  ElMessage.success("已恢复默认排版");
}
</script>

<template>
  <div class="settings-view">
    <h2 class="section-title">阅读</h2>
    <div class="card">
      <div class="row">
        <div class="row-label">
          正文字号
          <span class="row-value">{{ fontSize }}px</span>
        </div>
        <div class="row-control">
          <el-slider
            v-model="fontSize"
            :min="14"
            :max="28"
            :step="1"
            @change="onFontChange"
          />
        </div>
      </div>
      <div class="row">
        <div class="row-label">
          行距
          <span class="row-value">{{ lineHeight.toFixed(1) }}</span>
        </div>
        <div class="row-control">
          <el-slider
            v-model="lineHeight"
            :min="1.2"
            :max="3"
            :step="0.1"
            @change="onFontChange"
          />
        </div>
      </div>
      <!-- 预览：调字号时不用退出去看效果 -->
      <div
        class="preview"
        :style="{ fontSize: fontSize + 'px', lineHeight: lineHeight }"
      >
        这里是正文预览。风急天高猿啸哀，渚清沙白鸟飞回。
      </div>
      <!-- 书籍与漫画共用同一个阅读器，这一个开关同时管两者；默认关闭 -->
      <div class="row">
        <div class="row-label">返回时提示加入书架</div>
        <div class="row-control">
          <el-switch
            v-model="shelfPrompt"
            data-setting="shelf-prompt"
            @change="onShelfPromptChange"
          />
        </div>
      </div>
      <div class="hint">
        阅读书籍或漫画离开阅读器时，若这本书还不在书架，询问一次是否加入。
        默认关闭——只是随手看两章时，这个询问会拦人一下。
      </div>
      <div class="row-actions">
        <el-button link @click="resetReader">恢复默认</el-button>
      </div>
    </div>

    <h2 class="section-title">词典</h2>
    <div class="card">
      <div class="row">
        <div class="row-label">启用取词</div>
        <div class="row-control">
          <el-switch
            v-model="dictEnabled"
            data-setting="dict-enabled"
            @change="onDictEnabled"
          />
        </div>
      </div>
      <div class="row">
        <div class="row-label">选中后自动查询</div>
        <div class="row-control">
          <el-switch
            v-model="dictAutoLookup"
            data-setting="dict-auto-lookup"
            @change="onDictAutoLookup"
          />
        </div>
      </div>
      <div class="hint">
        阅读时选中文字会弹出词典浮层；关闭取词后选中不再弹窗。
        移动端用底栏的「词典」按钮进入取词模式，点正文里的词即可查。
      </div>

      <div class="row">
        <div class="row-label">
          内置核心词库
          <span class="row-value">
            {{ builtinPack ? `${builtinPack.entries.toLocaleString()} 词条 · ${fmtBytes(builtinPack.size)}` : "解压中…" }}
          </span>
        </div>
        <div class="row-control">
          <span class="row-value">随应用分发，不可删除</span>
        </div>
      </div>

      <template v-for="p in extPacks" :key="p.id">
        <div class="row dict-pack" :data-pack="p.id">
          <div class="row-label">
            {{ p.name }}
            <span class="row-value">
              {{ p.installed ? `${p.entries.toLocaleString()} 词条 · ${fmtBytes(p.size)}` : "未安装" }}
            </span>
          </div>
          <div class="row-control">
            <template v-if="dict.installs[p.id] && !dict.installs[p.id].finished">
              <el-progress
                :percentage="dict.installs[p.id].percent ?? 0"
                :indeterminate="dict.installs[p.id].percent === null"
                :stroke-width="8"
                class="r-fit"
                style="--r-fit-w: 130px"
              />
            </template>
            <template v-else>
              <el-button size="small" :data-dict="`install-${p.id}`" @click="openDictDialog(p)">
                {{ p.installed ? "重装" : "下载" }}
              </el-button>
              <el-button
                v-if="p.installed"
                link
                type="danger"
                :data-dict="`remove-${p.id}`"
                @click="removeDictPack(p)"
              >
                删除
              </el-button>
            </template>
          </div>
        </div>
        <div v-if="dict.installs[p.id]" class="hint" :data-pack-status="p.id">
          {{ installSummary(p.id) }}
          <span v-if="switchedNote(p.id)" class="warn">{{ switchedNote(p.id) }}</span>
          <el-button
            v-if="!dict.installs[p.id].finished"
            link
            size="small"
            @click="dict.cancel(p.id)"
          >
            取消
          </el-button>
        </div>
      </template>

      <div class="hint">
        下载源在下载时选择：自动依次尝试 / 指定某个源 / 自建地址。
        所有镜像都不可用时，也可以用「导入本地文件」直接选上游数据文件（ecdict.csv / cedict_ts.u8）。
      </div>
      <div class="hint">
        词库数据：ECDICT（MIT 许可）、CC-CEDICT（CC BY-SA 4.0）。
        词库存放在数据目录的 dict/ 下，与阅读数据互不影响。
      </div>
    </div>

    <DictSourceDialog
      v-model="dictDialog"
      :pack-id="dictPack.id"
      :pack-name="dictPack.name"
      :download-bytes="dictPack.bytes"
    />

    <h2 class="section-title">朗读</h2>
    <div class="card">
      <div class="row">
        <div class="row-label">
          语速
          <span class="row-value">{{ rate }}%</span>
        </div>
        <div class="row-control">
          <el-slider
            v-model="rate"
            :min="50"
            :max="200"
            :step="5"
            @change="onRateChange"
          />
        </div>
      </div>
      <div class="row">
        <div class="row-label">音色</div>
        <div class="row-control">
          <el-select
            v-model="voiceId"
            placeholder="默认音色"
            clearable
            @change="onVoiceChange"
          >
            <el-option
              v-for="v in tts.voices"
              :key="v.id"
              :label="v.name"
              :value="v.id"
            />
          </el-select>
        </div>
      </div>
      <div class="row">
        <div class="row-label">章末自动续读</div>
        <div class="row-control">
          <el-switch v-model="autoNext" @change="onAutoNextChange" />
        </div>
      </div>
      <div v-if="tts.voices.length === 0" class="hint">
        当前环境没有可用音色（系统朗读未安装中文语音包时会出现这种情况）。
      </div>
    </div>

    <h2 class="section-title">AI 助手</h2>
    <div class="card">
      <div class="row">
        <div class="row-label">状态</div>
        <div class="row-control ai-status">
          <span :class="['dot', aiConfigured ? 'ok' : 'idle']"></span>
          <span class="row-value">{{ aiStatus }}</span>
        </div>
      </div>
      <div class="row">
        <div class="row-label">服务地址</div>
        <div class="row-control">
          <el-input
            data-ai="base-url"
            v-model="aiForm.baseURL"
            placeholder="https://api.deepseek.com/v1"
            clearable
          />
        </div>
      </div>
      <div class="row">
        <div class="row-label">API Key</div>
        <div class="row-control ai-key">
          <el-input
            data-ai="api-key"
            v-model="aiForm.apiKey"
            type="password"
            show-password
            :placeholder="
              aiHasKey ? `已保存 ${aiKeyHint}，留空不修改` : 'sk-...'
            "
            clearable
          />
          <el-button v-if="aiHasKey" link @click="clearAIKey">清除</el-button>
        </div>
      </div>
      <div class="row">
        <div class="row-label">模型</div>
        <div class="row-control">
          <el-input
            data-ai="model"
            v-model="aiForm.model"
            placeholder="deepseek-chat"
            clearable
          />
        </div>
      </div>
      <div class="row">
        <div class="row-label">
          温度
          <span class="row-value">{{ aiForm.temperature.toFixed(1) }}</span>
        </div>
        <div class="row-control">
          <el-slider
            v-model="aiForm.temperature"
            :min="0.1"
            :max="2"
            :step="0.1"
          />
        </div>
      </div>
      <div class="row">
        <div class="row-label">上下文窗口</div>
        <div class="row-control">
          <el-input-number
            v-model="aiForm.contextWindow"
            :min="0"
            :max="2000000"
            :step="1000"
            controls-position="right"
          />
        </div>
      </div>
      <div class="hint">
        上下文窗口按 token 计；填 0 表示按模型名自动推断（兜底 8k）。
      </div>

      <!-- 向量配置单列：DeepSeek、Moonshot 等只提供对话接口，
           留空即降级为关键词检索，功能仍可用。 -->
      <div class="sub-title">向量检索（可选）</div>
      <div class="row">
        <div class="row-label">向量服务地址</div>
        <div class="row-control">
          <el-input
            data-ai="emb-base"
            v-model="aiForm.embeddingBaseURL"
            placeholder="留空则复用上面的地址"
            clearable
          />
        </div>
      </div>
      <div class="row">
        <div class="row-label">向量模型</div>
        <div class="row-control">
          <el-input
            data-ai="emb-model"
            v-model="aiForm.embeddingModel"
            placeholder="text-embedding-3-small"
            clearable
          />
        </div>
      </div>
      <div class="row">
        <div class="row-label">向量维度</div>
        <div class="row-control">
          <span class="row-value">
            {{
              aiForm.embeddingDim > 0
                ? `${aiForm.embeddingDim} 维`
                : "测试连接后自动识别"
            }}
          </span>
        </div>
      </div>
      <div class="hint">
        不填向量模型时，问答用关键词匹配召回原文；填了则用语义相似度，细节问题更准。
      </div>

      <div v-if="aiTestResult" class="ai-result">
        <div>
          <span class="dot ok"></span>
          对话可用<template v-if="aiTestResult.chatReply">
            （模型回复：{{ aiTestResult.chatReply }}）</template
          >
        </div>
        <div>
          <span :class="['dot', aiTestResult.embeddingOk ? 'ok' : 'idle']"></span>
          <template v-if="aiTestResult.embeddingOk">
            向量可用（{{ aiTestResult.embeddingDim }} 维）
          </template>
          <template v-else>{{ aiTestResult.embeddingMessage }}</template>
        </div>
      </div>

      <div class="row-actions ai-actions">
        <el-button :loading="aiTesting" @click="testAIConnection">
          测试连接
        </el-button>
        <el-button type="primary" :loading="aiSaving" @click="saveAIConfig">
          保存
        </el-button>
      </div>
    </div>

    <h2 class="section-title">数据与同步</h2>
    <div class="card entries">
      <button
        v-for="e in entries"
        :key="e.path"
        class="entry"
        @click="router.push(e.path)"
      >
        <span class="entry-main">
          <span class="entry-name">{{ e.label }}</span>
          <span class="entry-desc">{{ e.desc }}</span>
        </span>
        <span class="entry-arrow">›</span>
      </button>
    </div>

    <template v-if="permAvailable">
      <h2 class="section-title">权限</h2>
      <div class="card">
        <div class="row">
          <div class="row-label">存储</div>
          <div class="row-control perm-control">
            <span :class="['perm-state', permStorage]">{{
              permissionStateLabel(permStorage)
            }}</span>
            <el-button
              v-if="permStorage !== 'granted' && permStorage !== 'unavailable'"
              data-perm="storage"
              size="small"
              type="primary"
              plain
              @click="fixPermission('storage', permStorage)"
            >
              {{
                permStorage === "blocked" || permStorage === "settings_required"
                  ? "去设置"
                  : "去授权"
              }}
            </el-button>
          </div>
        </div>
        <div class="row">
          <div class="row-label">相机</div>
          <div class="row-control perm-control">
            <span :class="['perm-state', permCamera]">{{
              permissionStateLabel(permCamera)
            }}</span>
            <el-button
              v-if="permCamera !== 'granted' && permCamera !== 'unavailable'"
              data-perm="camera"
              size="small"
              type="primary"
              plain
              @click="fixPermission('camera', permCamera)"
            >
              {{
                permCamera === "blocked" ? "去设置" : "去授权"
              }}
            </el-button>
          </div>
        </div>
        <div class="hint">
          <template v-if="permStorage === 'settings_required'">
            安卓 11 及以上读取手机里的书籍文件需要「所有文件访问」，
            请在系统设置页打开开关后返回。
          </template>
          <template v-else>存储权限用于导入手机里的书籍、备份与漫画目录。</template>
          未授权时仍可用系统文件选择器导入，选中的文件会复制到应用内。
        </div>
      </div>
    </template>

    <h2 class="section-title">关于</h2>
    <div class="card">
      <div class="row">
        <div class="row-label">运行平台</div>
        <div class="row-value">{{ platformLabel }}</div>
      </div>
      <div class="row">
        <div class="row-label">书源引擎</div>
        <div class="row-value">legado-go（兼容阅读 3.0 规则）</div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.settings-view {
  flex: 1;
  min-height: 0;
  overflow: auto;
  padding: var(--r-pad) var(--r-pad) 24px;
  max-width: 720px;
  width: 100%;
  min-width: 0;
}
.section-title {
  margin: 16px 0 8px;
  font-size: 13px;
  font-weight: 600;
  color: #6b7280;
}
.card {
  background: #fff;
  border: 1px solid #e5e7eb;
  border-radius: var(--r-radius);
  padding: var(--r-pad-sm) var(--r-pad) var(--r-pad-sm);
  min-width: 0;
}
.row {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap);
  padding: var(--r-pad-sm) 0;
  border-bottom: 1px solid #f3f4f6;
  min-width: 0;
}
.row:last-child {
  border-bottom: none;
}
.row-label {
  flex: none;
  width: min(100%, 110px);
  min-width: 0;
  font-size: 14px;
  color: #374151;
}
.row-value {
  font-size: 13px;
  color: #6b7280;
}
.row-control {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
}
.row-actions {
  display: flex;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  justify-content: flex-end;
}
/* 预览区随字号变化，给一个最小高度避免滑块跳动 */
.preview {
  margin-top: 8px;
  padding: var(--r-pad-sm);
  border-radius: var(--r-radius-sm);
  background: #fffdf7;
  color: #1f2328;
  min-height: 60px;
  word-break: break-all;
}
.hint {
  padding: 8px 0 0;
  font-size: 12px;
  color: #9ca3af;
}
/* 换源提示：这里的"为什么变慢了"必须看得见，不能用灰色弱化 */
.warn {
  color: #e6a23c;
  margin-left: 6px;
}
/* 权限状态文案 + 授权按钮：窄屏下按钮不能被挤掉 */
.perm-control {
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  min-width: 0;
}
.perm-state {
  font-size: 13px;
  color: #9ca3af;
  white-space: nowrap;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
}
.perm-state.granted {
  color: #16a34a;
}
.perm-state.blocked,
.perm-state.settings_required {
  color: #d97706;
}
.entries {
  padding: 0;
  min-width: 0;
}
.entry {
  display: flex;
  align-items: center;
  gap: var(--r-gap);
  width: 100%;
  min-width: 0;
  padding: var(--r-pad-sm) var(--r-pad);
  border: none;
  border-bottom: 1px solid #f3f4f6;
  background: transparent;
  cursor: pointer;
  text-align: left;
  font-size: 14px;
  color: #1f2328;
  -webkit-tap-highlight-color: transparent;
}
.entry:last-child {
  border-bottom: none;
}
.entry:active {
  background: #f9fafb;
}
.entry-main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.entry-name {
  font-weight: 500;
}
.entry-desc {
  font-size: 12px;
  color: #9ca3af;
}
.entry-arrow {
  flex: none;
  font-size: 18px;
  color: #cbd5e1;
}

/* ── AI 分区 ─────────────────────────────────────────────── */
.sub-title {
  margin: 14px 0 0;
  padding-top: var(--r-pad-sm);
  border-top: 1px dashed #f3f4f6;
  font-size: 13px;
  font-weight: 600;
  color: #6b7280;
}
.ai-status {
  align-items: center;
  gap: var(--r-gap-sm);
}
/* 状态点：用色块而不是文字标签，窄屏下也不占横向空间 */
.dot {
  display: inline-block;
  flex: none;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #d1d5db;
}
.dot.ok {
  background: #22c55e;
}
.dot.idle {
  background: #d1d5db;
}
.ai-key {
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  min-width: 0;
}
.ai-key :deep(.el-input) {
  flex: 1;
  min-width: 0;
}
.row-control :deep(.el-input-number) {
  width: 100%;
}
.ai-result {
  display: flex;
  flex-direction: column;
  gap: var(--r-gap-sm);
  margin-top: 12px;
  padding: var(--r-pad-sm) var(--r-pad);
  border-radius: var(--r-radius-sm);
  background: #f9fafb;
  font-size: 13px;
  color: #374151;
  min-width: 0;
}
.ai-result > div {
  display: flex;
  align-items: center;
  gap: var(--r-gap-sm);
  min-width: 0;
}
.ai-actions {
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  margin-top: var(--r-gap);
}

@media (max-width: 640px) {
  .settings-view {
    padding: var(--r-pad-sm) var(--r-pad) calc(var(--r-pad) * 2);
  }
  /* 窄屏下标签不再占固定宽度，改为上下堆叠给滑块留出完整操作区 */
  .row {
    flex-direction: column;
    align-items: stretch;
    gap: var(--r-gap-sm);
  }
  .row-label {
    width: auto;
  }
  .row-control {
    justify-content: stretch;
  }
  .row-value {
    text-align: right;
  }
  .card {
    padding: var(--r-pad-sm) var(--r-pad);
  }
  .ai-result {
    padding: var(--r-pad-sm);
  }
}
</style>
