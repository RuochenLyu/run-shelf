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

    func testReconcileKeepsMissingIDsAndAppendsNewIDs() {
        let store = makeStore()
        store.reconcile(taskIDs: ["a", "b"])
        // 任务还没加载、或预览进程看的是另一份数据目录：列表不完整不能裁剪顺序。
        store.reconcile(taskIDs: [])
        store.reconcile(taskIDs: ["b", "c", "c"])

        XCTAssertEqual(store.manualOrder, ["a", "b", "c"])
        XCTAssertEqual(makeStore().manualOrder, ["a", "b", "c"])
    }

    func testForgetRemovesDeletedID() {
        let store = makeStore()
        store.reconcile(taskIDs: ["a", "b", "c"])
        store.forget(taskID: "b")

        XCTAssertEqual(store.manualOrder, ["a", "c"])
    }

    func testMoveKeepsIDsThatAreNotVisible() {
        let store = makeStore()
        store.reconcile(taskIDs: ["a", "hidden", "b", "c"])

        // "hidden" 此刻不在列表里（例如 task.json 暂时读不出来）。
        store.move(taskIDs: ["a", "b", "c"], fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(store.manualOrder, ["c", "hidden", "a", "b"])
        XCTAssertEqual(
            store.orderedTasks([task(id: "a"), task(id: "b"), task(id: "c")]).map(\.id),
            ["c", "a", "b"]
        )
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
