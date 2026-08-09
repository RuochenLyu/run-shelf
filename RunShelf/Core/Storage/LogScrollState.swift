import Combine
import Foundation

@MainActor
final class LogScrollStore: ObservableObject {
    private var state = LogScrollState()

    var origins: [String: CGPoint] { state.origins }

    func record(origin: CGPoint, for key: String) {
        state.record(origin: origin, for: key)
    }

    func beginRestore(for key: String) -> CGPoint {
        state.beginRestore(for: key)
    }

    func completeRestore(for key: String) {
        state.completeRestore(for: key)
    }
}

struct LogScrollState {
    private let limit: Int
    private(set) var origins: [String: CGPoint] = [:]
    private var order: [String] = []
    private var pendingRestoreKey: String?

    init(limit: Int = 50) {
        self.limit = max(limit, 1)
    }

    mutating func record(origin: CGPoint, for key: String) {
        guard pendingRestoreKey != key else { return }
        origins[key] = origin
        touch(key)
    }

    mutating func beginRestore(for key: String) -> CGPoint {
        pendingRestoreKey = key
        if origins[key] != nil {
            touch(key)
        }
        return origins[key] ?? CGPoint(x: 0, y: 0)
    }

    mutating func completeRestore(for key: String) {
        guard pendingRestoreKey == key else { return }
        pendingRestoreKey = nil
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            origins.removeValue(forKey: order.removeFirst())
        }
    }
}
