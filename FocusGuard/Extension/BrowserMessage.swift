import Foundation

/// The JSON the browser extension and the app exchange, through the helper.
/// Every message is an object with a `type`; requests that expect an answer
/// carry an `id`, echoed back in a `reply`. Times are milliseconds since
/// 1970, so the extension can count down without asking every second.
/// `extension/chrome/src/lib/protocol.js` is the other half of this file.
enum BrowserProtocol {
    /// Bumped when a message changes shape in a way old extensions can't read.
    static let version = 1

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(millis: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }
}

// MARK: - Extension → app

/// The tab the user is looking at, as the extension reports it.
struct BrowserTabReport: Equatable, Codable {
    var url: String?
    var title: String?
    var tabId: Int?
    var windowId: Int?
    /// A YouTube video's details, sent only while video by video is on (Pro).
    var video: Video?

    struct Video: Equatable, Codable {
        var title: String?
        var channel: String?
    }
}

/// A category as the extension names it.
enum BrowserCategory: String, Codable {
    case focus, neutral, distracting

    init(_ classification: Classification) {
        switch classification {
        case .focus:       self = .focus
        case .neutral:     self = .neutral
        case .distraction: self = .distracting
        }
    }

    var classification: Classification {
        switch self {
        case .focus:       return .focus
        case .neutral:     return .neutral
        case .distracting: return .distraction
        }
    }
}

/// Whether a category change covers the whole site or just this page.
enum CategoryScope: String, Codable {
    case site, page
}

/// Everything the extension (or the helper, for `helperHello`) can send.
enum ExtensionMessage: Equatable {
    /// First message on every connection, from the helper: which browser
    /// started it and which extension it's talking for.
    case helperHello(browser: String?, origin: String?)
    case hello(extensionVersion: String?, siteAccess: Bool, incognito: Bool)
    /// `nil` when no tab the extension can see is in front (another app,
    /// a private window it isn't allowed in).
    case tab(BrowserTabReport?)
    case classify(id: String, url: String)
    case setCategory(id: String, url: String, scope: CategoryScope, category: BrowserCategory)
    /// `minutes` nil: no end.
    case startSession(id: String, minutes: Int?)
    case extendBreak(id: String, minutes: Int)
    case endBreak(id: String)
    case openApp(page: String?)
    case backToWork(id: String)
    case requestPass(id: String, host: String)
    case allowForWork(id: String, host: String)
    case requestExtraTime(id: String, site: String)
    /// A page the extension kept from loading (Pro), for "stopped 4 visits".
    case blockedVisit(host: String)
    /// Whether the extension paused the tab a `PauseTabCommand` asked for.
    case pauseResult(requestId: String, ok: Bool)
    /// A button on the paused-tab page: "back", "reopenLater", "keepPaused"
    /// or "startBreak" (the same routes as #52's `focusguard://` links).
    case tabAction(id: String, action: String, pauseID: String?, minutes: Int?)
    case unknown(type: String, id: String?)

    var requestId: String? {
        switch self {
        case .classify(let id, _), .setCategory(let id, _, _, _), .startSession(let id, _),
             .extendBreak(let id, _), .endBreak(let id), .backToWork(let id),
             .requestPass(let id, _), .allowForWork(let id, _), .requestExtraTime(let id, _),
             .tabAction(let id, _, _, _):
            return id
        case .unknown(_, let id):
            return id
        case .helperHello, .hello, .tab, .openApp, .blockedVisit, .pauseResult:
            return nil
        }
    }

    /// Every field any message uses; `type` says which apply.
    private struct Wire: Decodable {
        var type: String
        var id: String?
        var browser: String?
        var origin: String?
        var extensionVersion: String?
        var siteAccess: Bool?
        var incognito: Bool?
        var tab: BrowserTabReport?
        var url: String?
        var scope: CategoryScope?
        var category: BrowserCategory?
        var minutes: Int?
        var page: String?
        var host: String?
        var site: String?
        var rid: String?
        var ok: Bool?
        var action: String?
        var pauseId: String?
    }

    enum DecodeError: Error, Equatable {
        case missing(String)
    }

    static func decode(_ data: Data) throws -> ExtensionMessage {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        func need<T>(_ value: T?, _ name: String) throws -> T {
            guard let value else { throw DecodeError.missing(name) }
            return value
        }
        switch wire.type {
        case "helperHello":
            return .helperHello(browser: wire.browser, origin: wire.origin)
        case "hello":
            return .hello(extensionVersion: wire.extensionVersion,
                          siteAccess: wire.siteAccess ?? false,
                          incognito: wire.incognito ?? false)
        case "tab":
            return .tab(wire.tab)
        case "classify":
            return .classify(id: try need(wire.id, "id"), url: try need(wire.url, "url"))
        case "setCategory":
            return .setCategory(id: try need(wire.id, "id"), url: try need(wire.url, "url"),
                                scope: wire.scope ?? .site, category: try need(wire.category, "category"))
        case "startSession":
            let minutes = wire.minutes.flatMap { $0 > 0 ? $0 : nil }
            return .startSession(id: try need(wire.id, "id"), minutes: minutes)
        case "extendBreak":
            return .extendBreak(id: try need(wire.id, "id"), minutes: wire.minutes ?? 5)
        case "endBreak":
            return .endBreak(id: try need(wire.id, "id"))
        case "openApp":
            return .openApp(page: wire.page)
        case "backToWork":
            return .backToWork(id: try need(wire.id, "id"))
        case "requestPass":
            return .requestPass(id: try need(wire.id, "id"), host: try need(wire.host, "host"))
        case "allowForWork":
            return .allowForWork(id: try need(wire.id, "id"), host: try need(wire.host, "host"))
        case "requestExtraTime":
            return .requestExtraTime(id: try need(wire.id, "id"), site: try need(wire.site, "site"))
        case "blockedVisit":
            return .blockedVisit(host: try need(wire.host, "host"))
        case "pauseResult":
            return .pauseResult(requestId: try need(wire.rid, "rid"), ok: wire.ok ?? false)
        case "tabAction":
            return .tabAction(id: try need(wire.id, "id"), action: try need(wire.action, "action"),
                              pauseID: wire.pauseId, minutes: wire.minutes)
        default:
            return .unknown(type: wire.type, id: wire.id)
        }
    }
}

// MARK: - App → extension

/// Everything the popup, toolbar button and block pages show. Pushed to
/// every connected extension whenever it changes.
struct ExtensionState: Equatable, Encodable {
    let type = "state"
    var v = BrowserProtocol.version
    var app: AppInfo
    var plan: Plan
    /// The preset in force: "gentle", "standard" or "strict".
    var preset: String
    /// What the block pages offer on that preset (passes, waits, extra
    /// time), straight from the app's `OverridePolicy`.
    var policy: OverridePolicy
    var today: Today
    var phase: Phase
    var session: SessionInfo?
    var breakInfo: BreakInfo?
    var recap: Recap?
    var blocking: Blocking

    enum Phase: String, Encodable {
        case ready, focusing, paused
        case onBreak = "break"
        case complete
    }

    struct AppInfo: Equatable, Encodable {
        var version: String
    }

    struct Plan: Equatable, Encodable {
        /// "free", "trial" or "pro".
        var tier: String
        /// Pro features unlocked (Pro or a running trial).
        var pro: Bool
        var trialDaysLeft: Int?
        /// The Pro features the extension uses, one by one.
        var features: Features
    }

    struct Features: Equatable, Encodable {
        var blockInBrowser: Bool
        var partsOfSites: Bool
        var youtubePerVideo: Bool
        var unlimitedLimits: Bool
    }

    struct Today: Equatable, Encodable {
        var focusSeconds: Int
        var goalMinutes: Int
    }

    struct SessionInfo: Equatable, Encodable {
        var name: String
        var startedAt: Int64
        /// Nil for open-ended sessions.
        var endsAt: Int64?
        var plannedMinutes: Int?
        /// Running time so far (pauses left out), as of `asOf`.
        var elapsedSeconds: Int
        var asOf: Int64
        var paused: Bool
        /// Tracked time in order, as `[kind, seconds]` with kind "f", "d" or "o".
        var segments: [Segment]
        var focusSeconds: Int
        var driftSeconds: Int
        var otherSeconds: Int
        /// Pages the extension kept from loading this session.
        var stoppedVisits: Int
        /// The app the block page's "Back to …" returns to.
        var backTo: String?
    }

    struct Segment: Equatable, Encodable {
        var kind: String
        var seconds: Int

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(kind)
            try container.encode(seconds)
        }
    }

    struct BreakInfo: Equatable, Encodable {
        var startedAt: Int64
        var endsAt: Int64
        var plannedSeconds: Int
        /// The session it follows, e.g. "Locked-in Deep Dive · 50 min".
        var after: String?
        var canEndEarly: Bool
    }

    struct Recap: Equatable, Encodable {
        var name: String
        var endedAt: Int64
        /// The toolbar shows the check-shield until then.
        var showUntil: Int64
    }

    struct Blocking: Equatable, Encodable {
        /// Pause distracting tabs when the block screen comes up (free, level 1).
        var pauseTab: Bool
        /// Whole sites blocked during sessions.
        var sites: [String]
        /// Parts of sites, as "host/path".
        var parts: [String]
        var limits: [Limit]
        /// Running 2-minute passes.
        var passes: [Pass]
        /// Sites let through as "for work" until the session ends.
        var allowed: [String]
        /// Strict: the blocked list can't change until then.
        var lockedUntil: Int64?
    }

    /// A daily limit on a site, from the app's `DailyLimitsEngine`.
    struct Limit: Equatable, Encodable {
        var site: String
        /// Today's allowance, extra time included.
        var minutes: Int
        var usedSeconds: Int
        /// Over the limit: blocked until 00:00.
        var reached: Bool
        /// Extra-time grants left today; how much and how soon is in `policy.extraTime`.
        var extraLeft: Int
        /// Separate visits today and when the last began; worked out only
        /// once the limit is reached, for its block page.
        var visits: Int?
        var lastVisitAt: Int64?
    }

    struct Pass: Equatable, Encodable {
        var host: String
        var until: Int64
    }

    private enum CodingKeys: String, CodingKey {
        case type, v, app, plan, preset, policy, today, phase, session, recap, blocking
        case breakInfo = "break"
    }
}

/// Answer to a request, matched by `id`.
struct ExtensionReply: Encodable {
    let type = "reply"
    var id: String
    var ok: Bool
    var error: String?
    var result: Result?

    /// The union of what any reply carries.
    struct Result: Equatable, Encodable {
        /// classify / setCategory
        var host: String?
        var category: BrowserCategory?
        /// "site" or "page" when a rule decides it, nil for the default.
        var ruleScope: CategoryScope?
        /// backToWork: the app brought forward, nil when there was none.
        var app: String?
        /// requestPass / requestExtraTime
        var until: Int64?
    }

    private enum CodingKeys: String, CodingKey { case type, id, ok, error, result }
}

/// Free "Pause the tab" (`ExtensionTabPauser`): point the front tab at the
/// extension's paused page, if it still shows `host`. Answered by
/// `pauseResult` with the same `rid`.
struct PauseTabCommand: Encodable {
    let type = "pauseTab"
    var rid: String
    var host: String
    /// The tab the extension last reported, to try first.
    var tabId: Int?
    /// The paused page's fields, exactly as `PausedPage` builds them for
    /// paused.html: id, host, url, state, ends, back, minutes.
    var fragment: String

    private enum CodingKeys: String, CodingKey { case type, rid, host, tabId, fragment }
}

/// Points the tab showing paused page `pauseId` at the page in another state
/// (`fragment`) or back at the site (`url`).
struct RedirectTabCommand: Encodable {
    let type = "redirectTab"
    var pauseId: String
    var fragment: String?
    var url: String?

    private enum CodingKeys: String, CodingKey { case type, pauseId, fragment, url }
}

/// Asks the extension to report its active tab again.
struct RefreshCommand: Encodable {
    let type = "refresh"

    private enum CodingKeys: String, CodingKey { case type }
}
