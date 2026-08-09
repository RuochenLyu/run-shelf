# 更新记录

## Unreleased

### Breaking changes

- 前台 `runshelf run --json` 在脚本失败、超时或取消时改为返回 `ok: false` 和 `error.code: "run_failed"`；退出码仍为 `8`，完整运行记录继续保留在 `result`。

## 1.0.0 - 2026-05-29

第一个可用版本。

- 完成原生 macOS 主 App。
- 支持文件化任务、内置模板、备注、脚本编辑和运行历史。
- 支持手动运行，记录 stdout/stderr、脚本快照、退出码、耗时和状态。
- 支持停止正在运行的任务；超时或取消时会清理整组子进程。
- 支持 5 段 cron、错过运行记录、保留清理和后台调度辅助进程。
- 支持失败通知和设置页里的后台状态检查。
- 支持 macOS 15+ 发布包，发布脚本可生成 DMG/zip，做 Developer ID 签名，并可选公证。
