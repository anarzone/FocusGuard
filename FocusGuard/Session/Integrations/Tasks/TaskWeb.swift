import Foundation

/// The personal tokens for Todoist and Linear, in the Keychain: never in
/// the defaults.
enum TaskTokens {
    static let service = "com.anar.focusguard.tasks"

    static func keychain(for source: TaskSource) -> TokenStore {
        KeychainTokenStore(service: service, account: source.rawValue)
    }
}

/// Requests to Todoist and Linear.
enum TaskWeb {
    /// The body and status code; a failed connection can't be reached.
    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TaskSourceProblem.unreachable }
            return (data, http.statusCode)
        } catch let problem as TaskSourceProblem {
            throw problem
        } catch {
            throw TaskSourceProblem.unreachable
        }
    }

    /// The URL with its query, "+" escaped too so a cursor reads back the same.
    static func url(_ base: URL, path: String, query: [URLQueryItem] = []) -> URL {
        let plain = base.appending(path: path)
        guard !query.isEmpty, var components = URLComponents(url: plain, resolvingAgainstBaseURL: false) else { return plain }
        components.queryItems = query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? plain
    }
}

/// Dates as Todoist and Linear send them.
enum TaskDates {
    /// "2026-10-26" is that day here; "2026-10-26T15:00:00" that time here;
    /// "2026-10-26T15:00:00Z" (fractions of a second too) that time in UTC.
    static func parse(_ text: String?, calendar: Calendar = .current) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let halves = text.split(separator: "T", maxSplits: 1).map(String.init)
        let day = halves[0].split(separator: "-").compactMap { Int($0) }
        guard day.count == 3 else { return nil }
        var components = DateComponents(year: day[0], month: day[1], day: day[2])
        var local = calendar
        if halves.count == 2 {
            var time = halves[1]
            if time.hasSuffix("Z") {
                time.removeLast()
                local.timeZone = TimeZone(identifier: "UTC") ?? local.timeZone
            }
            let clock = (time.split(separator: ".").first ?? "").split(separator: ":").compactMap { Int($0) }
            guard clock.count >= 2 else { return nil }
            components.hour = clock[0]
            components.minute = clock[1]
            components.second = clock.count > 2 ? clock[2] : 0
        }
        return local.date(from: components)
    }
}
