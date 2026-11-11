<script setup lang="ts">
/**
 * 书源分组表单。
 *
 * 按 config/sourceFields 的定义渲染 7 组共 70 个字段——字段清单与 Legado 官方
 * Web 编辑器一致，顺序也一致，用户在两端之间迁移书源时不会找不到东西。
 *
 * 布局上刻意保留「左侧分组标签页 + 可滚动表单」：书源的规则分散在
 * 搜索/发现/详情/目录/正文五组，平铺成一长页会让人不知道自己在改哪一段。
 */
import { computed, ref } from "vue";

import {
  BOOK_SOURCE_GROUPS,
  type SourceFieldDef,
} from "@/config/sourceFields";
import { useSourceEditStore } from "@/stores/sourceEdit";

const store = useSourceEditStore();

const activeGroup = computed({
  get: () => store.activeGroup,
  set: (v: string) => {
    store.activeGroup = v;
  },
});

const currentGroup = computed(
  () =>
    BOOK_SOURCE_GROUPS.find((g) => g.key === store.activeGroup) ??
    BOOK_SOURCE_GROUPS[0],
);

/** 规则类字段（ruleSearch.* 这种）用等宽字体，方便对齐竖线分隔的多个规则。 */
function isRuleField(f: SourceFieldDef): boolean {
  return f.path.length > 1;
}

/** 顶层里内容可能很长的字段，用多行输入。 */
const LONG_TOP_FIELDS = new Set([
  "loginUi",
  "loginCheckJs",
  "coverDecodeJs",
  "header",
  "variableComment",
  "jsLib",
  "exploreUrl",
  "searchUrl",
  "bookUrlPattern",
]);

function isMultiline(f: SourceFieldDef): boolean {
  return isRuleField(f) || LONG_TOP_FIELDS.has(f.path[0]);
}

function strValue(f: SourceFieldDef): string {
  const v = store.getField(f.path);
  return v === undefined || v === null ? "" : String(v);
}

function boolValue(f: SourceFieldDef): boolean {
  return Boolean(store.getField(f.path));
}

function numValue(f: SourceFieldDef): number {
  const v = store.getField(f.path);
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

function arrayValue(f: SourceFieldDef): number {
  const v = store.getField(f.path);
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

function setStr(f: SourceFieldDef, v: string): void {
  store.setField(f.path, v);
}

function setBool(f: SourceFieldDef, v: boolean): void {
  store.setField(f.path, v);
}

function setNum(f: SourceFieldDef, v: number | undefined): void {
  store.setField(f.path, v ?? 0);
}

// ── 大编辑器：规则一长（含 js、多行正则）小输入框就没法用了 ──────────────
const bigOpen = ref(false);
const bigField = ref<SourceFieldDef | null>(null);
const bigText = ref("");

function openBig(f: SourceFieldDef): void {
  bigField.value = f;
  bigText.value = strValue(f);
  bigOpen.value = true;
}

function applyBig(): void {
  if (!bigField.value) return;
  store.setField(bigField.value.path, bigText.value);
  bigOpen.value = false;
}

/** 当前分组的必填项是否都填了，用于标签页上的小圆点提示。 */
function groupHasMissing(key: string): boolean {
  const g = BOOK_SOURCE_GROUPS.find((x) => x.key === key);
  if (!g) return false;
  return g.fields.some(
    (f) => f.required && strValue(f).trim() === "",
  );
}
</script>

<template>
  <div class="source-form">
    <!-- 分组切换条自己画，不用 el-tabs：这里只需要一排按钮，
         el-tabs 的空 pane 会带来多余的高度计算与滚动容器。 -->
    <div class="group-bar">
      <button
        v-for="g in BOOK_SOURCE_GROUPS"
        :key="g.key"
        type="button"
        :class="['group-btn', { active: g.key === activeGroup }]"
        @click="activeGroup = g.key"
      >
        {{ g.name }}
        <i v-if="groupHasMissing(g.key)" class="tab-dot" title="有必填项未填" />
      </button>
    </div>

    <div class="form-body">
      <el-form label-position="top" class="field-form">
        <el-form-item
          v-for="f in currentGroup.fields"
          :key="f.path.join('.')"
          :data-path="f.path.join('.')"
          :required="f.required"
          class="field-item"
        >
          <template #label>
            <span class="field-label">
              <span class="field-title">{{ f.title }}</span>
              <code class="field-key">{{ f.path.join(".") }}</code>
              <el-tooltip
                v-if="f.hint"
                :content="f.hint"
                placement="top"
                popper-class="field-hint"
              >
                <span class="field-help">?</span>
              </el-tooltip>
              <span
                v-if="isMultiline(f)"
                class="field-expand"
                title="放大编辑"
                @click="openBig(f)"
                >⤢</span
              >
            </span>
          </template>

          <!-- 开关 -->
          <el-switch
            v-if="f.type === 'Boolean'"
            :model-value="boolValue(f)"
            @update:model-value="(v: string | number | boolean) => setBool(f, Boolean(v))"
          />

          <!-- 数字 -->
          <el-input-number
            v-else-if="f.type === 'Number'"
            :model-value="numValue(f)"
            :min="0"
            controls-position="right"
            @update:model-value="(v: number | undefined) => setNum(f, v)"
          />

          <!-- 枚举 -->
          <el-select
            v-else-if="f.type === 'Array'"
            :model-value="arrayValue(f)"
            class="r-fit"
            style="--r-fit-w: 200px"
            @update:model-value="(v: number) => setNum(f, v)"
          >
            <el-option
              v-for="(label, index) in f.options"
              :key="label"
              :label="label"
              :value="index"
            />
          </el-select>

          <!-- 多行文本（规则、JS） -->
          <el-input
            v-else-if="isMultiline(f)"
            :model-value="strValue(f)"
            type="textarea"
            :placeholder="f.hint"
            :class="{ mono: isRuleField(f) }"
            :autosize="{ minRows: 1, maxRows: 6 }"
            @update:model-value="(v: string) => setStr(f, v)"
          />

          <!-- 单行文本 -->
          <el-input
            v-else
            :model-value="strValue(f)"
            :placeholder="f.hint"
            @update:model-value="(v: string) => setStr(f, v)"
          />
        </el-form-item>
      </el-form>
    </div>

    <el-dialog
      v-model="bigOpen"
      :title="bigField ? bigField.title : '编辑'"
      width="760"
      append-to-body
    >
      <div class="big-hint">
        <code>{{ bigField?.path.join(".") }}</code>
        <span v-if="bigField?.hint">— {{ bigField.hint }}</span>
      </div>
      <el-input
        v-model="bigText"
        type="textarea"
        class="mono r-full"
        :autosize="{ minRows: 12, maxRows: 24 }"
      />
      <template #footer>
        <el-button @click="bigOpen = false">取消</el-button>
        <el-button type="primary" @click="applyBig">应用</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.source-form {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  min-width: 0;
  max-width: 100%;
}
.form-tabs {
  flex: none;
}
.form-tabs :deep(.el-tabs__header) {
  margin: 0 0 8px;
}
.form-tabs :deep(.el-tabs__content) {
  display: none;
}
.tab-label {
  display: inline-flex;
  align-items: center;
  gap: 4px;
}
.tab-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: #f56c6c;
}
.group-bar {
  flex: none;
  display: flex;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  min-width: 0;
  max-width: 100%;
  padding-bottom: var(--r-pad-sm);
  border-bottom: 1px solid var(--el-border-color-lighter);
  margin-bottom: var(--r-pad-sm);
}
.group-btn {
  display: inline-flex;
  align-items: center;
  gap: var(--r-gap-sm);
  min-width: 0;
  padding: var(--r-pad-sm) var(--r-pad);
  border: none;
  background: transparent;
  border-radius: var(--r-radius-sm);
  font-size: 13px;
  color: var(--el-text-color-regular);
  cursor: pointer;
}
.group-btn:hover {
  background: var(--el-fill-color-light);
}
.group-btn.active {
  color: var(--el-color-primary);
  background: var(--el-color-primary-light-9);
  font-weight: 600;
}
.form-body {
  flex: 1;
  min-height: 0;
  min-width: 0;
  max-width: 100%;
  overflow-y: auto;
  padding: var(--r-pad-sm) var(--r-pad-sm) var(--r-pad) var(--r-pad-sm);
}
.field-form {
  display: flex;
  flex-direction: column;
  min-width: 0;
  max-width: 100%;
}
.field-item {
  margin-bottom: var(--r-pad);
  min-width: 0;
  max-width: 100%;
}
.field-label {
  display: inline-flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  min-width: 0;
  max-width: 100%;
  width: 100%;
}
.field-title {
  font-weight: 600;
  font-size: 13px;
  min-width: 0;
}
.field-key {
  font-size: 11px;
  min-width: 0;
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--el-text-color-placeholder);
  background: var(--el-fill-color-light);
  padding: 0 4px;
  border-radius: var(--r-radius-sm);
}
.field-help {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 14px;
  height: 14px;
  border-radius: 50%;
  border: 1px solid var(--el-border-color);
  font-size: 10px;
  color: var(--el-text-color-secondary);
  cursor: help;
}
.field-expand {
  margin-left: auto;
  min-width: 0;
  cursor: pointer;
  color: var(--el-color-primary);
  font-size: 13px;
  opacity: 0.7;
}
.field-expand:hover {
  opacity: 1;
}
.mono :deep(textarea),
.mono :deep(input) {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 12px;
  line-height: 1.5;
  max-width: 100%;
}
.big-hint {
  margin-bottom: var(--r-pad-sm);
  min-width: 0;
  word-break: break-word;
  font-size: 12px;
  color: var(--el-text-color-secondary);
}

@media (max-width: 1024px) {
  .group-bar {
    gap: var(--r-gap-sm);
  }
  .group-btn {
    padding: var(--r-pad-sm);
  }
  .field-item {
    margin-bottom: var(--r-pad-sm);
  }
}

@media (max-width: 640px) {
  .form-body {
    padding: var(--r-pad-sm);
  }
  .field-label {
    flex-wrap: wrap;
  }
}
</style>
