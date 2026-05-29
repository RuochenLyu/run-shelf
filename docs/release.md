# Run Shelf 发布流程

## 支持范围

```text
最低系统：macOS 15
推荐系统：macOS 26 或更高版本
发布形式：Developer ID 签名 zip，可选公证
架构：universal x86_64 + arm64
```

macOS 15 和 16 使用同一套核心功能，外观跟随系统可用的原生控件。macOS 26 专属 API 必须放在 `#available(macOS 26, *)` 分支里，并保留 macOS 15 可用的路径。

## 发布前检查

```bash
git status --short
rg --hidden --pcre2 -n "/Users/|gh[pousr]_[A-Za-z0-9_]+|Developer ID Application: [^(]+ \\([A-Z0-9]{10}\\)" \
  -g '!*.git/**' \
  -g '!.build/**'
```

这条搜索不应命中真实 token、本机绝对路径或硬编码的签名身份。

## 测试

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Debug \
  -derivedDataPath .build/TestDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

## 手动冒烟检查

```text
1. 首次打开能进入后台调度授权页。
2. 启用后台运行后能进入主窗口。
3. 从模板新建任务后，会写入 task.json、run.sh 和 notes.md。
4. 运行成功脚本后，会写入 stdout.log 和 success meta.json。
5. 运行失败脚本后，会写入 stderr.log 和 failed meta.json。
6. 停止 sleep 任务后，会写入 cancelled meta.json。
7. 设置定时任务后，关闭主窗口，后台辅助进程仍能继续运行。
8. 重新打开 App 后，能读到后台写入的历史记录。
```

## 打包

脚本需要本机有 Developer ID Application 证书：

```bash
RUN_SHELF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
scripts/package_release.sh 1.0.0
```

如需公证，额外提供 `notarytool` 的钥匙串配置：

```bash
RUN_SHELF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
RUN_SHELF_NOTARY_PROFILE="your-notary-profile" \
scripts/package_release.sh 1.0.0
```

产物位置：

```text
.build/release/RunShelf-1.0.0/RunShelf-1.0.0-macOS15.zip
.build/release/RunShelf-1.0.0/RunShelf-1.0.0-macOS15.zip.sha256
```

## 校验产物

```bash
codesign --verify --deep --strict --verbose=2 \
  ".build/ReleaseDerivedData/Build/Products/Release/Run Shelf.app"

vtool -show-build \
  ".build/ReleaseDerivedData/Build/Products/Release/Run Shelf.app/Contents/MacOS/Run Shelf"

unzip -l .build/release/RunShelf-1.0.0/RunShelf-1.0.0-macOS15.zip | \
  rg '(^|/)\\._|__MACOSX' && exit 1 || true
```

如果做了公证，再跑：

```bash
spctl --assess --type execute --verbose=2 \
  ".build/ReleaseDerivedData/Build/Products/Release/Run Shelf.app"
```

## GitHub Release

```bash
git tag v1.0.0
git push origin main v1.0.0
gh release create v1.0.0 \
  .build/release/RunShelf-1.0.0/RunShelf-1.0.0-macOS15.zip \
  .build/release/RunShelf-1.0.0/RunShelf-1.0.0-macOS15.zip.sha256 \
  --title "Run Shelf 1.0.0" \
  --notes-file CHANGELOG.md
```
