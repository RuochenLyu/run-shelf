import Foundation

struct TaskTemplate: Identifiable, Equatable {
    var id: String
    var name: String
    var description: String
    var defaultSchedule: TaskSchedule
    var script: String
    var notes: String
    var enabledByDefault: Bool
}

extension TaskTemplate {
    static let blank = TaskTemplate(
        id: "blank",
        name: "空白脚本",
        description: "从一个最小 run.sh 开始。",
        defaultSchedule: .defaultDaily,
        script: """
        #!/bin/zsh
        set -euo pipefail

        # Write your script here
        """,
        notes: "",
        enabledByDefault: true
    )

    static let projectScript = TaskTemplate(
        id: "project-script",
        name: "项目脚本",
        description: "进入项目目录后执行已有脚本。",
        defaultSchedule: .defaultDaily,
        script: """
        #!/bin/zsh
        set -euo pipefail

        cd "$HOME/Projects/my-project"

        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

        # source .venv/bin/activate

        exec ./run.sh
        """,
        notes: "",
        enabledByDefault: true
    )

    static let curlRequest = TaskTemplate(
        id: "curl-request",
        name: "curl 请求",
        description: "定时请求一个 URL，失败时记录错误。",
        defaultSchedule: TaskSchedule(type: "cron", expression: "*/15 * * * *", timezone: "local"),
        script: """
        #!/bin/zsh
        set -euo pipefail

        curl --fail --silent --show-error \\
          --connect-timeout 10 \\
          --max-time 30 \\
          "https://example.com/health"
        """,
        notes: "",
        enabledByDefault: true
    )

    static let gitSync = TaskTemplate(
        id: "git-sync",
        name: "Git 同步",
        description: "定时拉取、提交并推送一个本地仓库。",
        defaultSchedule: TaskSchedule(type: "cron", expression: "0 8,12,18 * * *", timezone: "local"),
        script: """
        #!/bin/zsh
        set -euo pipefail

        cd "$HOME/Projects/notes"

        git pull --rebase
        git add -A
        git commit -m "auto sync: $(date '+%Y-%m-%d %H:%M:%S')" || true
        git push
        """,
        notes: "",
        enabledByDefault: true
    )

    static let nodeScript = TaskTemplate(
        id: "node-script",
        name: "Node 脚本",
        description: "进入 Node 项目并运行脚本。",
        defaultSchedule: .defaultDaily,
        script: """
        #!/bin/zsh
        set -euo pipefail

        cd "$HOME/Projects/my-node-project"
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

        exec node scripts/main.mjs
        """,
        notes: "",
        enabledByDefault: true
    )

    static let pythonScript = TaskTemplate(
        id: "python-script",
        name: "Python 脚本",
        description: "进入 Python 项目、激活环境并运行模块。",
        defaultSchedule: .defaultDaily,
        script: """
        #!/bin/zsh
        set -euo pipefail

        cd "$HOME/Projects/my-python-project"
        source .venv/bin/activate

        exec python -m main
        """,
        notes: "",
        enabledByDefault: true
    )

    static let rsyncBackup = TaskTemplate(
        id: "rsync-backup",
        name: "rsync 备份",
        description: "用 rsync 同步本地目录到备份盘。",
        defaultSchedule: TaskSchedule(type: "cron", expression: "0 20 * * *", timezone: "local"),
        script: """
        #!/bin/zsh
        set -euo pipefail

        rsync -av --delete \\
          "$HOME/Documents/" \\
          "/Volumes/Backup/Documents/"
        """,
        notes: "",
        enabledByDefault: true
    )

    static let exampleHealthCheck = TaskTemplate(
        id: "example-health-check",
        name: "网站健康检查（示例）",
        description: "每 15 分钟请求一次示例健康检查地址；示例默认停用，可删除。",
        defaultSchedule: TaskSchedule(type: "cron", expression: "*/15 * * * *", timezone: "local"),
        script: curlRequest.script,
        notes: "这是一个默认停用的示例任务，可以直接删除。",
        enabledByDefault: false
    )

    static let exampleDiskUsage = TaskTemplate(
        id: "example-disk-usage",
        name: "磁盘空间检查（示例）",
        description: "检查 Home 目录所在磁盘使用率；示例默认停用，可删除。",
        defaultSchedule: TaskSchedule(type: "cron", expression: "0 9 * * *", timezone: "local"),
        script: """
        #!/bin/zsh
        set -euo pipefail

        usage="$(df -H "$HOME" | awk 'NR==2 { gsub("%", "", $5); print $5 }')"

        if [ "$usage" -ge 90 ]; then
          echo "Home disk usage is ${usage}%" >&2
          exit 1
        fi

        echo "Home disk usage is ${usage}%"
        """,
        notes: "这是一个默认停用的示例任务，可以直接删除。",
        enabledByDefault: false
    )

    static let builtIns: [TaskTemplate] = [
        .blank,
        .projectScript,
        .curlRequest,
        .gitSync,
        .nodeScript,
        .pythonScript,
        .rsyncBackup
    ]

    static let examples: [TaskTemplate] = [
        .exampleHealthCheck,
        .exampleDiskUsage
    ]
}
