# 自动化与发布

[返回 README](../README.md)

## CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) 检查发往 `main` 的 Pull Request 和 `main` 上的推送：

- Ubuntu：发布版本与发布说明脚本测试、ASR 响应和时间戳契约测试。
- macOS 14 arm64：准备内嵌 Python 运行环境，再执行 `swift test`。部分集成测试需要联网，Ollama 不可达时相应实时翻译测试跳过。

纯 Markdown、设计文档、历史评审、网站、许可证和忽略规则更新跳过应用 CI。网站有独立检查和部署流程。CI 的 SPM 缓存仅加速构建，不能替代 Python 环境准备。

## 应用发布

[`.github/workflows/release.yml`](../.github/workflows/release.yml) 在影响应用或发布流程的变更进入 `main` 后自动运行，也可手动触发；手动运行仅允许在 `main` 上发布。纯文档和网站更新不会触发应用发布。

1. 基于已发布版本和完整 Git 历史生成发布说明。
2. 计算版本号，测试发布脚本，准备内嵌 Python，运行 Swift 测试。
3. 通过 `build_app.sh` 编译应用，再运行 `scripts/package-release.sh` 验证签名并打包。
4. 上传 DMG、ZIP 和 `SHA256SUMS.txt`，发布 GitHub Release。相同标签已存在时跳过发布。

版本号由提交时间（Asia/Singapore）和提交数确定，例如 `v26-10-21.069`；计算规则见 [`scripts/release-metadata.sh`](../scripts/release-metadata.sh)。打包产物保存在 `dist/release/`。当前应用使用 ad-hoc 签名，未进行 Developer ID 签名或 Apple 公证。

本地复现打包：

```bash
eval "$(./scripts/release-metadata.sh)"
export RELEASE_TAG RELEASE_BUNDLE_VERSION RELEASE_COMMIT_COUNT RELEASE_PACKAGE_VERSION
./build_app.sh
./scripts/package-release.sh
```

必须使用完整 Git 历史；浅克隆会被版本脚本拒绝。发布 workflow 中仅发布任务拥有 `contents: write`，其余任务使用只读仓库权限。

## 项目网站

网站源文件位于 [`pages/`](../pages/README.md)，目标域名为 **`vat.zfdang.com`**。页面为静态 HTML/CSS，不依赖前端构建工具。

[`.github/workflows/pages.yml`](../.github/workflows/pages.yml) 对网站 Pull Request 检查文件并上传站点产物；合并到 `main` 后才部署 GitHub Pages。也支持在 `main` 手动运行。部署任务使用 `pages: write` 和 `id-token: write`，不拥有仓库写权限。

首次部署设置：

1. 在仓库 **Settings → Pages → Build and deployment** 中选择 **GitHub Actions**。
2. 在 Pages 的 **Custom domain** 中设置 `vat.zfdang.com`。`pages/CNAME` 仅记录域名，Actions 部署不会靠该文件配置仓库域名。
3. DNS 中将 `vat` 的 CNAME 指向 `zfdang.github.io`。域名服务商若启用了代理，公开 DNS 可能返回代理 IP；仍需确认源站指向 GitHub Pages，并通过 GitHub 域名检查。
4. 域名验证、证书签发完成后启用 **Enforce HTTPS**。建议先在 GitHub 账户中验证域名所有权，再发布 DNS。

操作依据：[GitHub Pages 自定义 workflow](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)、[自定义域名配置](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site)。

## 排查任务未启动

2026-10-23 检查时，最近一次 CI 和应用发布均在执行步骤前失败，GitHub 注释为账户付款失败或支出额度不足。仓库已公开；如果新任务仍出现同样注释，需要仓库所有者检查 GitHub **Billing & plans**，不能将这种状态当成测试失败。

历史记录：[CI](https://github.com/zfdang/video-auto-translate/actions/runs/39793306317)、[应用发布](https://github.com/zfdang/video-auto-translate/actions/runs/39793306292)。
