import Foundation

public struct DanmakuComment: Sendable {
    public var id: Int64
    /// 出现时间（秒）
    public var time: Double
    /// 1/2/3 滚动，4 底部，5 顶部，6 逆向，7 高级，8 代码，9 BAS
    public var mode: Int
    public var fontSize: Int
    public var color: Int
    public var midHash: String
    public var content: String
    public var ctime: Int64
    public var weight: Int
    public var pool: Int
}

/// 极简 protobuf 读取器，只够解析弹幕分段（DmSegMobileReply）。
private struct ProtoReader {
    let bytes: [UInt8]
    var pos: Int
    let end: Int

    init(_ bytes: [UInt8], range: Range<Int>? = nil) {
        self.bytes = bytes
        pos = range?.lowerBound ?? 0
        end = range?.upperBound ?? bytes.count
    }

    var atEnd: Bool { pos >= end }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < end {
            let b = bytes[pos]
            pos += 1
            guard shift < 63 || b <= 1 else { throw BiliError.invalidInput("弹幕数据格式错误") }
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { break }
        }
        throw BiliError.invalidInput("弹幕数据格式错误")
    }

    mutating func lengthDelimited() throws -> Range<Int> {
        guard let len = Int(exactly: try varint()), len <= end - pos else {
            throw BiliError.invalidInput("弹幕数据格式错误")
        }
        defer { pos += len }
        return pos ..< pos + len
    }

    mutating func skip(wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: pos += 8
        case 2: _ = try lengthDelimited()
        case 5: pos += 4
        default: throw BiliError.invalidInput("弹幕数据格式错误")
        }
        guard pos <= end else { throw BiliError.invalidInput("弹幕数据格式错误") }
    }
}

func parseSegment(_ data: Data) throws -> [DanmakuComment] {
    let bytes = [UInt8](data)
    var reader = ProtoReader(bytes)
    var out: [DanmakuComment] = []
    while !reader.atEnd {
        let key = try reader.varint()
        let field = Int(key >> 3), wire = Int(key & 7)
        guard field == 1, wire == 2 else { try reader.skip(wire: wire); continue }
        let range = try reader.lengthDelimited()
        var r = ProtoReader(bytes, range: range)
        var c = DanmakuComment(id: 0, time: 0, mode: 1, fontSize: 25, color: 0xFFFFFF, midHash: "",
                               content: "", ctime: 0, weight: 0, pool: 0)
        while !r.atEnd {
            let k = try r.varint()
            let f = Int(k >> 3), w = Int(k & 7)
            switch (f, w) {
            case (1, 0): c.id = Int64(bitPattern: try r.varint())
            case (2, 0): c.time = Double(Int32(truncatingIfNeeded: try r.varint())) / 1000
            case (3, 0): c.mode = Int(Int32(truncatingIfNeeded: try r.varint()))
            case (4, 0): c.fontSize = Int(Int32(truncatingIfNeeded: try r.varint()))
            case (5, 0): c.color = Int(try r.varint() & 0xFFFFFF)
            case (6, 2): c.midHash = String(decoding: bytes[try r.lengthDelimited()], as: UTF8.self)
            case (7, 2): c.content = String(decoding: bytes[try r.lengthDelimited()], as: UTF8.self)
            case (8, 0): c.ctime = Int64(bitPattern: try r.varint())
            case (9, 0): c.weight = Int(Int32(truncatingIfNeeded: try r.varint()))
            case (11, 0): c.pool = Int(Int32(truncatingIfNeeded: try r.varint()))
            default: try r.skip(wire: w)
            }
        }
        if !c.content.isEmpty { out.append(c) }
    }
    return out
}

public extension BiliClient {
    /// 通过分段接口获取全量弹幕（每段 6 分钟），比 XML 接口的 1000~8000 条上限更完整。
    func danmaku(cid: Int, aid: Int, duration: Double, tag: String? = nil) async throws -> [DanmakuComment] {
        let segments = max(1, Int((duration / 360).rounded(.up)))
        let watch = Stopwatch()
        var all: [DanmakuComment] = []
        var failures = 0
        // 每次并发 4 段，避免请求过猛
        for batchStart in stride(from: 1, through: segments, by: 4) {
            let batch = batchStart ... min(segments, batchStart + 3)
            try await withThrowingTaskGroup(of: [DanmakuComment]?.self) { group in
                for idx in batch {
                    group.addTask {
                        var comps = URLComponents(string: "https://api.bilibili.com/x/v2/dm/web/seg.so")!
                        comps.queryItems = [
                            .init(name: "type", value: "1"), .init(name: "oid", value: String(cid)),
                            .init(name: "pid", value: String(aid)), .init(name: "segment_index", value: String(idx)),
                        ]
                        for attempt in 0 ..< 3 {
                            if let (data, resp) = try? await self.fetch(comps.url!), resp.statusCode == 200,
                               let list = try? parseSegment(data) {
                                return list
                            }
                            try await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
                        }
                        return nil
                    }
                }
                for try await r in group {
                    if let r { all += r } else { failures += 1 }
                }
            }
        }
        if failures > 0 { Log.warn("弹幕分段 \(failures)/\(segments) 段获取失败", tag: tag) }
        if failures == segments {
            Log.warn("分段接口全部失败，改用 XML 接口", tag: tag)
            all = try await danmakuXML(cid: cid)
        }
        // 同一条弹幕可能出现在相邻分段里
        var seen = Set<Int64>()
        let result = all.filter { $0.id == 0 || seen.insert($0.id).inserted }.sorted { $0.time < $1.time }
        var modes: [Int: Int] = [:]
        for c in result { modes[c.mode, default: 0] += 1 }
        Log.info("弹幕 \(result.count) 条（\(segments) 段，用时 \(watch.text)），按类型: "
            + modes.sorted { $0.key < $1.key }.map { "mode\($0.key)=\($0.value)" }.joined(separator: " "), tag: tag)
        return result
    }

    /// 备用：老的 XML 接口
    private func danmakuXML(cid: Int) async throws -> [DanmakuComment] {
        let (data, _) = try await fetch(URL(string: "https://comment.bilibili.com/\(cid).xml")!)
        let xml = String(decoding: data, as: UTF8.self)
        let re = try NSRegularExpression(pattern: #"<d p="([^"]*)">([^<]*)</d>"#)
        return re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { m in
            guard let pr = Range(m.range(at: 1), in: xml), let tr = Range(m.range(at: 2), in: xml) else { return nil }
            let p = xml[pr].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 8 else { return nil }
            return DanmakuComment(id: Int64(p[7]) ?? 0, time: Double(p[0]) ?? 0, mode: Int(p[1]) ?? 1,
                                  fontSize: Int(p[2]) ?? 25, color: Int(p[3]) ?? 0xFFFFFF, midHash: p[6],
                                  content: xmlUnescape(String(xml[tr])), ctime: Int64(p[4]) ?? 0,
                                  weight: p.count > 8 ? Int(p[8]) ?? 0 : 0, pool: Int(p[5]) ?? 0)
        }
    }
}

private func xmlUnescape(_ s: String) -> String {
    s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
}

private func xmlEscape(_ s: String) -> String {
    let cleaned = s.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }
    return String(String.UnicodeScalarView(cleaned))
        .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

public enum DanmakuXML {
    /// 输出与 B 站兼容的 XML，可被弹弹play、IINA 插件等识别
    public static func make(_ comments: [DanmakuComment], cid: Int) -> String {
        var s = #"<?xml version="1.0" encoding="UTF-8"?><i><chatserver>chat.bilibili.com</chatserver>"#
        s += "<chatid>\(cid)</chatid><mission>0</mission><maxlimit>\(comments.count)</maxlimit><state>0</state><real_name>0</real_name><source>k-v</source>\n"
        for c in comments {
            s += "<d p=\"\(String(format: "%.5f", c.time)),\(c.mode),\(c.fontSize),\(c.color),\(c.ctime),\(c.pool),\(xmlEscape(c.midHash)),\(c.id),\(c.weight)\">\(xmlEscape(c.content))</d>\n"
        }
        return s + "</i>\n"
    }
}
