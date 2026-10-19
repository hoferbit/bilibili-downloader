import XCTest
@testable import BiliCore

final class PlaybackTests: XCTestCase {
    func testShareChoosesNearestAvailableSizeAndAvoidsHighFrameRateTies() {
        let videos = [(16, 640, 360), (32, 854, 480), (64, 1280, 720), (80, 1920, 1080), (116, 1920, 1080)].map {
            JSON(["id": $0.0, "width": $0.1, "height": $0.2])
        }
        XCTAssertEqual(nearestShareQuality(videos, maxDimension: 640), 16)
        XCTAssertEqual(nearestShareQuality(videos, maxDimension: 960), 32)
        XCTAssertEqual(nearestShareQuality(videos, maxDimension: 1280), 64)
        XCTAssertEqual(nearestShareQuality(videos, maxDimension: 1920), 80)
        XCTAssertEqual(nearestShareQuality([videos[0], videos[2]], maxDimension: 960), 16)
        XCTAssertEqual(nearestShareQuality([JSON(["id": 64, "width": 720, "height": 1280])], maxDimension: 1280), 64)
        XCTAssertNil(nearestShareQuality([JSON(["id": 125, "width": 1920, "height": 1080])], maxDimension: 960))
    }
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
