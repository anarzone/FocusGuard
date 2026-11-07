import Foundation

/// Open reminders in the chosen lists, as tasks. Only lists the user picked
/// are read: Reminders holds personal things too, and none of it should turn
/// up as a work goal unasked. EventKit itself is behind `ReminderStore`;
/// without access there are none.
final class ReminderTasks: TaskStore {
    let source = TaskSource.reminders
    private let store: ReminderStore
    private let defaults: UserDefaults

    init(store: ReminderStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    func openTasks() async throws -> [TaskItem] {
        let lists = IntegrationSettings.ids(IntegrationSettings.reminderLists, defaults)
        guard !lists.isEmpty else { return [] }
        return await store.incomplete(listIDs: lists) ?? []
    }

    func setCompleted(_ task: TaskItem, _ completed: Bool) async -> Bool {
        await store.setCompleted(task.id, completed)
    }
}
