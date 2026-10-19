import CoreImage
import Foundation

public struct Account: Sendable {
    public var mid: Int
    public var name: String
    public var face: String
    public var isVip: Bool
    public var vipLabel: String
}

public enum QRLoginState: Sendable, Equatable {
    case waiting, scanned, expired, success
}

public extension BiliClient {
    func account() async throws -> Account? {
        let j = try await getJSON("https://api.bilibili.com/x/web-interface/nav", allowCodes: [-101])
        let d = j["data"]
        guard d["isLogin"].bool == true else { return nil }
        return Account(mid: d["mid"].int ?? 0, name: d["uname"].string ?? "", face: d["face"].string ?? "",
                       isVip: (d["vipStatus"].int ?? 0) == 1,
                       vipLabel: d["vip_label"]["text"].string ?? "")
    }

    /// 申请登录二维码，返回 (二维码内容, key)
    func qrGenerate() async throws -> (url: String, key: String) {
        let d = try await getJSON("https://passport.bilibili.com/x/passport-login/web/qrcode/generate")["data"]
        guard let url = d["url"].string, let key = d["qrcode_key"].string else {
            throw BiliError.invalidInput("获取登录二维码失败")
        }
        return (url, key)
    }

    func qrPoll(key: String) async throws -> QRLoginState {
        var comps = URLComponents(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll")!
        comps.queryItems = [URLQueryItem(name: "qrcode_key", value: key)]
        let (data, resp) = try await fetch(comps.url!)
        let d = try JSON(data: data)["data"]
        switch d["code"].int {
        case 0:
            var got: [String: String] = [:]
            // 优先取 Set-Cookie，退而求其次解析跳转链接里的参数（保持原始编码）
            if let fields = resp.allHeaderFields as? [String: String] {
                for c in HTTPCookie.cookies(withResponseHeaderFields: fields, for: comps.url!) {
                    got[c.name] = c.value
                }
            }
            if got["SESSDATA"] == nil, let url = d["url"].string, let q = url.split(separator: "?", maxSplits: 1).last {
                for pair in q.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 { got[String(kv[0])] = String(kv[1]) }
                }
                got["gourl"] = nil
                got["first_domain"] = nil
                got["Expires"] = nil
            }
            guard got["SESSDATA"] != nil else { throw BiliError.invalidInput("登录成功但未拿到 Cookie") }
            setCookies(got)
            return .success
        case 86090: return .scanned
        case 86038: return .expired
        default: return .waiting
        }
    }
}

public enum QRCode {
    /// 生成二维码模块矩阵（true = 黑）
    public static func matrix(_ text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let img = filter.outputImage else { return nil }
        let w = Int(img.extent.width), h = Int(img.extent.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CIContext()
        ctx.render(img, toBitmap: &pixels, rowBytes: w * 4, bounds: img.extent, format: .RGBA8, colorSpace: nil)
        return (0 ..< h).map { y in (0 ..< w).map { x in pixels[(y * w + x) * 4] < 128 } }
    }

    public static func ciImage(_ text: String) -> CIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        return filter.outputImage
    }

    /// 终端里用半格字符画二维码
    public static func terminal(_ text: String) -> String {
        guard let m = matrix(text) else { return text }
        let size = m.count
        let pad = 2
        func dark(_ x: Int, _ y: Int) -> Bool {
            let xx = x - pad, yy = y - pad
            guard xx >= 0, yy >= 0, xx < size, yy < size else { return false }
            return m[yy][xx]
        }
        var out = ""
        let total = size + pad * 2
        for y in stride(from: 0, to: total, by: 2) {
            for x in 0 ..< total {
                switch (dark(x, y), dark(x, y + 1)) {
                case (false, false): out += "█"
                case (true, false): out += "▄"
                case (false, true): out += "▀"
                case (true, true): out += " "
                }
            }
            out += "\n"
        }
        return out
    }
}
