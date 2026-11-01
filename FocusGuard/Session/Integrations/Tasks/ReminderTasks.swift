import Foundation

/// Open reminders in the chosen lists, as tasks. EventKit itself is behind
/// `ReminderStore`; without access there are none.
final class ReminderTasks: TaskStore {
    let source = TaskSource.reminders
    private let store: ReminderStore
    private let defaults: UserDefaults

    init(store: ReminderStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    func openTasks() async throws -> [TaskItem] {
        await store.incomplete(listIDs: IntegrationSettings.ids(IntegrationSettings.reminderLists, defaults)) ?? []
    }

    func setCompleted(_ task: TaskItem, _ completed: Bool) async -> Bool {
        await store.setCompleted(task.id, completed)
    }
}
