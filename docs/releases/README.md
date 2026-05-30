# 发布说明

每个正式版本的 GitHub Release 文案放在这里，文件名固定为：

```text
docs/releases/vX.Y.Z.md
```

标准发布命令会默认读取对应文件：

```bash
scripts/release.sh 1.1.2
```

只有临时重发或特殊测试时才使用 `--notes-file` 指向别的文件。
