import CryptoKit
import Foundation

public enum BiliError: LocalizedError, Sendable {
    case api(Int, String)
    case http(Int)
    case invalidInput(String)
    case noStream(String)
    case ffmpegMissing
    case ffmpegFailed(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .api(code, msg):
            switch code {
            case -101: return "账号未登录（\(code)）"
            case -352, -412: return "触发了 B 站风控（\(code)），请稍后再试或先登录"
            case -404, 62002, 62004: return "视频不存在或已被删除（\(code)）"
            case -10403: return "该内容有地区限制或需要大会员（\(code)）"
            default: return "B 站接口返回错误 \(code)：\(msg)"
            }
        case let .http(code):
            return code == 412 ? "请求被 B 站拦截（412 风控），请稍后再试；UP 主空间列表可先登录，或改用合集/收藏夹链接" : "HTTP 错误 \(code)"
        case let .invalidInput(msg): return msg
        case let .noStream(msg): return "没有可用的视频流：\(msg)"
        case .ffmpegMissing: return "未找到 ffmpeg，请先执行 brew install ffmpeg，或在设置中指定路径"
        case let .ffmpegFailed(msg): return "ffmpeg 处理失败：\(msg)"
        case let .downloadFailed(msg): return "下载失败：\(msg)"
        }
    }
}

/// 登录后的 Cookie 保存在 ~/Library/Application Support/BiliDownloader/cookies.json（权限 600），
/// 图形界面和命令行共用同一份。
public struct CookieStore: Sendable {
    public let fileURL: URL

    public static let shared = CookieStore(fileURL: AppPaths.supportDir.appendingPathComponent("cookies.json"))

    public func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    public func save(_ cookies: [String: String]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".cookies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                            attributes: [.posixPermissions: 0o600]) else { return }
        // 同目录原子替换，避免进程中断留下半份 Cookie；同时修复旧文件的宽松权限。
        _ = rename(temporary.path, fileURL.path)
    }
}

public enum AppPaths {
    public static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BiliDownloader", isDirectory: true)
    }
}

public final class BiliClient: @unchecked Sendable {
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    public static let referer = "https://www.bilibili.com/"

    public let session: URLSession
    public let store: CookieStore
    private let lock = NSLock()
    private var cookies: [String: String]
    private var mixinKey: String?
    private var mixinKeyDate = Date.distantPast

    public init(store: CookieStore = .shared, configuration: URLSessionConfiguration = .default) {
        let cfg = configuration
        // Cookie 由我们自己管理，避免和系统共享存储互相污染
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: CookieRedirectGuard(), delegateQueue: nil)
        self.store = store
        cookies = store.load()
    }

    // MARK: Cookie

    public var isLoggedIn: Bool { cookie("SESSDATA") != nil }

    public func cookie(_ name: String) -> String? {
        lock.withLock { cookies[name] }
    }

    public func setCookies(_ new: [String: String]) {
        lock.withLock {
            cookies.merge(new) { _, b in b }
            store.save(cookies)
        }
    }

    public func logout() {
        lock.withLock {
            for k in ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"] { cookies[k] = nil }
            store.save(cookies)
        }
    }

    private var cookieHeader: String {
        lock.withLock { cookies.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ") }
    }

    // MARK: 请求

    public func request(_ url: URL, withCookies: Bool = true) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(Self.referer, forHTTPHeaderField: "Referer")
        r.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        if withCookies && Self.canSendCookies(to: url) {
            let c = cookieHeader
            if !c.isEmpty { r.setValue(c, forHTTPHeaderField: "Cookie") }
        }
        return r
    }

    static func canSendCookies(to url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "bilibili.com" || host.hasSuffix(".bilibili.com")
    }

    public func fetch(_ url: URL, withCookies: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request(url, withCookies: withCookies))
        guard let http = resp as? HTTPURLResponse else { throw BiliError.http(-1) }
        return (data, http)
    }

    /// GET 一个返回 {code, message, data/result} 的接口，code 非 0 时抛错。
    public func getJSON(_ base: String, _ params: [String: String] = [:], wbi: Bool = false,
                        allowCodes: Set<Int> = []) async throws -> JSON {
        try await ensureBuvid()
        var p = params
        if wbi { p = try await wbiSign(p) }
        let urlString = p.isEmpty ? base : base + "?" + Self.query(p)
        guard let url = URL(string: urlString) else { throw BiliError.invalidInput("无效地址 \(urlString)") }
        let watch = Stopwatch()
        let path = url.path
        let (data, resp) = try await fetch(url)
        guard resp.statusCode == 200 else {
            Log.warn("API \(path) HTTP \(resp.statusCode)（\(watch.text)）")
            throw BiliError.http(resp.statusCode)
        }
        let json = try JSON(data: data)
        let code = json["code"].int ?? -1
        if code != 0 && !allowCodes.contains(code) {
            Log.warn("API \(path) code=\(code) \(json["message"].string ?? "")（\(watch.text)）")
            throw BiliError.api(code, json["message"].string ?? "")
        }
        Log.debug("API \(path) code=\(code) \(formatBytes(Double(data.count)))（\(watch.text)）")
        return json
    }

    /// 没有 buvid3 时很容易被风控，先向 B 站要一个。
    private func ensureBuvid() async throws {
        if cookie("buvid3") != nil { return }
        guard let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") else { return }
        if let (data, _) = try? await fetch(url, withCookies: false), let json = try? JSON(data: data),
           let b3 = json["data"]["b_3"].string {
            var c = ["buvid3": b3, "b_nut": String(Int(Date().timeIntervalSince1970))]
            if let b4 = json["data"]["b_4"].string { c["buvid4"] = b4 }
            setCookies(c)
        }
    }

    // MARK: WBI 签名

    private static let mixinTable = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
        61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
        36, 20, 34, 44, 52,
    ]

    private func currentMixinKey() async throws -> String {
        if let key = lock.withLock({ Date().timeIntervalSince(mixinKeyDate) < 1800 ? mixinKey : nil }) {
            return key
        }
        let nav = try await getJSON("https://api.bilibili.com/x/web-interface/nav", allowCodes: [-101])
        func stem(_ s: String?) -> String {
            guard let s, let u = URL(string: s) else { return "" }
            return u.deletingPathExtension().lastPathComponent
        }
        let raw = Array(stem(nav["data"]["wbi_img"]["img_url"].string) + stem(nav["data"]["wbi_img"]["sub_url"].string))
        guard raw.count >= 64 else { throw BiliError.invalidInput("获取 WBI 密钥失败") }
        let key = String(Self.mixinTable.prefix(32).map { raw[$0] })
        lock.withLock {
            mixinKey = key
            mixinKeyDate = Date()
        }
        return key
    }

    func wbiSign(_ params: [String: String]) async throws -> [String: String] {
        let key = try await currentMixinKey()
        var p = params
        p["wts"] = String(Int(Date().timeIntervalSince1970))
        let banned = Set("!'()*")
        for (k, v) in p { p[k] = String(v.filter { !banned.contains($0) }) }
        let digest = Insecure.MD5.hash(data: Data((Self.query(p) + key).utf8))
        p["w_rid"] = digest.map { String(format: "%02x", $0) }.joined()
        return p
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func query(_ p: [String: String]) -> String {
        p.keys.sorted().map { "\(encode($0))=\(encode(p[$0]!))" }.joined(separator: "&")
    }
}

private final class CookieRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if redirected.url.map(BiliClient.canSendCookies(to:)) != true {
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(redirected)
    }
}
