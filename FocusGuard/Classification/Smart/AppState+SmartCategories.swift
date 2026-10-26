import Foundation

extension AppState {
    /// Pro smart categories, made on first use and kept while the app runs.
    var smartCategories: SmartCategories {
        if let made = SmartCategoriesHost.made { return made }
        let made = SmartCategories(container: container, classifier: classifier,
                                   optedOut: { [weak self] in self?.optOutCache.bundleIdentifiers ?? [] },
                                   isInSession: { [weak self] in self?.sessionManager.currentSession != nil },
                                   isStrictLocked: { [weak self] in self?.isStrictLocked ?? false })
        SmartCategoriesHost.made = made
        return made
    }
}

@MainActor
private enum SmartCategoriesHost {
    static var made: SmartCategories?
}
