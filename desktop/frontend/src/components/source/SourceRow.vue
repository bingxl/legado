<script setup lang="ts">
/**
 * 书源列表行。
 *
 * 布局照搬 Legado 原生的 BookSourceAdapter 视图：
 *  [✓ 名称 + 分组]  [发现圆点]  [启用开关]  [编辑]  [更多]
 * 下方是校验消息（原生 ivDebugText）。
 *
 * 为什么不用 el-table：原生每行是「名称 + 一行状态」，不是表格语义；
 * 用表格会把启用开关、更多菜单塞进固定的列宽里，窄屏（安卓端同一套前端）
 * 直接挤成一团。自定义行在 412px 宽度下依然可用。
 */
import { computed } from "vue";

import type { SourceView } from "@/types";
import type { CheckMessage } from "@/stores/sourceCheck";
import { splitGroups, typeLabel } from "@/utils/sourceList";

const props = defineProps<{
  source: SourceView;
  selected: boolean;
  /** 本行的校验结论（有则显示） */
  message?: CheckMessage;
  /** 是否正在校验（显示转圈） */
  checking: boolean;
  /** 此刻允许拖拽排序 */
  canDrag: boolean;
  /** 手动排序下才有「置顶/置底」 */
  showTopBottom: boolean;
}>();

const emit = defineEmits<{
  (e: "select", v: boolean): void;
  (e: "edit"): void;
  (e: "toggle-enabled", v: boolean): void;
  (e: "command", cmd: string): void;
}>();

const groups = computed(() => splitGroups(props.source.group));

/** 发现状态：没有 exploreUrl 就不显示圆点（原生 ivExplore 同样隐藏）。 */
const exploreState = computed(() => {
  if (!props.source.hasExploreUrl) return "none";
  return props.source.enabled && props.source.enabledExplore
    ? "on"
    : "off";
});

const exploreTitle = computed(() => {
  if (exploreState.value === "on") return "已启用发现";
  if (exploreState.value === "off") return "未启用发现";
  return "";
});

/** 非文本类书源给个类型徽标，避免把漫画源当小说源用。 */
const typeBadge = computed(() =>
  props.source.type > 0 ? typeLabel(props.source.type) : "",
);

function onCommand(cmd: string) {
  emit("command", cmd);
}
</script>

<template>
  <div
    class="src-row"
    :class="{ 'is-selected': selected, 'is-off': !source.enabled }"
    :draggable="canDrag"
    :data-source-id="source.id"
    :data-source-url="source.url"
    @dblclick="emit('edit')"
  >
    <el-checkbox
      class="row-check"
      :model-value="selected"
      :title="selected ? '取消选择' : '选择'"
      @change="(v: string | number | boolean) => emit('select', Boolean(v))"
    />

    <div class="row-main" @click="emit('select', !selected)">
      <div class="row-line">
        <span class="row-name">{{ source.name || "(未命名)" }}</span>
        <span v-if="groups.length" class="row-groups">
          <span v-for="g in groups" :key="g" class="row-group">{{ g }}</span>
        </span>
        <span v-if="typeBadge" class="row-type">{{ typeBadge }}</span>
        <span v-if="source.hasLoginUrl" class="row-login" title="配置了登录">登录</span>
      </div>
      <div class="row-url" :title="source.url">{{ source.url }}</div>
      <div
        v-if="message"
        class="row-msg"
        :class="message.ok ? 'ok' : 'bad'"
        :title="message.text"
      >
        <span v-if="checking" class="spinner" />
        <span class="row-msg-text">{{ message.text }}</span>
      </div>
    </div>

    <span
      v-if="exploreState !== 'none'"
      class="explore-dot"
      :class="exploreState"
      :title="exploreTitle"
    />

    <el-switch
      class="row-switch"
      :model-value="source.enabled"
      :title="source.enabled ? '停用' : '启用'"
      @change="(v: string | number | boolean) => emit('toggle-enabled', Boolean(v))"
      @click.stop
    />

    <el-button
      class="row-btn"
      link
      title="编辑"
      data-role="edit"
      @click.stop="emit('edit')"
      >✎</el-button
    >

    <el-dropdown
      trigger="click"
      placement="bottom-end"
      @command="onCommand"
      @click.stop
    >
      <el-button class="row-btn" link title="更多" data-role="more">⋮</el-button>
      <template #dropdown>
        <el-dropdown-menu>
          <el-dropdown-item v-if="showTopBottom" command="top">置顶</el-dropdown-item>
          <el-dropdown-item v-if="showTopBottom" command="bottom">置底</el-dropdown-item>
          <el-dropdown-item v-if="source.hasLoginUrl" command="login" divided>
            登录
          </el-dropdown-item>
          <el-dropdown-item command="search">搜索本书源</el-dropdown-item>
          <el-dropdown-item command="debug">调试</el-dropdown-item>
          <el-dropdown-item v-if="source.hasExploreUrl" command="toggle-explore">
            {{ source.enabledExplore ? "禁用发现" : "启用发现" }}
          </el-dropdown-item>
          <el-dropdown-item command="delete" divided>删除</el-dropdown-item>
        </el-dropdown-menu>
      </template>
    </el-dropdown>
  </div>
</template>

<style scoped>
.src-row {
  display: flex;
  align-items: center;
  gap: var(--r-gap-sm);
  padding: var(--r-pad-sm) var(--r-pad);
  min-width: 0;
  max-width: 100%;
  border-bottom: 1px solid var(--el-border-color-lighter);
  cursor: default;
}
.src-row:hover {
  background: var(--el-fill-color-light);
}
.src-row.is-selected {
  background: var(--el-color-primary-light-9);
}
/* 停用的源整体降低存在感，但不要灰到看不清名字 */
.src-row.is-off .row-name {
  color: var(--el-text-color-secondary);
}
.src-row[draggable="true"] {
  cursor: grab;
}
.src-row.dragging {
  opacity: 0.4;
}
.row-check {
  flex: none;
  margin-right: 0;
}
.row-main {
  flex: 1;
  min-width: 0;
  cursor: pointer;
}
.row-line {
  display: flex;
  align-items: center;
  gap: var(--r-gap-sm);
  min-width: 0;
}
.row-name {
  font-size: 14px;
  font-weight: 500;
  min-width: 0;
  color: var(--el-text-color-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.row-groups {
  display: inline-flex;
  gap: var(--r-gap-sm);
  flex: none;
  min-width: 0;
}
.row-group {
  font-size: 11px;
  padding: 0 5px;
  border-radius: var(--r-radius-sm);
  color: var(--el-color-primary);
  background: var(--el-color-primary-light-9);
}
.row-type,
.row-login {
  flex: none;
  font-size: 11px;
  padding: 0 5px;
  border-radius: var(--r-radius-sm);
  color: var(--el-text-color-secondary);
  background: var(--el-fill-color);
}
.row-login {
  color: var(--el-color-success);
  background: var(--el-color-success-light-9);
}
.row-url {
  margin-top: 2px;
  min-width: 0;
  max-width: 100%;
  font-size: 12px;
  color: var(--el-text-color-secondary);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.row-msg {
  display: flex;
  align-items: center;
  gap: var(--r-gap-sm);
  min-width: 0;
  margin-top: 3px;
  font-size: 12px;
}
.row-msg.ok {
  color: var(--el-color-success);
}
.row-msg.bad {
  color: var(--el-color-danger);
}
.row-msg-text {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.spinner {
  flex: none;
  width: 10px;
  height: 10px;
  border: 2px solid var(--el-color-primary-light-5);
  border-top-color: var(--el-color-primary);
  border-radius: 50%;
  animation: spin 0.8s linear infinite;
}
@keyframes spin {
  to {
    transform: rotate(360deg);
  }
}
.explore-dot {
  flex: none;
  width: 8px;
  height: 8px;
  border-radius: 50%;
}
.explore-dot.on {
  background: var(--el-color-success);
}
.explore-dot.off {
  background: var(--el-color-danger);
}
.row-switch {
  flex: none;
}
.row-btn {
  flex: none;
  font-size: 15px;
  padding: 0 4px;
  color: var(--el-text-color-regular);
}

/* 窄屏（安卓端同一套前端）：藏掉地址行与徽标，保证开关和菜单点得到 */
@media (max-width: 640px) {
  .src-row {
    padding: var(--r-pad-sm);
    gap: var(--r-gap-sm);
  }
  .row-url {
    display: none;
  }
  .row-groups,
  .row-type,
  .row-login {
    display: none;
  }
}
</style>
