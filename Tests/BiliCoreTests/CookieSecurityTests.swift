import XCTest
@testable import BiliCore

final class CookieSecurityTests: XCTestCase {
    func testCookiesAreLimitedToHTTPSBilibiliHosts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CookieStore(fileURL: directory.appendingPathComponent("cookies.json"))
        let client = BiliClient(store: store)
        defer { client.session.invalidateAndCancel() }
        client.setCookies(["SESSDATA": "test-only-placeholder"])
        for address in ["https://bilibili.com/", "https://api.bilibili.com/x"] {
            XCTAssertNotNil(client.request(try XCTUnwrap(URL(string: address))).value(forHTTPHeaderField: "Cookie"))
        }
        for address in ["http://api.bilibili.com/x", "https://bilibili.com.example.org/", "https://example.org/", "https://evilbilibili.com/"] {
            XCTAssertNil(client.request(try XCTUnwrap(URL(string: address))).value(forHTTPHeaderField: "Cookie"))
        }
        XCTAssertNil(client.request(URL(string: "https://api.bilibili.com/")!, withCookies: false).value(forHTTPHeaderField: "Cookie"))
        client.logout()
        XCTAssertNil(store.load()["SESSDATA"])
    }

    func testSavingReplacesPermissiveFileAndKeepsOnlyOwnerAccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cookies.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let store = CookieStore(fileURL: file)
        for value in ["first-test-value", "second-test-value"] {
            store.save(["SESSDATA": value])
            XCTAssertEqual(store.load(), ["SESSDATA": value])
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["cookies.json"])
    }
}
