import Foundation
import XCTest

@MainActor
final class TaskListPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TaskListPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testManualOrderReconcilesMovesAndPersists() {
        let store = makeStore()
        store.reconcile(taskIDs: ["b", "a", "c"])

        XCTAssertEqual(store.manualOrder, ["b", "a", "c"])
        XCTAssertEqual(
            store.orderedTasks([task(id: "a"), task(id: "b"), task(id: "c")]).map(\.id),
            ["b", "a", "c"]
        )

        store.move(taskIDs: store.manualOrder, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(store.manualOrder, ["a", "c", "b"])

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.manualOrder, ["a", "c", "b"])
    }

    func testNextRunSortPlacesDisabledTasksLastAndUsesManualOrderForTies() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 29,
            hour: 8,
            minute: 0
        )))
        let store = makeStore()
        store.reconcile(taskIDs: ["late", "tie", "early", "disabled"])
        store.setSortMode(.nextRun)

        let tasks = [
            task(id: "late", expression: "0 10 * * *"),
            task(id: "tie", expression: "30 8 * * *"),
            task(id: "early", expression: "30 8 * * *"),
            task(id: "disabled", expression: "5 8 * * *", enabled: false)
        ]

        XCTAssertEqual(
            store.orderedTasks(tasks, now: now).map(\.id),
            ["tie", "early", "late", "disabled"]
        )
    }

    func testReconcileRemovesDeletedIDsAndAppendsNewIDs() {
        let store = makeStore()
        store.reconcile(taskIDs: ["a", "b"])
        store.reconcile(taskIDs: ["b", "c"])

        XCTAssertEqual(store.manualOrder, ["b", "c"])
    }

    private func makeStore() -> TaskListPreferencesStore {
        TaskListPreferencesStore(
            defaults: defaults,
            sortModeKey: "sortMode",
            manualOrderKey: "manualOrder"
        )
    }

    private func task(
        id: String,
        expression: String = "0 9 * * *",
        enabled: Bool = true
    ) -> RunShelfTask {
        RunShelfTask(
            manifest: .create(
                id: id,
                name: id,
                description: "",
                enabled: enabled,
                schedule: TaskSchedule(type: "cron", expression: expression, timezone: "local")
            ),
            directoryURL: URL(fileURLWithPath: "/tmp/\(id)"),
            script: "",
            notes: "",
            runs: [],
            isDirty: false
        )
    }
}
