# 参与开发

Run Shelf 是一个小型原生 macOS 项目。改动应当坚持本机保存、文件格式清楚、运行状态可排查。

## 开发环境

先安装 Xcode 工程工具依赖，并增量同步源码引用：

```bash
bundle install
bundle exec ruby scripts/sync_xcodeproj_files.rb
```

完整重建 `RunShelf.xcodeproj` 仅用于工程损坏等恢复场景；日常新增、删除或移动 Swift 文件不要运行全量生成器。

提交改动前运行统一检查入口：

```bash
scripts/check.sh
```

## 约定

- 任务数据必须保持可读，不能变成只能由 App 理解的黑盒。
- 修改 `schemaVersion` 时必须同时给出迁移方案。
- 后台调度的行为要能通过文件、日志和心跳记录排查。
- 不要在没有产品决策和文档说明的情况下加入遥测、账号系统或网络同步。
- 只在 `#available(macOS 26, *)` 分支里使用 macOS 26 专属 API，并保留 macOS 15 可用的路径。
