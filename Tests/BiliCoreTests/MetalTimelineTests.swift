import XCTest
@testable import BiliCore

final class MetalTimelineTests: XCTestCase {
    private func comment(time: Double, mode: Int = 1, text: String = "测试 712 ABC") -> DanmakuComment {
        DanmakuComment(id: 1, time: time, mode: mode, fontSize: 25, color: 0xFFFFFF,
                       midHash: "", content: text, ctime: 0, weight: 0, pool: 0)
    }

    func testPreservesLateTimelineAndMovement() throws {
        let ass = DanmakuASS.make([comment(time: 1500)], width: 1920, height: 1080, style: DanmakuStyle()).text
        let t = try MetalTimeline(ass)
        let cue = try XCTUnwrap(t.cues.first)
        XCTAssertEqual(cue.start, 1500)
        XCTAssertEqual(cue.end, 1509)
        XCTAssertEqual(cue.text, "测试 712 ABC")
        XCTAssertGreaterThan(cue.position(at: 1500).x, cue.position(at: 1504.5).x)
        XCTAssertLessThan(cue.position(at: 1509).x, 0)
        XCTAssertFalse(cue.centered)
        XCTAssertEqual(t.outlineOpacity, 0.85, accuracy: 0.003)
    }

    func testFixedCueAndEscapedText() throws {
        let ass = DanmakuASS.make([comment(time: 10, mode: 5, text: "{ABC}\\123")], width: 1920, height: 1080, style: DanmakuStyle()).text
        let cue = try XCTUnwrap(MetalTimeline(ass).cues.first)
        XCTAssertTrue(cue.centered)
        XCTAssertEqual(cue.position(at: 10), cue.position(at: 12))
        XCTAssertEqual(cue.text, "{ABC}\\123")
    }

    func testRejectUnsupportedASS() {
        XCTAssertThrowsError(try MetalTimeline("[Script Info]\n"))
        XCTAssertThrowsError(try MetalTimeline("PlayResX:\nPlayResY:\n"))
    }
}
