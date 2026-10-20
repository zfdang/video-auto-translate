# 应用图标

- `app-icon.png`：高分辨率透明背景母版，浅色圆角底板、深色视频画框、`A → 文` 翻译符号与白色/橙色双语字幕条。
- `AppIcon.icns`：应用打包使用的 macOS 图标，包含 16、32、128、256、512pt 的普通与 Retina 尺寸。

在 macOS 上运行 `bash scripts/build_icon.sh`，可由 PNG 母版重新生成 ICNS。打包脚本 `build_app.sh` 会复制图标到应用 Resources 并配置 `CFBundleIconFile`。

PNG 母版保留透明外缘；导出各尺寸时保持该透明度，不额外添加背景。
