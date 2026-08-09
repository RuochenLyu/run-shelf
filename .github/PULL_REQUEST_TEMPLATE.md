## 变更说明

<!-- 做了什么、为什么。关联 issue 用 Fixes #123。 -->

## 检查清单

- [ ] `scripts/check.sh` 本地通过
- [ ] 提交信息符合 Conventional Commits 1.0.0
- [ ] 新增/移动 Swift 文件使用了 `bundle exec ruby scripts/sync_xcodeproj_files.rb`
- [ ] 改动 `schemas/*.json` 时已重新生成 `RunShelf/CLI/GeneratedSchemas.swift`
- [ ] 测试使用 `RUN_SHELF_APP_SUPPORT_DIR` 隔离目录，不触碰真实用户数据
