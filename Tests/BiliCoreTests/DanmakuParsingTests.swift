import XCTest
@testable import BiliCore

final class DanmakuParsingTests: XCTestCase {
    func testMalformedProtobufThrowsInsteadOfCrashing() {
        let largest = Array(repeating: UInt8(0xFF), count: 9) + [0x01]
        let overflowing = Array(repeating: UInt8(0xFF), count: 9) + [0x02]
        for bytes in [[0x0A] + largest, [0x0A] + overflowing,
                      [0x0A, 0x02, 0x3A, 0x7F], [0x09, 0x00], [0x0D, 0x00]] {
            XCTAssertThrowsError(try parseSegment(Data(bytes)))
        }
    }

    func testValidCommentSurvivesParsing() throws {
        let comments = try parseSegment(Data([0x0A, 0x04, 0x3A, 0x02, 0x48, 0x69]))
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.content, "Hi")
    }

    func testTallBottomCommentDoesNotIndexNegativeLane() {
        let comment = DanmakuComment(id: 1, time: 0, mode: 4, fontSize: 64, color: 0xFFFFFF,
                                     midHash: "", content: Array(repeating: "line", count: 100).joined(separator: "\n"),
                                     ctime: 0, weight: 0, pool: 0)
        let result = DanmakuASS.make([comment], width: 1920, height: 1080, style: DanmakuStyle())
        XCTAssertEqual(result.dropped, 1)
        XCTAssertEqual(result.count, 0)
    }
}
