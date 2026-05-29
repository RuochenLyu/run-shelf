# 参与开发

Run Shelf 是一个小型原生 macOS 项目。改动应当坚持本机保存、文件格式清楚、运行状态可排查。

## 开发环境

先安装生成 Xcode 工程需要的依赖：

```bash
gem install xcodeproj
ruby scripts/generate_xcodeproj.rb
```

提交改动前至少跑一遍测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Debug \
  -derivedDataPath .build/TestDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

## 约定

- 任务数据必须保持可读，不能变成只能由 App 理解的黑盒。
- 修改 `schemaVersion` 时必须同时给出迁移方案。
- 后台调度的行为要能通过文件、日志和心跳记录排查。
- 不要在没有产品决策和文档说明的情况下加入遥测、账号系统或网络同步。
- 只在 `#available(macOS 26, *)` 分支里使用 macOS 26 专属 API，并保留 macOS 15 可用的路径。
