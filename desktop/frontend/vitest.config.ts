import { fileURLToPath, URL } from "node:url";

import { defineConfig } from "vitest/config";

/**
 * 单测配置（与 vite.config.ts 分开）。
 *
 * 不 merge 主配置：主配置里挂着 Wails 的插件，单测用不到还会拖慢启动。
 * 单测只覆盖 `src/tts` 这类纯逻辑，不涉及 Wails 绑定，所以只需要 `@` 别名。
 */
export default defineConfig({
  resolve: {
    alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) },
  },
  test: {
    environment: "jsdom",
    include: ["src/**/*.test.ts"],
  },
});
