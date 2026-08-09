import SwiftUI

struct TaskOriginBadge: View {
    var origin: TaskOrigin?

    var body: some View {
        if origin == .cli {
            Text("CLI")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .help("由命令行/AI agent 创建")
                .accessibilityLabel("由命令行或 AI agent 创建")
        }
    }
}
