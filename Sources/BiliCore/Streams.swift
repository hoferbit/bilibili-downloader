import Foundation

public enum VideoCodec: String, Codable, CaseIterable, Sendable, Identifiable {
    case avc, hevc, av1
    public var id: String { rawValue }
    public var codecId: Int { switch self { case .avc: 7; case .hevc: 12; case .av1: 13 } }
    public var label: String { switch self { case .avc: "H.264 (AVC)"; case .hevc: "H.265 (HEVC)"; case .av1: "AV1" } }
    public static func from(codecId: Int) -> VideoCodec? { allCases.first { $0.codecId == codecId } }
}

public enum Quality {
    public static let all: [(qn: Int, name: String)] = [
        (127, "8K 超高清"), (126, "杜比视界"), (125, "HDR 真彩"), (120, "4K 超清"),
        (116, "1080P 60帧"), (112, "1080P 高码率"), (80, "1080P 高清"), (74, "720P 60帧"),
        (64, "720P 高清"), (32, "480P 清晰"), (16, "360P 流畅"),
    ]
    /// 只有明确选择时才会用到的特殊格式
    static let special: Set<Int> = [125, 126, 127]

    public static func name(_ qn: Int) -> String {
        all.first { $0.qn == qn }?.name ?? "清晰度 \(qn)"
    }
}

public struct StreamInfo: Sendable {
    public var videoURLs: [String]
    public var audioURLs: [String]?
    public var audioId: Int = 0
    public var needsDecodeValidation: Bool = false
    /// 老式 FLV/MP4 分段（极少数视频没有 DASH）
    public var segments: [[String]]?
    public var qn: Int
    public var codec: VideoCodec?
    public var width: Int
    public var height: Int
    public var fps: Double
    public var videoBandwidth: Int
    public var durationMs: Int
    public var available: [Int]

    public var qualityName: String { Quality.name(qn) }

    /// 不包含会过期的签名查询参数；更换流时必须丢弃旧下载和合并缓存。
    var cacheIdentity: String {
        let paths = ([videoURLs] + [audioURLs ?? []] + (segments ?? []))
            .map { $0.first.flatMap { URL(string: $0)?.path } ?? "" }
        return shortHash("\(qn)|\(codec?.rawValue ?? "")|\(audioId)|\(videoBandwidth)|\(width)x\(height)|\(fps)|\(durationMs)|\(paths)")
    }

    public var summary: String {
        var parts = [qualityName]
        if let codec { parts.append(codec == .avc ? "AVC" : codec == .hevc ? "HEVC" : "AV1") }
        if width > 0 { parts.append("\(width)×\(height)") }
        if fps > 0 { parts.append("\(Int(fps.rounded()))fps") }
        return parts.joined(separator: " · ")
    }
}

/// 优先走主 CDN，PCDN（mcdn）节点放到最后，稳定性更好
private func orderedURLs(_ json: JSON) -> [String] {
    let urls = [json["baseUrl"].string ?? json["base_url"].string]
        .compactMap { $0 } + (json["backupUrl"].isNull ? json["backup_url"] : json["backupUrl"]).stringArray
    let main = urls.filter { !$0.contains("mcdn") && !$0.contains(":8082") }
    let pcdn = urls.filter { $0.contains("mcdn") || $0.contains(":8082") }
    return main + pcdn
}

public extension BiliClient {
    func streams(for e: VideoEntry, quality: Int, codec: VideoCodec, prefer60: Bool,
                 targetMaxDimension: Int? = nil, tag: String? = nil) async throws -> StreamInfo {
        let requestedQN = targetMaxDimension.map { edge in
            [(16, 640), (32, 854), (64, 1280), (80, 1920)].min { abs($0.1 - edge) < abs($1.1 - edge) }!.0
        } ?? 127
        let data: JSON
        if let ep = e.epid {
            data = try await getJSON("https://api.bilibili.com/pgc/player/web/playurl",
                                     ["ep_id": String(ep), "cid": String(e.cid), "qn": String(requestedQN),
                                      "fnval": "4048", "fnver": "0", "fourk": "1"])["result"]
        } else {
            var p = ["cid": String(e.cid), "qn": String(requestedQN), "fnval": "4048", "fnver": "0", "fourk": "1",
                     "web_location": "1315873"]
            if e.bvid.isEmpty { p["avid"] = String(e.aid) } else { p["bvid"] = e.bvid }
            data = try await getJSON("https://api.bilibili.com/x/player/wbi/playurl", p, wbi: true)["data"]
        }
        try validateFullPlayback(data)
        let durationMs = data["timelength"].int ?? e.duration * 1000
        let dash = data["dash"]

        if dash.isNull {
            let durl = data["durl"].array
            guard !durl.isEmpty else { throw BiliError.noStream("接口未返回播放地址（可能需要大会员或已下架）") }
            Log.info("无 DASH，使用 \(durl.count) 段 durl，清晰度 \(Quality.name(data["quality"].int ?? 0))", tag: tag)
            let segs = durl.map { d in [d["url"].string].compactMap { $0 } + d["backup_url"].stringArray }
            return StreamInfo(videoURLs: [], audioURLs: nil, segments: segs, qn: data["quality"].int ?? 0,
                              codec: nil, width: 0, height: 0, fps: 0, videoBandwidth: 0,
                              durationMs: durationMs, available: data["accept_quality"].array.compactMap(\.int))
        }

        let videos = dash["video"].array.filter { !streamIsEncrypted($0) }
        guard !videos.isEmpty else { throw BiliError.noStream("没有视频轨") }
        let ids = Set(videos.compactMap { $0["id"].int })

        // 选清晰度：不超过设定值的最高档；有 60 帧同分辨率版本时优先（1080P60 需要大会员）
        var target: Int
        if let edge = targetMaxDimension, let nearest = nearestShareQuality(videos, maxDimension: edge) {
            target = nearest
            Log.info("微信分享目标最长边 \(edge)px，选择最接近的可用源：\(Quality.name(target))", tag: tag)
        } else if prefer60 && quality == 80 && ids.contains(116) {
            target = 116
        } else if prefer60 && quality == 64 && ids.contains(74) {
            target = 74
        } else if ids.contains(quality) {
            target = quality
        } else {
            let normal = ids.filter { !Quality.special.contains($0) }
            target = normal.filter { $0 <= quality }.max() ?? normal.min() ?? ids.min()!
        }
        if !ids.contains(target) { target = ids.max()! }

        let sameQuality = videos.filter { $0["id"].int == target }
        let order = [codec] + VideoCodec.allCases.filter { $0 != codec }
        var picked = sameQuality[0]
        for c in order {
            if let v = sameQuality.first(where: { $0["codecid"].int == c.codecId }) { picked = v; break }
        }

        var audioURLs: [String]?
        var audioId = 0
        let audios = dash["audio"].array.filter { !streamIsEncrypted($0) }.sorted { ($0["bandwidth"].int ?? 0) > ($1["bandwidth"].int ?? 0) }
        if let a = audios.first {
            audioURLs = orderedURLs(a)
            audioId = a["id"].int ?? a["bandwidth"].int ?? 0
        }

        let fpsString = picked["frameRate"].string ?? picked["frame_rate"].string ?? "0"
        var fps = Double(fpsString) ?? 0
        if fpsString.contains("/") {
            let parts = fpsString.split(separator: "/").compactMap { Double($0) }
            if parts.count == 2, parts[1] > 0 { fps = parts[0] / parts[1] }
        }
        let available = (data["accept_quality"].array.compactMap(\.int)).filter { ids.contains($0) }

        // 把所有候选流都记下来，方便以后调整选择策略
        let variants = videos.map { v in
            "\(v["id"].int ?? 0)/\(VideoCodec.from(codecId: v["codecid"].int ?? 0)?.rawValue ?? "?")/"
                + "\(v["width"].int ?? 0)x\(v["height"].int ?? 0)@\(v["frameRate"].string ?? v["frame_rate"].string ?? "?")/"
                + "\((v["bandwidth"].int ?? 0) / 1000)k"
        }
        let hosts = Set(orderedURLs(picked).compactMap { URL(string: $0)?.host }).sorted()
        Log.info("接口可选清晰度 \(data["accept_quality"].array.compactMap(\.int))，实际有流 \(ids.sorted(by: >))；"
            + "设定 \(quality)\(prefer60 ? "（优先60帧）" : "")/\(codec.rawValue) → 选中 \(target)/"
            + "\(VideoCodec.from(codecId: picked["codecid"].int ?? 0)?.rawValue ?? "?") "
            + "\(picked["width"].int ?? 0)x\(picked["height"].int ?? 0)@\(fpsString) \((picked["bandwidth"].int ?? 0) / 1000)kbps；"
            + "音频 \(audios.first.map { "\(($0["bandwidth"].int ?? 0) / 1000)kbps" } ?? "无")；时长 \(durationMs / 1000)s；"
            + "CDN \(hosts.joined(separator: ", "))", tag: tag)
        Log.debug("全部视频流: \(variants.joined(separator: "  "))", tag: tag)

        return StreamInfo(videoURLs: orderedURLs(picked), audioURLs: audioURLs, audioId: audioId, needsDecodeValidation: data["is_drm"].bool == true || data["is_drm"].int == 1, segments: nil, qn: target,
                          codec: VideoCodec.from(codecId: picked["codecid"].int ?? 0),
                          width: picked["width"].int ?? 0, height: picked["height"].int ?? 0, fps: fps,
                          videoBandwidth: picked["bandwidth"].int ?? 0, durationMs: durationMs,
                          available: available.isEmpty ? ids.sorted(by: >) : available)
    }
}

func nearestShareQuality(_ videos: [JSON], maxDimension: Int) -> Int? {
    videos.filter {
        guard let qn = $0["id"].int else { return false }
        return !Quality.special.contains(qn) && !streamIsEncrypted($0)
            && max($0["width"].int ?? 0, $0["height"].int ?? 0) > 0
    }.min { a, b in
        let edgeA = max(a["width"].int ?? 0, a["height"].int ?? 0)
        let edgeB = max(b["width"].int ?? 0, b["height"].int ?? 0)
        let distanceA = abs(edgeA - maxDimension), distanceB = abs(edgeB - maxDimension)
        if distanceA != distanceB { return distanceA < distanceB }
        // 同尺寸优先普通低码率档，不为分享下载 60fps/高码率原片。
        return (a["id"].int ?? 0) < (b["id"].int ?? 0)
    }?["id"].int
}

/// 不把试看或加密流误当成完整下载结果。
func validateFullPlayback(_ data: JSON) throws {
    if data["is_preview"].bool == true || data["is_preview"].int == 1 {
        throw BiliError.noStream("接口仅提供试看内容，请先确认账号拥有完整观看权限")
    }
    if data["is_drm"].bool == true || data["is_drm"].int == 1 {
        // is_drm 是响应总标记，不足以证明每一条流都已加密（实测 ep248180 可直接解码）。
        let candidates = data["dash"]["video"].array
        guard candidates.contains(where: { !streamIsEncrypted($0) && !(($0["baseUrl"].string ?? $0["base_url"].string) ?? "").isEmpty }) else {
            throw BiliError.noStream("该响应未提供可验证的普通视频流，当前不支持加密视频")
        }
    }
}

func streamIsEncrypted(_ stream: JSON) -> Bool {
    (stream["drm_tech_type"].int ?? 0) > 0
        || !(stream["drm_key_id"].string ?? "").isEmpty
        || !(stream["widevine_pssh"].string ?? "").isEmpty
}
