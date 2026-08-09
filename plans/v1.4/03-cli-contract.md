# 任务书 03：CLI 契约修复

范围：`RunShelf/CLI/RunShelfCLI.swift`、`schemas/*.json`（如有 envelope 变更需同步
`scripts/generate_cli_schemas.rb` + 重新生成 `GeneratedSchemas.swift`）、
`docs/agent-usage.md`、README CLI 节。

背景：CLI 的 agent 契约骨架是好的（`help agent`、`--json`、语义退出码），但存在几
处会让 agent 产生错误行为的契约漏洞。按 A→F 顺序，每项独立提交。

---

## A（P0）未知 flag / 多余参数被静默忽略

位置：`RunShelfCLI.swift` 全部子命令解析（`removeAll`/`takeValue` 风格，无 leftover
校验）。

实测：`runshelf apply spec.json --dryrun --json` → `ok:true, dryRun:false`，任务被真
实写入。agent 拼错 `--dry-run` 时预演变成落盘，这是对 agent 最危险的失败模式。
同理 `run t --detech` 变成前台阻塞。

修法：每个子命令消费完已知参数后统一校验剩余参数为空：
`guard arguments.isEmpty else { throw .usage("未知参数：\(arguments.joined(...))") }`。
顺带把 help/README 宣传但从未解析的 `--stdout`（:203 只认 `--stderr`）实现为显式
参数，避免"碰巧因默认值而工作"。

测试：`apply --dryrun` 报 usage 错误且不写盘；`run --detech` 报 usage；`log --stdout`
正常工作。

## B（P1）"任务正在运行"映射到两种错误码

位置：`RunShelfCLI.swift:18-21`（`TaskRunClaimError` 一律映射 `.conflict`）。

实测：`run <busy> --detach` → `conflict`/exit 5；`run <busy>`（前台）→
`already_running`/exit 7。违反 `help agent` 自己声明的退出码契约，agent 的重试逻辑
无法统一。

修法：claim 错误里表示"已有活动运行"的 case 映射 `.running`（already_running/7），
其余 claim 错误保持 conflict。

## C（P1）前台 run 失败时 `ok:true` + exit 8 语义脱钩

位置：`RunShelfCLI.swift:261-267`。

现状：脚本失败时 envelope `ok:true`（result 内 status=failed），exit 8，`runFailed`
message 从未输出。只看 `ok` 字段的 agent 会误判成功。

修法（择一，倾向 1）：
1. 脚本失败时输出 `ok:false, error.code="run_failed"`，`result` 仍携带完整 run 记录
   （exitCode、日志路径），exit 8 不变；`help agent` 与 schema 注明。
2. 保持 `ok:true`，但在 `help agent`、docs/agent-usage.md、schema description 里明确
   写死："run 的成败以 exit code 与 result.run.status 为准，ok 只表示命令本身执行成
   功"。
选 1 时注意向后兼容说明写入 CHANGELOG。

## D（P1）CAS 契约与文档矛盾

位置：`RunShelfCLI.swift:164`、`TaskRepository.swift:415`；docs/agent-usage.md 第 5 条。

现状：更新已有任务时省略 `--expected-revision` 会用本命令内刚读的 revision 做 CAS
——等于没有 CAS，agent 上次 `task show` 之后的并发修改被静默覆盖。文档却说"必须
带回"。

修法：`apply` 更新已有任务且未带 `--expected-revision` 时报 usage 错误，message 指
引"先 task show 获取 revisionToken"。创建新任务不受影响。这会收紧契约，属破坏性
变更，CHANGELOG 注明。

## E（P2）零散契约问题

- `TaskRepository.swift:505-507`：`timeoutSeconds < 0` 抛 conflict/5，应为 validation/4。
- `RunShelfCLI.swift:689`：`(try? encode) ?? Data()` 编码失败输出空行 + exit 0，破坏
  "stdout 必为合法 envelope"。改为向 stderr 写诊断并 exit unexpected。
- `RunShelfCLI.swift:504-533`：`cancelRun` 补 `isSafeRunID` 校验（与 `findRun:484` 一致）。
- slug 恰为 `status/log/cancel/stop` 的任务无法用 slug 运行（:191 switch 先吃掉）：
  在 slug 生成侧把这几个词加入保留字（apply 时报 validation），并在 help 里注明。
- `doctor` 有 loadIssues 时 exit 1 与"未知错误"混用：分配专用退出码或在 help 注明。
- cancel 已结束 run 的 not_found message 补一句"用 run status 查看最终状态"。

## F（P2）契约自描述补强

- envelope 增加 `schemaVersion` 字段；新增 `runshelf version` 子命令（输出 app 版本 +
  envelope schemaVersion）。schema 同步更新 + 重新生成。
- 顶层 help 前两行加导引："AI agent：先运行 `runshelf help agent`；机器可读输出加
  `--json`"。
- help 文本补齐缺失命令：`task delete`、`schema cli-result`、`run stop` 别名、
  `run log` 的 `--bytes/--full/--json`、`RUNSHELF_JSON` 环境变量。
- `runshelf schema task-spec --example` 输出一个最小可用 spec（agent 免拼文档）。

## 验收

- `scripts/check.sh` 全绿；新增 CLI 端到端测试覆盖 A/B/C/D 的每个分支。
- `RUN_SHELF_APP_SUPPORT_DIR` 隔离目录下手工走一遍 `help agent` 声明的完整流程：
  create → dry-run → apply → run → status → log → cancel → delete，确认退出码与
  envelope 与文档逐条一致。
- docs/agent-usage.md 与实现零矛盾（逐条核对）。
