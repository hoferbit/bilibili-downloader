import Foundation

/// 单文件下载：支持断点续传、备用地址切换、进度回调。
final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var writeError: Error?
    private var offset: Int64 = 0
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var lastReport = Date.distantPast
    private let part: URL
    private let progress: @Sendable (Int64, Int64) -> Void

    init(part: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.part = part
        self.progress = progress
    }

    static func fetch(urls: [String], to dest: URL, label: String = "文件", tag: String? = nil,
                      progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard !urls.isEmpty else { throw BiliError.noStream("地址为空") }
        let part = dest.appendingPathExtension("part")
        var lastError: Error = BiliError.downloadFailed("未知错误")
        for attempt in 0 ..< max(4, urls.count) {
            try Task.checkCancellation()
            guard let url = URL(string: urls[attempt % urls.count]) else { continue }
            let host = url.host ?? "?"
            let before = fileSize(part)
            let watch = Stopwatch()
            do {
                try await FileDownload(part: part, progress: progress).run(url)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: part, to: dest)
                let got = Double(fileSize(dest) - before)
                Log.info("\(label)下载完成 \(formatBytes(Double(fileSize(dest))))\(before > 0 ? "（续传 \(formatBytes(Double(before)))）" : "")，"
                    + "用时 \(watch.text)，\(formatBytes(got / max(watch.elapsed, 0.001)))/s，节点 \(host)\(attempt > 0 ? "，第 \(attempt + 1) 次尝试" : "")",
                    tag: tag)
                return
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                lastError = error
                Log.warn("\(label)下载失败（第 \(attempt + 1) 次，节点 \(host)，已下 \(formatBytes(Double(fileSize(part)))))：\(error.localizedDescription)", tag: tag)
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 800_000_000)
            }
        }
        throw lastError
    }

    func run(_ url: URL, configuration: URLSessionConfiguration = .default) async throws {
        try Task.checkCancellation()
        let existing = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(BiliClient.referer, forHTTPHeaderField: "Referer")
        if existing > 0 { req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        offset = existing

        let cfg = configuration
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let t = session.dataTask(with: req)
                lock.withLock {
                    continuation = cont
                    task = t
                    if cancelled { t.cancel() }
                    t.resume()
                }
            }
        } onCancel: {
            lock.withLock {
                cancelled = true
                task?.cancel()
            }
        }
    }

    private func finish(_ error: Error?) {
        let cont: CheckedContinuation<Void, Error>? = lock.withLock {
            let c = continuation
            continuation = nil
            try? handle?.close()
            handle = nil
            return c
        }
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        let fm = FileManager.default
        switch http.statusCode {
        case 200:
            // 服务器不支持续传，从头开始
            offset = 0
            fm.createFile(atPath: part.path, contents: nil)
        case 206:
            do { try Self.validateContentRange(http, offset: offset) } catch {
                // 错位的响应不能追加，否则会把损坏文件标记为下载完成。
                completionHandler(.cancel)
                finish(error)
                return
            }
            if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        case 416:
            try? fm.removeItem(at: part)
            completionHandler(.cancel)
            finish(BiliError.http(416))
            return
        default:
            completionHandler(.cancel)
            finish(BiliError.http(http.statusCode))
            return
        }
        do {
            let h = try FileHandle(forWritingTo: part)
            if offset == 0 { try h.truncate(atOffset: 0) } else { try h.seekToEnd() }
            lock.withLock {
                handle = h
                expected = http.expectedContentLength > 0 ? offset + http.expectedContentLength : -1
                received = offset
            }
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let report: (Int64, Int64)? = lock.withLock {
            do { try handle?.write(contentsOf: data) } catch {
                writeError = error
                task?.cancel()
                return nil
            }
            received += Int64(data.count)
            let now = Date()
            guard now.timeIntervalSince(lastReport) > 0.2 else { return nil }
            lastReport = now
            return (received, expected)
        }
        if let report { progress(report.0, report.1) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure = lock.withLock({ writeError }) { finish(failure); return }
        let (got, total) = lock.withLock { (received, expected) }
        if error == nil && total > 0 && got < total {
            finish(BiliError.downloadFailed("连接中断（\(got)/\(total)）"))
            return
        }
        if error == nil { progress(got, total > 0 ? total : got) }
        finish(error)
    }

    static func validateContentRange(_ response: HTTPURLResponse, offset: Int64) throws {
        let value = response.value(forHTTPHeaderField: "Content-Range") ?? ""
        let fields = value.split(separator: " ")
        guard fields.count == 2, fields[0].lowercased() == "bytes" else {
            throw BiliError.downloadFailed("续传响应缺少有效 Content-Range")
        }
        let range = fields[1].split(separator: "/")
        let bounds = range.first?.split(separator: "-") ?? []
        guard range.count == 2, bounds.count == 2,
              let start = Int64(bounds[0]), let end = Int64(bounds[1]), let total = Int64(range[1]),
              start == offset, start >= 0, end >= start, total > end, end == total - 1,
              response.expectedContentLength < 0 || response.expectedContentLength == end - start + 1 else {
            throw BiliError.downloadFailed("续传响应范围与本地文件不一致")
        }
    }
}
