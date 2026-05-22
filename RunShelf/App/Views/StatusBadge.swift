import SwiftUI

struct StatusBadge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

extension TaskRunStatus {
    var badgeColor: Color {
        switch self {
        case .pending: return .secondary
        case .running: return .blue
        case .success: return .green
        case .failed: return .red
        case .skipped: return .orange
        case .timeout: return .red
        case .cancelled: return .secondary
        case .stale: return .orange
        }
    }
}
