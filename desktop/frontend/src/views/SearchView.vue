<script setup lang="ts">
import { ref } from "vue";
import { ElMessage } from "element-plus";
import { useRouter } from "vue-router";

import { sourceApi } from "@/api/source";
import { coverURL } from "@/utils/media";
import type { SearchResultView, SourceView } from "@/types";

const router = useRouter();
const keyword = ref("");
const results = ref<SearchResultView[]>([]);
const loading = ref(false);
const sources = ref<SourceView[]>([]);
const sourceId = ref(0);

async function load() {
  sources.value = await sourceApi.list("");
}
load();

async function search() {
  if (!keyword.value.trim()) {
    ElMessage.warning("请输入关键词");
    return;
  }
  loading.value = true;
  results.value = [];
  try {
    results.value =
      sourceId.value === 0
        ? await sourceApi.searchAll(keyword.value.trim(), 1)
        : await sourceApi.search(sourceId.value, keyword.value.trim(), 1);
    if (results.value.length === 0) ElMessage.info("没有找到结果");
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    loading.value = false;
  }
}

async function addToShelf(r: SearchResultView) {
  try {
    const sid = await resolveSourceId(r);
    // 带上书名/作者：详情页规则取不到书名时用它兜底，否则落库会失败。
    // variable 是列表页 @put 的变量，目录/正文的 @get 依赖它。
    await sourceApi.addToShelf(sid, r.bookUrl, r.name, r.author, r.variable ?? "", 0);
    ElMessage.success(`《${r.name}》已加入书架`);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/** 点结果行 → 先入库拿到 book id，再进详情页（与发现页一致）。 */
const opening = ref("");
async function openBook(r: SearchResultView) {
  if (opening.value) return;
  opening.value = r.bookUrl;
  try {
    const sid = await resolveSourceId(r);
    const brief = await sourceApi.addToShelf(
      sid,
      r.bookUrl,
      r.name,
      r.author,
      r.variable ?? "",
      0,
    );
    if (!brief) return;
    router.push({ name: "book", params: { id: String(brief.id) } });
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    opening.value = "";
  }
}

/** 结果自带的 origin 就是书源 URL，据此反查书源 ID。 */
async function resolveSourceId(r: SearchResultView): Promise<number> {
  if (sourceId.value !== 0) return sourceId.value;
  const hit = sources.value.find((s) => s.url === r.origin);
  if (hit) return hit.id;
  throw new Error("无法定位该书所属书源，请在指定书源下重试");
}
</script>

<template>
  <div class="search-view">
    <header class="toolbar">
      <el-input
        v-model="keyword"
        placeholder="输入书名或作者"
        style="width: 300px"
        @keyup.enter="search"
      />
      <el-select v-model="sourceId" style="width: 200px">
        <el-option :value="0" label="全部书源" />
        <el-option
          v-for="s in sources"
          :key="s.id"
          :value="s.id"
          :label="s.name"
        />
      </el-select>
      <el-button type="primary" :loading="loading" @click="search">搜索</el-button>
      <div class="spacer" />
      <el-button @click="router.push('/sources')">管理书源</el-button>
    </header>

    <div class="results" v-loading="loading">
      <el-empty v-if="results.length === 0" description="输入关键词开始搜索" />
      <div
        v-for="(r, i) in results"
        :key="i"
        class="result"
        :class="{ opening: opening === r.bookUrl }"
        @click="openBook(r)"
      >
        <div class="cover">
          <img v-if="r.cover" :src="coverURL(r.cover)" :alt="r.name" />
        </div>
        <div class="info">
          <div class="name">{{ r.name }}</div>
          <div class="author">{{ r.author }}</div>
          <div class="intro">{{ r.intro }}</div>
          <div class="from">来自 {{ r.originName || r.origin }}</div>
        </div>
        <div class="ops" @click.stop>
          <el-button size="small" type="primary" @click="addToShelf(r)">
            加入书架
          </el-button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.search-view {
  display: flex;
  flex-direction: column;
  height: 100%;
}
.toolbar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 12px 16px;
}
.spacer {
  flex: 1;
}
.results {
  flex: 1;
  overflow: auto;
  padding: 0 16px 16px;
}
.result {
  display: flex;
  gap: 12px;
  padding: 12px;
  background: #fff;
  border: 1px solid #e5e7eb;
  border-radius: 8px;
  margin-bottom: 10px;
  cursor: pointer;
}
.result:hover {
  border-color: #c7d2fe;
}
.result.opening {
  opacity: 0.55;
  pointer-events: none;
}
.cover {
  width: 72px;
  height: 100px;
  flex: none;
  background: #f3f4f6;
  border-radius: 4px;
  overflow: hidden;
}
.cover img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.info {
  flex: 1;
  min-width: 0;
}
.name {
  font-weight: 600;
}
.author,
.from {
  font-size: 12px;
  color: #6b7280;
  margin-top: 2px;
}
.intro {
  font-size: 12px;
  color: #4b5563;
  margin-top: 6px;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.ops {
  display: flex;
  align-items: center;
}
</style>
