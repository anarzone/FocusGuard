import XCTest
@testable import FocusGuard

final class GlyphAnimationTests: XCTestCase {
    func testNoAnimationOnFirstRenderOrNoChange() {
        XCTAssertTrue(GlyphAnimation.frames(from: nil, to: .focusing(progress: 0.5)).isEmpty)
        XCTAssertTrue(GlyphAnimation.frames(from: .ready, to: .ready).isEmpty)
        XCTAssertTrue(GlyphAnimation.frames(from: .focusing(progress: 0.5), to: .paused).isEmpty)
    }

    func testSessionStartSweepsUpThenSettles() {
        let frames = GlyphAnimation.frames(from: .ready, to: .focusing(progress: 0.2))
        XCTAssertEqual(frames.count, 24)
        XCTAssertEqual(frames.map { $0.fill ?? -1 }.max()!, 1, accuracy: 0.0001)
        XCTAssertEqual(frames.last!.fill!, 0.2, accuracy: 0.0001)
    }

    func testFillStepGlidesToTheNewLevel() {
        let frames = GlyphAnimation.frames(from: .focusing(progress: 0.5), to: .focusing(progress: 0.54))
        XCTAssertEqual(frames.count, 9)
        XCTAssertTrue(frames.allSatisfy { ($0.fill ?? 0) > 0.5 - 1e-9 && ($0.fill ?? 1) <= 0.54 + 1e-9 })
        XCTAssertEqual(frames.last!.fill!, 0.54, accuracy: 0.0001)
    }

    func testDriftShakesOnceAndEndsCentred() {
        let frames = GlyphAnimation.frames(from: .focusing(progress: 0.3), to: .drifted)
        XCTAssertEqual(frames.count, 8)
        XCTAssertEqual(frames.last!.dx, 0)
        XCTAssertTrue(frames.contains { $0.dx != 0 })
    }

    func testCompleteDrawsTheCheckAndBreakFadesInSteam() {
        let check = GlyphAnimation.frames(from: .focusing(progress: 0.9), to: .complete)
        XCTAssertEqual(check.last!.checkProgress, 1, accuracy: 0.0001)
        XCTAssertLessThan(check.first!.checkProgress, 0.1)
        let steam = GlyphAnimation.frames(from: .complete, to: .onBreak)
        XCTAssertEqual(steam.last!.steamOpacity, 1, accuracy: 0.0001)
    }

    func testFinerFillSteps() {
        // One Retina pixel per step: 26 levels across the shield.
        XCTAssertEqual(StatusGlyphState.focusing(elapsed: 1500, planned: 3000), .focusing(progress: 0.5))
        XCTAssertEqual(StatusGlyphState.focusing(elapsed: 120, planned: 3000), .focusing(progress: 1.0 / 26))
    }

    func testPartialCheckStartsAtTheFirstPoint() {
        let path = StatusGlyph.partialPolyline([.zero, CGPoint(x: 10, y: 0)], fraction: 0.5)
        XCTAssertEqual(path.currentPoint.x, 5, accuracy: 0.0001)
    }
}
