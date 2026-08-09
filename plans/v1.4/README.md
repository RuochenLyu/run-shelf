# v1.4.0 任务书总览

本目录是 v1.4.0 的执行任务书，基于 2026-08-09 对 `main`（7ad2fbf）的四路审查：
最近三个性能提交的回归审查、核心运行/调度/claim 正确性审查、CLI 契约与 agent
可用性审查、开源就绪度审计。

v1.4.0 的主题：**修正确性，补 agent 桥，达到可公开状态**。不加大功能。

## 执行顺序与分工

| 任务书 | 主题 | 优先级 | 建议执行者 | 状态 |
|---|---|---:|---|---|
| [01](01-scheduler-runner-correctness.md) | 调度器与 Runner 正确性修复 | P0 | Codex | DONE |
| [02](02-ui-log-fixes.md) | 日志视图与线程池修复 | P0 | Codex | DONE |
| [03](03-cli-contract.md) | CLI 契约修复 | P1 | Codex | DONE |
| [04](04-agent-bridges.md) | Agent/CLI 发现性（产品桥） | P1 | Claude 设计 + Codex 实现 | DONE（2026-08-09 Claude 隔离目录端到端验收通过） |
| [05](05-open-source-prep.md) | 开源收尾 | P1 | 部分已完成，见文内清单 | 进行中 |
| [06](06-readme-media.md) | README 截图与演示 GIF | P1 | Codex（Computer Use） | TODO |

01 与 02 无依赖可并行；03 独立；04 依赖 03（错误契约稳定后再写 agent 文档命令）。

## 所有任务书共同约束（来自 AGENTS.md）

- 测试与手工验证必须设置 `RUN_SHELF_APP_SUPPORT_DIR` 指向临时目录，绝不触碰真实用户数据。
- 新增/移动 Swift 文件用 `bundle exec ruby scripts/sync_xcodeproj_files.rb`，不手改 pbxproj。
- 改动 `schemas/*.json` 后必须重新生成 `RunShelf/CLI/GeneratedSchemas.swift`（`scripts/generate_cli_schemas.rb`）。
- 交付前跑 `scripts/check.sh`。提交遵循 Conventional Commits。
- 不 tag、不 push、不发布。

## 验收基线

- `scripts/check.sh` 全绿（含全部既有测试）。
- 每个任务书内列出的新增回归测试全部存在且通过。
- 每个修复能对应一条"修复前可复现、修复后不可复现"的失败场景说明。
