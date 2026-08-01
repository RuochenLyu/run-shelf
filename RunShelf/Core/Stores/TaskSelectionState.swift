import Foundation

@MainActor
final class TaskSelectionState: ObservableObject {
    @Published var selectedTaskID: String? {
        didSet {
            if oldValue != selectedTaskID, selectedRunID != nil {
                selectedRunID = nil
            }
        }
    }
    @Published var selectedRunID: String?

    init(selectedTaskID: String? = nil, selectedRunID: String? = nil) {
        self.selectedTaskID = selectedTaskID
        self.selectedRunID = selectedRunID
    }
}
