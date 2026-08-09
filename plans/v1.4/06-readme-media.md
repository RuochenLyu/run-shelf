# 任务书 06：README 截图与演示 GIF

目标：为两份 README（README.md 中文、README.en.md 英文）补上视觉素材。这是 GUI
应用开源第一印象的最大缺口。

## 前置约束（务必遵守）

- **绝不使用真实用户数据**。启动 App 前设置 `RUN_SHELF_APP_SUPPORT_DIR` 指向
  mktemp 临时目录；截图里出现的所有任务都必须是本任务书定义的演示任务。
- 不启用真实后台调度（不注册 SMAppService）；演示只用手动运行。
- 素材提交到 `docs/assets/`，文件名固定（见下），保证 README 引用稳定。
- 图片语言用中文界面（App 本身即中文）；两份 README 引用同一组素材。
- 完成后清理临时数据目录与构建产物，仓库保持 clean（素材与 README 改动除外）。

## 演示数据准备

用 Debug 构建的 App（或 CLI apply）在隔离目录创建 3 个任务，让界面看起来真实：

1. 「网站健康检查」：`*/15 * * * *`，脚本用 `curl --fail https://example.com`，
   手动跑一次成功。
2. 「每日笔记备份」：`0 21 * * *`，脚本 `echo "backed up 42 files"`，手动跑一次成功。
3. 「磁盘空间检查」：`0 9 * * *`，脚本故意 `exit 1` 并向 stderr 输出
   `Home disk usage is 93%`，手动跑一次失败——让侧边栏出现一个失败标记，
   展示失败可见性（这是产品核心卖点，不要全绿）。

窗口尺寸统一 1280×800 左右，浅色外观，隐藏与产品无关的桌面内容。

## 交付物

| 文件 | 内容 |
|---|---|
| `docs/assets/main-window.png` | 主窗口三栏视图：选中「网站健康检查」，可见任务列表（含失败标记）、脚本编辑器、右侧 Inspector 的下次运行时间 |
| `docs/assets/run-history.png` | 选中「磁盘空间检查」的失败 run：运行历史 + stderr 日志可见 |
| `docs/assets/demo.mp4` | 源素材，≤30 秒：新建任务（选模板→命名→看 cron 预览）→ 立即运行 → 查看 stdout。用 Computer Use 操作真实 App，`screencapture -v` 或 ffmpeg 录制，1280px 宽，H.264 |
| `docs/assets/demo.gif` | 从 demo.mp4 转出（ffmpeg palettegen/paletteuse 两步法），≤10 MB，帧率 10-15fps，宽度 1000px 左右 |

先录 mp4 再转 GIF 的原因：GitHub README 只能内嵌自动播放仓库内的 GIF；仓库内的
mp4 只会渲染成链接，但保留它作为高清源——README 里 GIF 下方附"高清视频"链接，
后续也可手动上传到 GitHub 网页端换成内嵌播放器，或挂到 Release 页。

GIF 体积超限时降帧率/降宽度，不牺牲文字可读性；实在压不下就缩短演示流程重录，
先反馈再决定。

## README 接入

- README.md：在开头简介之后插入 `main-window.png`；「App 使用」一节插入
  `demo.gif`，下方加一行链接指向 `docs/assets/demo.mp4`（文案：高清视频）；
  「日志/失败排查」相关段落插入 `run-history.png`。
- README.en.md：同样位置引用同一组文件（链接文案：Full-quality video）。
- alt 文本写清内容（中文 README 用中文，英文用英文）。

## 完成后反馈

- 四个素材文件的最终尺寸（像素与字节）
- 截图/录制时使用的隔离目录路径（证明未触碰真实数据）
- README 两个文件的 diff 概要
- 无法自动完成的步骤（如系统权限弹窗）如实列出
