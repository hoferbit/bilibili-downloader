import XCTest
@testable import BiliCore

private final class DownloadStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "3"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("new".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DownloadValidationTests: XCTestCase {
    func testRejectsIncorrectAndIncompleteResumeRanges() throws {
        for range in [nil, "bytes 0-9/10", "bytes 5-8/10", "bytes 5-10/10", "bytes 5-9/*", "bytes 5-9/10/11"] as [String?] {
            let headers = range.map { ["Content-Range": $0, "Content-Length": "5"] } ?? [:]
            let response = HTTPURLResponse(url: URL(string: "https://example.invalid/video")!, statusCode: 206,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            XCTAssertThrowsError(try FileDownload.validateContentRange(response, offset: 5), range ?? "missing")
        }
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid/video")!, statusCode: 206,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes 5-9/10", "Content-Length": "5"])!
        XCTAssertNoThrow(try FileDownload.validateContentRange(response, offset: 5))
    }

    func testServerIgnoringRangeReplacesPartialFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let part = directory.appendingPathComponent("video.part")
        try Data("old partial bytes".utf8).write(to: part)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadStub.self]
        try await FileDownload(part: part) { _, _ in }.run(URL(string: "https://example.invalid/video")!, configuration: configuration)
        XCTAssertEqual(try Data(contentsOf: part), Data("new".utf8))
    }
}
