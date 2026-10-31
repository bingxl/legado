import { createRouter, createWebHistory } from "vue-router";

/** 路由表。阅读器使用独立布局，因此单独定义。 */
const routes = [
  {
    path: "/",
    name: "shelf",
    component: () => import("@/views/ShelfView.vue"),
    meta: { title: "书架" },
  },
  {
    path: "/explore",
    name: "explore",
    component: () => import("@/views/ExploreView.vue"),
    meta: { title: "发现" },
  },
  {
    path: "/search",
    name: "search",
    component: () => import("@/views/SearchView.vue"),
    meta: { title: "搜索" },
  },
  {
    path: "/sources",
    name: "sources",
    component: () => import("@/views/SourceView.vue"),
    meta: { title: "书源" },
  },
  {
    // 必须排在 /sources/:id/edit 前面，否则 "new" 会被当成 ID。
    path: "/sources/new",
    name: "source-new",
    component: () => import("@/views/SourceEditView.vue"),
    meta: { title: "新建书源" },
  },
  {
    path: "/sources/:id/edit",
    name: "source-edit",
    component: () => import("@/views/SourceEditView.vue"),
    meta: { title: "编辑书源" },
    props: true,
  },
  {
    path: "/cache",
    name: "cache",
    component: () => import("@/views/CacheView.vue"),
    meta: { title: "缓存" },
  },
  {
    path: "/replace",
    name: "replace",
    component: () => import("@/views/ReplaceRuleView.vue"),
    meta: { title: "替换规则" },
  },
  {
    path: "/subscriptions",
    name: "subscriptions",
    component: () => import("@/views/SubscriptionView.vue"),
    meta: { title: "书源订阅" },
  },
  {
    // 设置页在移动端兼作「我的」，是替换/订阅/缓存/WebDAV 的入口。
    path: "/settings",
    name: "settings",
    component: () => import("@/views/SettingsView.vue"),
    meta: { title: "设置" },
  },
  {
    path: "/webdav",
    name: "webdav",
    component: () => import("@/views/WebDAVView.vue"),
    meta: { title: "WebDAV" },
  },
  {
    // AI 问答：`?book=<id>` 指定书籍，不指定时由页面内选择。
    path: "/ai",
    name: "ai",
    component: () => import("@/views/AIView.vue"),
    meta: { title: "AI 问答" },
  },
  {
    path: "/book/:id",
    name: "book",
    component: () => import("@/views/BookDetailView.vue"),
    meta: { title: "书籍详情" },
    props: true,
  },
  {
    path: "/reader/:id",
    name: "reader",
    component: () => import("@/views/ReaderView.vue"),
    meta: { title: "阅读" },
    props: true,
  },
  {
    // 兜底：未知路径回书架。
    // 后端对无扩展名的路径统一回退到 index.html（见 main.go spaHandler），
    // 所以这类地址会真的落到这里；没有它就会白屏。
    path: "/:pathMatch(.*)*",
    redirect: "/",
  },
];

export const router = createRouter({
  history: createWebHistory(),
  routes,
});
