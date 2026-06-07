# Contributing

Thanks for helping improve Video Downloader.

This project is still moving quickly, so contributions should stay practical: keep the macOS app simple to use, keep hard-site behavior observable, and avoid changes that make downloads appear successful before the final file is validated.

## Development Workflow

```bash
brew install ffmpeg
make install-deps
make test
make run
```

Use `make test-live` only when you need real website coverage. Live sites are volatile and may fail because of network, region, account, anti-bot, or CDN behavior.

GitHub Actions runs the deterministic gate on pushes and pull requests: dependency install, Python compilation, `make test`, and `make build`.

Use `make package` before preparing a release. It creates `dist/VideoDownloader-<version>-macos-arm64.zip` and a matching SHA-256 checksum file.

Successful CI runs upload the generated package and checksum as an Actions artifact for short-lived testing.

## Reporting Issues

Use the GitHub issue forms instead of blank issues.

- For a specific website or media URL, choose **Site download failure / 网站下载失败** and paste the support report copied from the app's Diagnostics sheet.
- For app behavior that is not site-specific, choose **App bug / 应用 Bug**.
- For product ideas, choose **Feature request / 功能建议**.

Do not include private cookies, account tokens, paid media, or credentials in an issue.

## Commit Message Rule

All commits should use bilingual English/Chinese messages.

Recommended format:

```text
English summary / 中文摘要
```

Examples:

```text
Polish GitHub documentation / 打磨 GitHub 文档
Improve task center recovery / 改进任务中心恢复能力
Fix HLS output validation / 修复 HLS 输出校验
```

For multi-line commit messages, keep the first line bilingual and use the body for extra detail:

```text
Improve live site diagnostics / 改进真实站点诊断

- Add clearer protected-site guidance.
- Record probe status in the live test matrix.
```

## Pull Request Checklist

- Run `make test` for code changes.
- Update `README.md` and `README.zh-CN.md` together when user-facing behavior changes.
- Update `docs/ARCHITECTURE.md` when detection, download, queue, or validation internals change.
- Update `docs/AGILE_LOG.md` for shipped product work and verification notes.
- Do not commit `build/`, `venv/`, cookies, downloaded videos, `.DS_Store`, or local reports.

# 贡献指南

感谢你一起改进 Video Downloader。

这个项目还在快速迭代，提交时请优先保持应用简单、可恢复、可诊断。尤其不要让“下载完成”的状态早于最终文件可播放性校验。

## 开发流程

```bash
brew install ffmpeg
make install-deps
make test
make run
```

只有在需要真实网站覆盖时再运行 `make test-live`。真实站点会受网络、地区、账号、反爬、CDN 策略影响，失败不一定代表本地代码回归。

GitHub Actions 会在推送和 Pull Request 时运行确定性门禁：安装依赖、Python 编译、`make test` 和 `make build`。

准备发布前运行 `make package`。它会生成 `dist/VideoDownloader-<version>-macos-arm64.zip` 和对应的 SHA-256 校验文件。

CI 成功后会把生成的包和校验文件上传为 Actions artifact，方便短期测试。

## 反馈问题

请使用 GitHub issue 表单，不要提交空白 issue。

- 针对具体网站或媒体链接，选择 **Site download failure / 网站下载失败**，并粘贴应用诊断页复制的支持报告。
- 针对不局限于某个网站的应用行为，选择 **App bug / 应用 Bug**。
- 针对产品想法，选择 **Feature request / 功能建议**。

不要在 issue 中包含私人 Cookie、账号 token、付费媒体或凭据。

## 提交信息规则

所有提交信息都使用中英文双语。

推荐格式：

```text
English summary / 中文摘要
```

示例：

```text
Polish GitHub documentation / 打磨 GitHub 文档
Improve task center recovery / 改进任务中心恢复能力
Fix HLS output validation / 修复 HLS 输出校验
```

如果提交信息需要多行，第一行保持双语，正文再补充细节。

## 提交前检查

- 代码改动运行 `make test`。
- 用户可见行为变化时，同时更新 `README.md` 和 `README.zh-CN.md`。
- 侦测、下载、队列、校验等内部机制变化时，更新 `docs/ARCHITECTURE.md`。
- 产品功能和验证结果写入 `docs/AGILE_LOG.md`。
- 不提交 `build/`、`venv/`、Cookie、下载视频、`.DS_Store` 或本地报告。
