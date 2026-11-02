import XCTest
@testable import FocusGuard

/// The German and Azerbaijani catalogs reach the built app, and resolve. The
/// suite itself runs in English (the scheme sets -AppleLanguages (en)), so
/// these go to each language's bundle. scripts/check-translations.py checks
/// every key; these check that the build wires them up.
final class LocalizationTests: XCTestCase {
    private func bundle(_ language: String, file: StaticString = #filePath, line: UInt = #line) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "\(language).lproj is missing", file: file, line: line)
        return try XCTUnwrap(Bundle(path: path), file: file, line: line)
    }

    private func text(_ key: String, _ language: String, table: String? = nil, _ arguments: CVarArg...) throws -> String {
        let format = try bundle(language).localizedString(forKey: key, value: nil, table: table)
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), arguments: arguments)
    }

    func testTheAppOffersThreeLanguages() {
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), ["en", "de", "az"])
    }

    func testPlainKeysResolve() throws {
        XCTAssertEqual(try text("Today", "de"), "Heute")
        XCTAssertEqual(try text("Today", "az"), "Bu gün")
    }

    func testPluralsFollowEachLanguage() throws {
        XCTAssertEqual(try text("%lld sessions", "en", 1), "1 session")
        XCTAssertEqual(try text("%lld sessions", "en", 2), "2 sessions")
        XCTAssertEqual(try text("%lld sessions", "de", 1), "1 Session")
        XCTAssertEqual(try text("%lld sessions", "de", 2), "2 Sessions")
        XCTAssertEqual(try text("%lld sessions", "az", 1), "1 sessiya")
        XCTAssertEqual(try text("%lld sessions", "az", 2), "2 sessiya")
    }

    func testAPluralInsideASentenceKeepsTheOtherValues() throws {
        let key = "From this week so far and last week · %lld sessions"
        let one = try text(key, "de", 1), three = try text(key, "de", 3)
        XCTAssertTrue(one.hasSuffix("1 Session"), one)
        XCTAssertTrue(three.hasSuffix("3 Sessions"), three)

        let sentence = "Focused in all of last week: %@, %lld sessions."
        let german = try text(sentence, "de", "3 Std" as NSString, 1)
        XCTAssertTrue(german.contains("3 Std"), german)
        XCTAssertTrue(german.contains("1 Session"), german)
    }

    func testFormatStringsResolve() throws {
        let german = try text("%@ is blocked after %lld minutes a day.", "de", "x.com" as NSString, 20)
        XCTAssertTrue(german.contains("x.com") && german.contains("20"), german)
        let azerbaijani = try text("%@ is blocked after %lld minutes a day.", "az", "x.com" as NSString, 20)
        XCTAssertTrue(azerbaijani.contains("x.com") && azerbaijani.contains("20"), azerbaijani)
    }

    func testCompactDurationsHaveTheirOwnForms() throws {
        XCTAssertEqual(try text("%lldm", "de", 24), "24 Min")
        XCTAssertEqual(try text("%lldh %lldm", "de", 1, 20), "1 Std 20 Min")
        XCTAssertEqual(try text("%lldm", "az", 24), "24 dəq")
        XCTAssertEqual(try text("%lldh %lldm", "az", 1, 20), "1 s 20 dəq")
    }

    func testPermissionPromptsAreTranslated() throws {
        let german = try text("NSRemindersUsageDescription", "de", table: "InfoPlist")
        XCTAssertTrue(german.contains("Erinnerungen"), german)
        let azerbaijani = try text("NSRemindersUsageDescription", "az", table: "InfoPlist")
        XCTAssertTrue(azerbaijani.contains("xatırladıcı"), azerbaijani)
    }

    // MARK: - English keeps working

    func testTheTestsRunInEnglish() {
        XCTAssertEqual(OnDeviceAI.appLanguage, "en")
        XCTAssertEqual(String(localized: "Today"), "Today")
    }

    func testEnglishPromptsGetNoLanguageLine() {
        XCTAssertTrue(OnDeviceAI.writesAppLanguage)
        XCTAssertEqual(OnDeviceAI.languageInstruction, "")
    }

    // MARK: - Sentences with a bold start

    func testAPointSplitsAtItsMark() {
        let point = CoachPoint("Most of that drift came late:| 60% of it.", tone: .other)
        XCTAssertEqual(point.lead, "Most of that drift came late:")
        XCTAssertEqual(point.rest, " 60% of it.")
        XCTAssertEqual(point.sentence, "Most of that drift came late: 60% of it.")
        XCTAssertEqual(CoachPoint("All of it bold.", tone: .focus).rest, "")
    }

    // MARK: - Decisions don't read display words

    func testAnUnchangedResultIsKnownWithoutReadingItsWords() {
        XCTAssertTrue(CoachMetric.sessionRate(.allDay).isUnchanged(from: 0.8, to: 0.8))
        XCTAssertFalse(CoachMetric.sessionRate(.allDay).isUnchanged(from: 0.8, to: 0.9))
        XCTAssertTrue(CoachMetric.firstSession.isUnchanged(from: 540, to: 543))
        XCTAssertFalse(CoachMetric.firstSession.isUnchanged(from: 540, to: 560))
        XCTAssertFalse(CoachMetric.siteMinutes("x.com").isUnchanged(from: 20, to: 20))
    }

    func testAnUntitledMeetingIsJustTheMeeting() {
        let entry = CalendarEntry(id: "a", title: "", start: .now.addingTimeInterval(60), end: .now.addingTimeInterval(120), isAllDay: false, isOwn: false, isDeclined: false)
        XCTAssertEqual(NextMeeting.pick(from: [entry], now: .now, ownIDs: [])?.shortTitle, "the meeting")
    }

    // MARK: - Ask in other languages

    func testGermanQuestionsFindTheirKind() {
        XCTAssertEqual(AskOtherLanguages.intent("Wann bin ich am produktivsten?"), .bestHours)
        XCTAssertEqual(AskOtherLanguages.intent("Was lenkt mich am meisten ab? Ablenkung überall"), .pullsAway)
        XCTAssertEqual(AskOtherLanguages.intent("Wie lief diese Woche im Vergleich zur letzten?"), .weekCompare)
        XCTAssertEqual(AskOtherLanguages.intent("Wie lang sollten meine Sessions sein?"), .sessionLength)
        XCTAssertEqual(AskOtherLanguages.intent("An welchen Tagen bin ich am meisten abgelenkt?"), .driftDay)
        XCTAssertEqual(AskOtherLanguages.intent("Wie viel Zeit auf YouTube?"), .appTime)
        XCTAssertEqual(AskOtherLanguages.intent("Hat das Experiment geholfen?"), .coachExperiment)
        XCTAssertEqual(AskOtherLanguages.intent("Was gibt es zum Mittagessen?"), .unknown)
    }

    func testAzerbaijaniQuestionsFindTheirKind() {
        XCTAssertEqual(AskOtherLanguages.intent("Nə vaxt daha yaxşı fokuslanıram?"), .bestHours)
        XCTAssertEqual(AskOtherLanguages.intent("Məni ən çox nə yayındırır?"), .pullsAway)
        XCTAssertEqual(AskOtherLanguages.intent("Bu həftə keçən həftə ilə müqayisədə necə keçdi?"), .weekCompare)
        XCTAssertEqual(AskOtherLanguages.intent("Sessiyalarım nə qədər uzun olmalıdır?"), .sessionLength)
        XCTAssertEqual(AskOtherLanguages.intent("Hansı gün daha çox yayınıram?"), .driftDay)
        XCTAssertEqual(AskOtherLanguages.intent("YouTube-da nə qədər vaxt keçirdim?"), .appTime)
        XCTAssertEqual(AskOtherLanguages.intent("Eksperiment işə yaradı?"), .coachExperiment)
        XCTAssertEqual(AskOtherLanguages.intent("Hava necədir?"), .unknown)
    }

    func testOtherLanguagesNameHoursAndPeriods() {
        XCTAssertEqual(AskHours.parse("Was lenkt mich nachmittags ab?"), AskHours(from: 12, to: 17))
        XCTAssertEqual(AskHours.parse("Abends bin ich müde"), AskHours(from: 17, to: 22))
        XCTAssertEqual(AskHours.parse("Səhərlər məni nə yayındırır?"), AskHours(from: 6, to: 12))
        XCTAssertEqual(AskHours.parse("Nach 15 Uhr"), AskHours(from: 15, to: 17))
        XCTAssertEqual(AskPeriod.parse("Wie viel Zeit letzte Woche?"), .lastWeek)
        XCTAssertEqual(AskPeriod.parse("Bu həftə nə qədər vaxt?"), .thisWeek)
        XCTAssertEqual(AskPeriod.parse("Bu gün nə qədər vaxt?"), .today)
    }

    func testTheSuggestedQuestionsNeedNoWordsAtAll() {
        for question in AskSuggestions.all {
            XCTAssertNotEqual(AskIntentMatcher.match(question), .unknown, question)
        }
        XCTAssertEqual(AskSuggestions.intent(of: AskSuggestions.all[3]), .driftDay)
    }

    func testANameWithASuffixStillMatches() {
        let target = AskFactsBuilder.Target(key: "youtube.com", name: "youtube.com", isSite: true, seconds: 60, names: ["youtube.com", "youtube"])
        XCTAssertEqual(AskFactsBuilder.match("YouTube-da nə qədər vaxt?", in: [target])?.key, "youtube.com")
    }

    // MARK: - The paused page

    func testThePausedPageHearsTheLanguageOnlyWhenItIsNotEnglish() throws {
        let base = URL(fileURLWithPath: "/paused.html")
        let tab = PausedTab(id: "a", browser: "com.apple.Safari", host: "x.com", originalURL: try XCTUnwrap(URL(string: "https://x.com")),
                            reason: .limit(minutes: 5), endsAt: nil, backTo: nil)
        let url = PausedPage.url(base: base, for: tab, state: .limit)
        XCTAssertFalse((url.fragment(percentEncoded: true) ?? "").contains("lang="))
    }
}
