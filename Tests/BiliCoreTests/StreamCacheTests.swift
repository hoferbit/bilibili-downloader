import XCTest
@testable import BiliCore

final class StreamCacheTests: XCTestCase {
    func testCacheChangesWithStreamButNotExpiringURLSignatures() {
        let original = StreamInfo(videoURLs: ["https://cdn.example.invalid/video?sign=old"], audioURLs: nil,
                                  qn: 80, codec: .avc, width: 1920, height: 1080, fps: 30,
                                  videoBandwidth: 3000000, durationMs: 60000, available: [80, 64])
        var changed = original
        changed.videoURLs = ["https://cdn.example.invalid/video?sign=new"]
        XCTAssertEqual(changed.cacheIdentity, original.cacheIdentity)
        changed.qn = 64
        XCTAssertNotEqual(changed.cacheIdentity, original.cacheIdentity)
        changed = original
        changed.codec = .hevc
        XCTAssertNotEqual(changed.cacheIdentity, original.cacheIdentity)
        changed = original
        changed.videoURLs = ["https://cdn.example.invalid/other-video?sign=new"]
        XCTAssertNotEqual(changed.cacheIdentity, original.cacheIdentity)
    }
}
