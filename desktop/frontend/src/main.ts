import { createApp } from "vue";
import { createPinia } from "pinia";
import ElementPlus from "element-plus";
import "element-plus/dist/index.css";
// 统一响应式基线必须在 Element Plus 之后引入，才能覆盖它的默认尺寸。
import "./styles/responsive.css";

import App from "./App.vue";
import { router } from "./router";

createApp(App).use(createPinia()).use(router).use(ElementPlus).mount("#app");
