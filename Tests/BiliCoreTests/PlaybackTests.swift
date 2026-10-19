import XCTest
@testable import BiliCore

final class PlaybackTests: XCTestCase {
    func testRejectPreviewAndDRM() {
        for payload: [String: Any] in [["is_preview": true], ["is_preview": 1], ["is_drm": true], ["is_drm": 1]] {
            XCTAssertThrowsError(try validateFullPlayback(JSON(payload)))
        }
    }

    func testDRMFlagWithOrdinaryStreamRequiresLaterDecodeCheck() {
        let clear: [String: Any] = ["base_url": "https://example.invalid/video.m4s", "codecs": "avc1.640032"]
        XCTAssertNoThrow(try validateFullPlayback(JSON(["is_drm": true, "dash": ["video": [clear]]])))
        var encrypted = clear
        encrypted["drm_tech_type"] = 1
        XCTAssertThrowsError(try validateFullPlayback(JSON(["is_drm": true, "dash": ["video": [encrypted]]])))
        XCTAssertTrue(streamIsEncrypted(JSON(encrypted)))
        XCTAssertFalse(streamIsEncrypted(JSON(clear)))
    }

    func testAcceptFullPlaybackAndMissingOptionalFlags() {
        for payload: [String: Any] in [[:], ["is_preview": false, "is_drm": false], ["is_preview": 0, "is_drm": 0]] {
            XCTAssertNoThrow(try validateFullPlayback(JSON(payload)))
        }
    }
}
