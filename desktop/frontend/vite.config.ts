import { fileURLToPath, URL } from "node:url";
import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import wails from "@wailsio/runtime/plugins/vite";

// https://vitejs.dev/config/
export default defineConfig({
  resolve: {
    alias: {
      // "@" 指向 src，避免深层相对路径。
      "@": fileURLToPath(new URL("./src", import.meta.url)),
      // "@bindings" 指向自动生成目录。
      // 约定：只有 src/api 下的模块允许引用它（见 ARCHITECTURE.md R4）。
      "@bindings": fileURLToPath(new URL("./bindings", import.meta.url)),
    },
  },
  server: {
    host: "127.0.0.1",
    port: Number(process.env.WAILS_VITE_PORT) || 9245,
    strictPort: true,
  },
  plugins: [vue(), wails("./bindings")],
});
