# 应用图标说明

## 文件与用途

| 文件 | 用途 |
| --- | --- |
| `build/appicon.svg` | **矢量源文件**（改设计只改这里） |
| `build/appicon.png` | 1024×1024 位图，`wails3 generate icons` 的输入 |
| `build/windows/icon.ico` | 由 `generate:icons` 从 PNG 生成，`generate:syso` 嵌入 exe 资源 |
| `build/darwin/icons.icns` | 由 `generate:icons` 生成（macOS 打包用） |
| `frontend/public/appicon.svg` | 前端 favicon 与侧栏品牌图标 |

## 构建链路（无需手动干预）

`wails3 task build`（Windows）自动执行：

1. `common:generate:icons`：`appicon.png` → `windows/icon.ico` + `darwin/icons.icns`
2. `generate:syso`：`icon.ico` + `wails.exe.manifest` + `info.json` → `.syso` 资源
3. `go build`：链接器自动把 `.syso` 嵌入 exe（任务栏/资源管理器图标）

## 修改图标的流程

1. 编辑 `build/appicon.svg`（视口 1024×1024，安全区内边距约 32px）
2. 重新渲染 PNG：

   ```bash
   python -c "import resvg_py; open('build/appicon.png','wb').write(resvg_py.svg_to_bytes(svg_path='build/appicon.svg', width=1024, height=1024))"
   ```

   （需要 `pip install resvg-py`；或用任意 SVG→PNG 工具输出 1024×1024）
3. 跑一次 `wails3 task build` 即可，`generate:icons` 会检测 `appicon.png` 变化自动重新生成 ico/icns。

## 备注

- macOS 的 Icon Composer 源（`build/appicon.icon/`）仍为 Wails 默认矢量，仅在 macOS 打包时使用；如需 macOS 也用新图标，把书本图形（透明底、无底板）放入 `appicon.icon/Assets/` 并保留 `icon.json` 的填充设置。
- 设计稿：靛蓝→紫渐变圆角方板 + 摊开的书页（暖米色）+ 底部燕尾书签（琥珀色），正文纹理为暖金色短行。
