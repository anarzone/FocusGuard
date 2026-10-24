import XCTest
@testable import FocusGuard

final class CallDetectorTests: XCTestCase {
    private var detector = CallDetector()

    private func reading(recording: [String]?, mic: Bool = true, running: Set<String> = [],
                         front: String? = nil) -> CallDetector.Reading {
        .init(recording: recording, microphoneInUse: mic, runningApps: running, frontURL: front)
    }

    private func call(_ reading: CallDetector.Reading) -> String? {
        detector.update(reading)?.name
    }

    func testACallAppRecordingIsACall() {
        XCTAssertEqual(call(reading(recording: ["us.zoom.xos"])), "Zoom")
        XCTAssertEqual(detector.update(reading(recording: ["us.zoom.CptHost"])),
                       .init(name: "Zoom", bundleId: "us.zoom.xos"))
        XCTAssertEqual(call(reading(recording: ["com.microsoft.teams2"])), "Teams")
        XCTAssertEqual(call(reading(recording: ["com.apple.avconferenced"])), "FaceTime")
        XCTAssertEqual(call(reading(recording: ["com.tinyspeck.slackmacgap.helper"])), "Slack")
    }

    func testOtherRecordingIsNotACall() {
        XCTAssertNil(call(reading(recording: ["com.apple.VoiceMemos"])))
        XCTAssertNil(call(reading(recording: [], mic: false)))
    }

    func testABrowserCallCountsOnceSeenInFront() {
        let chrome = ["com.google.Chrome.helper"]
        XCTAssertNil(call(reading(recording: chrome, front: "https://www.youtube.com/")))
        XCTAssertEqual(detector.update(reading(recording: chrome, front: "https://meet.google.com/abc-defg-hij")),
                       .init(name: "Google Meet", bundleId: nil))
        // Still a call with the Meet tab in the background.
        XCTAssertEqual(call(reading(recording: chrome, front: "https://x.com/home")), "Google Meet")
        // The microphone goes quiet: the call is over, and so is the memory of it.
        XCTAssertNil(call(reading(recording: [], mic: false)))
        XCTAssertNil(call(reading(recording: chrome, front: "https://x.com/home")))
    }

    func testWithoutPerAppInfoAnOpenCallAppAndTheMicCount() {
        XCTAssertEqual(call(reading(recording: nil, running: ["us.zoom.xos", "com.apple.Safari"])), "Zoom")
        XCTAssertNil(call(reading(recording: nil, running: ["com.apple.Safari"])))
        XCTAssertNil(call(reading(recording: nil, mic: false, running: ["us.zoom.xos"])))
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
