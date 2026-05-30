# Run Shelf 发布流程

## 支持范围

```text
最低系统：macOS 15
推荐系统：macOS 26 或更高版本
发布形式：Developer ID 签名并公证的 DMG + zip
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

## 本机发布配置

正式发布不手敲签名身份和 notarytool profile。把仓库里的示例复制成本机配置：

```bash
cp .release.env.example .release.env
```

`.release.env` 不进 git，只保存本机发布参数：

```bash
RUN_SHELF_SIGN_IDENTITY="Developer ID Application: Ruochen Lyu (B4BJ3QY8T2)"
RUN_SHELF_NOTARY_PROFILE="silent-switch-notary"
```

如果换电脑，先在钥匙串里保存 notarytool 凭据。profile 名称要和 `.release.env` 一致：

```bash
xcrun notarytool store-credentials "silent-switch-notary" \
  --apple-id "APPLE_ID" \
  --team-id "B4BJ3QY8T2"
```

正式发布必须公证。只做本地签名包时才显式跳过：

```bash
RUN_SHELF_SKIP_NOTARY=1 scripts/package_release.sh 1.0.0
```

## 标准发布

先提交代码，然后准备 release notes 文件，路径固定为：

```text
docs/releases/v1.1.2.md
```

示例：

```bash
cat > docs/releases/v1.1.2.md <<'EOF'
修复……

校验：
- xcodebuild test 通过
- App 与 DMG 均已 Developer ID 签名、公证并 staple
EOF
```

一条命令完成测试、构建、签名、公证、staple、校验、tag、push 和 GitHub Release：

```bash
scripts/release.sh 1.1.2
```

脚本默认读取 `docs/releases/v1.1.2.md`。它会拒绝脏工作区、重复 tag、重复 release。成功后会上传四个资产：

```text
.build/release/RunShelf-1.1.2/RunShelf-1.1.2-macOS15.dmg
.build/release/RunShelf-1.1.2/RunShelf-1.1.2-macOS15.dmg.sha256
.build/release/RunShelf-1.1.2/RunShelf-1.1.2-macOS15.zip
.build/release/RunShelf-1.1.2/RunShelf-1.1.2-macOS15.zip.sha256
```

## 只打包不发布

需要只生成产物、不创建 tag 和 GitHub Release 时，直接运行：

```bash
scripts/package_release.sh 1.1.2
```

脚本会跑测试，构建 Release，分别签名内嵌的 `RunShelfScheduler` 和 `runshelf` helper，再签名主 App，提交 Apple 公证并 staple App 和 DMG。

产物位置：

```text
.build/release/RunShelf-1.1.2/RunShelf-1.1.2-macOS15.dmg
.build/release/RunShelf-1.1.2/RunShelf-1.1.2-macOS15.dmg.sha256
.build/release/RunShelf-1.1.2/RunShelf-1.1.2-macOS15.zip
.build/release/RunShelf-1.1.2/RunShelf-1.1.2-macOS15.zip.sha256
```

## 校验产物

```bash
codesign --verify --deep --strict --verbose=2 \
  ".build/ReleaseDerivedData/Build/Products/Release/Run Shelf.app"

vtool -show-build \
  ".build/ReleaseDerivedData/Build/Products/Release/Run Shelf.app/Contents/MacOS/Run Shelf"

unzip -l .build/release/RunShelf-1.1.2/RunShelf-1.1.2-macOS15.zip | \
  rg '(^|/)\._|__MACOSX' && exit 1 || true

spctl --assess --type execute --verbose=2 \
  ".build/ReleaseDerivedData/Build/Products/Release/Run Shelf.app"

spctl --assess --type open --context context:primary-signature --verbose=2 \
  .build/release/RunShelf-1.1.2/RunShelf-1.1.2-macOS15.dmg
```
