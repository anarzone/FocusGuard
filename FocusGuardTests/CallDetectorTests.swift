import XCTest
@testable import FocusGuard

final class CallDetectorTests: XCTestCase {
    private var detector = CallDetector()

    private func reading(recording: [String]?, mic: Bool = true, running: Set<String> = [],
                         front: String? = nil) -> CallDetector.Reading {
        .init(recording: recording, microphoneInUse: mic, runningApps: running, frontURL: front)
    }

    func testACallAppRecordingIsACall() {
        XCTAssertTrue(detector.update(reading(recording: ["us.zoom.xos"])))
        XCTAssertTrue(detector.update(reading(recording: ["us.zoom.CptHost"])))
        XCTAssertTrue(detector.update(reading(recording: ["com.microsoft.teams2"])))
        XCTAssertTrue(detector.update(reading(recording: ["com.apple.avconferenced"])))
        XCTAssertTrue(detector.update(reading(recording: ["com.tinyspeck.slackmacgap.helper"])))
    }

    func testOtherRecordingIsNotACall() {
        XCTAssertFalse(detector.update(reading(recording: ["com.apple.VoiceMemos"])))
        XCTAssertFalse(detector.update(reading(recording: [], mic: false)))
    }

    func testABrowserCallCountsOnceSeenInFront() {
        let chrome = ["com.google.Chrome.helper"]
        XCTAssertFalse(detector.update(reading(recording: chrome, front: "https://www.youtube.com/")))
        XCTAssertTrue(detector.update(reading(recording: chrome, front: "https://meet.google.com/abc-defg-hij")))
        // Still a call with the Meet tab in the background.
        XCTAssertTrue(detector.update(reading(recording: chrome, front: "https://x.com/home")))
        // The microphone goes quiet: the call is over, and so is the memory of it.
        XCTAssertFalse(detector.update(reading(recording: [], mic: false)))
        XCTAssertFalse(detector.update(reading(recording: chrome, front: "https://x.com/home")))
    }

    func testWithoutPerAppInfoAnOpenCallAppAndTheMicCount() {
        XCTAssertTrue(detector.update(reading(recording: nil, running: ["us.zoom.xos", "com.apple.Safari"])))
        XCTAssertFalse(detector.update(reading(recording: nil, running: ["com.apple.Safari"])))
        XCTAssertFalse(detector.update(reading(recording: nil, mic: false, running: ["us.zoom.xos"])))
    }

    func testCallsAreNeutralByDefault() {
        let seeds = DefaultRules.seeds
        for id in ["us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams2"] {
            XCTAssertEqual(seeds.first { $0.pattern == id }?.classification, .neutral, id)
        }
        XCTAssertEqual(seeds.first { $0.pattern == "meet.google.com" }?.kind, .host)
        XCTAssertTrue(MeetingApps.isCallSite("https://meet.google.com/abc"))
        XCTAssertFalse(MeetingApps.isCallSite("https://google.com/search"))
    }
}
