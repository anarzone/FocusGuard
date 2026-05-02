import Foundation
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// Exports sessions + activity events to JSON or CSV. Triggered from the
/// main window toolbar (Reports tab → Export… button).
enum DataExporter {
    enum Format {
        case json
        case csv
    }

    @MainActor
    static func export(_ format: Format, container: ModelContainer) {
        let panel = NSSavePanel()
        panel.title = "Export FocusGuard data"
        panel.nameFieldStringValue = defaultFilename(for: format)
        panel.allowedContentTypes = [format == .json ? .json : .commaSeparatedText]
        panel.canCreateDirectories = true

        // beginSheetModal — non-blocking; the active key window hosts the sheet.
        // If no key window (popover-only state), fall back to a free-floating
        // panel via begin().
        let host = NSApp.keyWindow ?? NSApp.mainWindow
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                writeExport(format: format, container: container, url: url)
            }
        }

        if let host {
            panel.beginSheetModal(for: host, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    @MainActor
    private static func writeExport(format: Format, container: ModelContainer, url: URL) {
        let context = container.mainContext
        do {
            switch format {
            case .json:
                let data = try buildJSON(context: context)
                try data.write(to: url, options: .atomic)
            case .csv:
                let csv = try buildCSV(context: context)
                try csv.data(using: .utf8)?.write(to: url, options: .atomic)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // MARK: - Filenames

    private static func defaultFilename(for format: Format) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: .now)
        let ext = format == .json ? "json" : "csv"
        return "focusguard-\(date).\(ext)"
    }

    // MARK: - JSON

    private struct ExportRoot: Codable {
        let exportedAt: Date
        let appVersion: String
        let sessions: [SessionDTO]
        let events: [EventDTO]
    }
    private struct SessionDTO: Codable {
        let id: String
        let startedAt: Date
        let endedAt: Date?
        let label: String?
        let status: String
        let plannedDurationMinutes: Int?
        let pausedSeconds: Double
    }
    private struct EventDTO: Codable {
        let id: String
        let startedAt: Date
        let endedAt: Date
        let bundleIdentifier: String
        let appName: String
        let windowTitle: String?
        let url: String?
        let classification: String?
        let sessionId: String?
    }

    @MainActor
    private static func buildJSON(context: ModelContext) throws -> Data {
        let sessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let events   = (try? context.fetch(FetchDescriptor<ActivityEvent>())) ?? []

        let sessionDTOs = sessions.map { s in
            SessionDTO(
                id: s.id.uuidString,
                startedAt: s.startedAt,
                endedAt: s.endedAt,
                label: s.label,
                status: statusName(s.status),
                plannedDurationMinutes: s.plannedDurationMinutes,
                pausedSeconds: s.pausedSeconds
            )
        }
        let eventDTOs = events.map { e in
            EventDTO(
                id: e.id.uuidString,
                startedAt: e.startedAt,
                endedAt: e.endedAt,
                bundleIdentifier: e.bundleIdentifier,
                appName: e.appName,
                windowTitle: e.windowTitle,
                url: e.url,
                classification: e.classification.map(classificationName),
                sessionId: e.session?.id.uuidString
            )
        }

        let root = ExportRoot(
            exportedAt: .now,
            appVersion: "0.1.0",
            sessions: sessionDTOs,
            events: eventDTOs
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(root)
    }

    // MARK: - CSV

    @MainActor
    private static func buildCSV(context: ModelContext) throws -> String {
        let events = (try? context.fetch(FetchDescriptor<ActivityEvent>())) ?? []

        var out = "started_at,ended_at,duration_seconds,bundle_id,app_name,classification,window_title,url,session_id\n"
        let iso = ISO8601DateFormatter()
        for e in events {
            let dur = Int(e.endedAt.timeIntervalSince(e.startedAt))
            let row = [
                iso.string(from: e.startedAt),
                iso.string(from: e.endedAt),
                "\(dur)",
                csvEscape(e.bundleIdentifier),
                csvEscape(e.appName),
                csvEscape(e.classification.map(classificationName) ?? ""),
                csvEscape(e.windowTitle ?? ""),
                csvEscape(e.url ?? ""),
                e.session?.id.uuidString ?? ""
            ].joined(separator: ",")
            out.append(row)
            out.append("\n")
        }
        return out
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    // MARK: - Enum names

    private static func classificationName(_ c: Classification) -> String {
        switch c {
        case .focus:       return "focus"
        case .neutral:     return "neutral"
        case .distraction: return "distraction"
        }
    }
    private static func statusName(_ s: SessionStatus) -> String {
        switch s {
        case .active:    return "active"
        case .completed: return "completed"
        case .abandoned: return "abandoned"
        }
    }
}
