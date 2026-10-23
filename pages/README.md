# 项目网站

面向 `https://vat.zfdang.com` 的静态项目介绍页。无需 Node.js、第三方前端依赖或构建步骤。

- `index.html`：功能介绍、使用流程与下载入口。
- `styles.css`：响应式样式。
- `assets/`：应用图标与实际工作台截图。工作台截图于 2026-10-23 直接截取自实际运行的 `dist/VideoAutoTranslate.app`，展示本地视频完成识别与翻译后的界面；未使用修改版 UI 或占位字幕。
- `CNAME`：记录预期域名；使用 Actions 部署时，实际域名以仓库 Pages 设置为准。

本地预览（在仓库根目录执行）：

```bash
python3 -m http.server 8080 --directory pages
```

打开 `http://localhost:8080`。完整部署、域名和 HTTPS 设置见[自动化与发布](../docs/workflows.md#项目网站)。
