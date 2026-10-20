# 应用图标

- `app-icon.png`：高分辨率透明背景母版，浅色圆角底板、深色视频画框、`A → 文` 翻译符号与白色/橙色双语字幕条。
- `AppIcon.icns`：应用打包使用的 macOS 图标，包含 16、32、128、256、512pt 的普通与 Retina 尺寸。

在 macOS 上运行 `bash scripts/build_icon.sh`，可由 PNG 母版重新生成 ICNS。应用集成时，将 `AppIcon.icns` 复制到应用包的 `Contents/Resources/`，并将 `Info.plist` 中的 `CFBundleIconFile` 设置为 `AppIcon`。图标素材可独立于应用功能代码合并。

PNG 母版保留透明外缘；导出各尺寸时保持该透明度，不额外添加背景。
