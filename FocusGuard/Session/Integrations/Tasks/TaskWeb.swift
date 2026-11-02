import Foundation

/// The personal tokens for Todoist, Linear, GitHub and Jira, in the Keychain:
/// never in the defaults.
enum TaskTokens {
    static let service = "com.anar.focusguard.tasks"

    static func keychain(for source: TaskSource) -> TokenStore {
        KeychainTokenStore(service: service, account: source.rawValue)
    }
}

/// Requests to Todoist, Linear, GitHub and Jira.
enum TaskWeb {
    /// The body and status code; a failed connection can't be reached.
    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, Int) {
        let (data, response) = try await exchange(request, session: session)
        return (data, response.statusCode)
    }

    /// The body and the whole response. With `staysOn`, a redirect anywhere
    /// else isn't followed, so credentials don't go with it.
    static func exchange(_ request: URLRequest, session: URLSession,
                         staysOn: (@Sendable (URL) -> Bool)? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request, delegate: staysOn.map(RedirectGuard.init))
            guard let http = response as? HTTPURLResponse else { throw TaskSourceProblem.unreachable }
            return (data, http)
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

/// Follows a redirect only to where the request may go.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let allows: @Sendable (URL) -> Bool

    init(_ allows: @escaping @Sendable (URL) -> Bool) {
        self.allows = allows
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url.map(allows) == true ? request : nil
    }
}

/// Dates as Todoist, Linear, GitHub and Jira send them.
enum TaskDates {
    /// "2026-10-26" is that day here; "2026-10-26T15:00:00" that time here;
    /// "2026-10-26T15:00:00Z" (fractions of a second too) that time in UTC;
    /// "2026-10-26T15:00:00.000+0200" that time at that offset.
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
            } else if let sign = time.lastIndex(where: { $0 == "+" || $0 == "-" }) {
                let digits = time[time.index(after: sign)...].filter(\.isNumber)
                guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else { return nil }
                let seconds = (hours * 3600 + minutes * 60) * (time[sign] == "-" ? -1 : 1)
                local.timeZone = TimeZone(secondsFromGMT: seconds) ?? local.timeZone
                time = String(time[..<sign])
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
