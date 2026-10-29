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
    path: "/webdav",
    name: "webdav",
    component: () => import("@/views/WebDAVView.vue"),
    meta: { title: "WebDAV" },
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
];

export const router = createRouter({
  history: createWebHistory(),
  routes,
});
