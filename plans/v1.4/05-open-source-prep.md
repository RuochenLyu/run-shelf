# 任务书 05：开源收尾

背景：2026-08-09 开源就绪度审计结论——文档链条、CI、.gitignore、git 历史整体干
净，无密钥/token 泄漏；`.release.env` 从未进 git。剩余项如下。

## 已完成（2026-08-09，Claude）

- [x] `.release.env.example` 与 `docs/release.md` 中的真实签名身份、Team ID、notary
      profile 名替换为占位符（历史中的 Team ID 属半公开信息——它本就嵌在每个已分
      发的签名二进制里——不重写历史）。注意：本机 `.release.env` 未跟踪、未改动。
- [x] CHANGELOG.md 补齐 1.1.0–1.3.0（此前停在 1.0.0），并指向 docs/releases/。
- [x] plans/README.md 顶部加"历史设计存档"说明，消除内部作业指令的困惑。
- [x] `.github/ISSUE_TEMPLATE/`（bug_report、feature_request）与 PR 模板。
- [x] README 顶部加 CI 徽章 + MIT 许可证徽章。
- [x] CONTRIBUTING 说明 Ruby 仅用于工程文件生成。
- [x] `docs/requirements.md` 与 `docs/roadmap.md` 顶部加存档说明。

## 待做

### 必须（公开前）

- [ ] **README 截图/GIF**：已拆为独立任务书 [06-readme-media.md](06-readme-media.md)，
      由 Codex 用 Computer Use 执行。
- [x] **plans/ 三个 IN PROGRESS 状态行更新**（2026-08-09 对照代码核实：009/010 为
      DONE，007 未开始改为 DEFERRED）。

### 建议（可与公开同步进行）

- [x] **英文 README**：新增 `README.en.md`，与中文主 README 顶部互链（主 README
      保持中文，符合"简体中文优先"的产品定位）。docs/ 内部文档暂不翻译。
      注意：任务书 03/04 落地后，两份 README 的 CLI 节要同步更新。

### 发版前小项（04 验收时发现，不阻塞）

- [ ] `agent-setup` 输出的 CLI 路径取自运行时自身位置；从开发构建执行
      `--write claude` 会把临时构建路径写进用户文件。改进：优先使用已安装的稳定
      路径（`~/.local/bin/runshelf` 或 App bundle 内 Helpers 路径），都不存在时才
      回退到自身路径。
- [ ] 发布打包后核对 `runshelf version --json` 的 `appVersion` 与发布版本一致
      （版本注入逻辑已在 package_release.sh，属确认项）。

### 可选（公开后）

- [ ] SECURITY.md：写清"什么算安全问题、往哪报"——对一个执行任意 shell 脚本的工
      具是加分项。
- [ ] Homebrew 自有 tap（`brew install --cask <owner>/tap/run-shelf`）；产物已满足
      cask 全部技术要求（签名+公证+staple DMG+sha256+GitHub Releases）。官方
      homebrew/cask 有知名度门槛，起量后再提交。

### 时机

以上"必须"完成 + 任务书 01/02 的 P0 修复合入并发布 v1.4.0 后再公开仓库——不要
带着已知的调度器永久跳过 bug（已在 v1.3.0 线上版本中）开源首发。

### 备忘

- AGENTS.md 审计结论：适合公开，无需修改。
- git 作者邮箱与 GitHub 账号的关联会随开源公开，属预期。
