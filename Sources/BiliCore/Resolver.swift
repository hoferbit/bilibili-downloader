import Foundation

public enum ListKind: String, Sendable {
    case video = "视频"
    case multiPart = "多P视频"
    case season = "合集"
    case series = "系列"
    case favorites = "收藏夹"
    case uploads = "UP主投稿"
    case bangumi = "番剧/影视"
}

/// 一个待下载的视频分P。cid 为 0 表示还需在下载前用 view 接口补全（收藏夹、系列等列表接口不返回 cid）。
public struct VideoEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var aid: Int
    public var bvid: String
    public var cid: Int
    public var epid: Int?
    public var title: String
    public var fileName: String
    public var folder: String?
    public var duration: Int
    public var defaultSelected: Bool

    public init(aid: Int, bvid: String, cid: Int, epid: Int? = nil, page: Int = 1, title: String,
                fileName: String? = nil, folder: String? = nil, duration: Int = 0, defaultSelected: Bool = true) {
        id = "\(bvid.isEmpty ? "av\(aid)" : bvid)#\(cid)#\(epid ?? 0)#\(page)"
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.epid = epid
        self.title = title
        self.fileName = fileName ?? title
        self.folder = folder
        self.duration = duration
        self.defaultSelected = defaultSelected
    }
}

public struct SeasonRef: Sendable, Hashable {
    public var mid: Int
    public var id: Int
    public var title: String
    public var count: Int
}

public struct ParsedList: Sendable {
    public var title: String
    public var kind: ListKind
    public var entries: [VideoEntry]
    /// 单个视频所属的合集，界面上可以一键展开
    public var season: SeasonRef?
}

private func firstMatch(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

/// 给列表条目按序号编号，位数随总数变化（01、001…）
private func numbered(_ entries: [VideoEntry], folder: String) -> [VideoEntry] {
    let width = max(2, String(entries.count).count)
    return entries.enumerated().map { i, e in
        var e = e
        e.fileName = String(format: "%0\(width)d ", i + 1) + e.fileName
        e.folder = folder
        return e
    }
}

public extension BiliClient {
    /// 解析用户输入：视频链接、BV/av 号、b23 短链、合集、系列、收藏夹、番剧、UP 主空间。
    func parse(_ input: String) async throws -> ParsedList {
        let watch = Stopwatch()
        do {
            let r = try await parseInput(input)
            let unresolved = r.entries.filter { $0.cid == 0 }.count
            Log.info("解析「\(input.prefix(200))」→ \(r.kind.rawValue)《\(r.title)》\(r.entries.count) 项，"
                + "默认选中 \(r.entries.filter(\.defaultSelected).count)\(unresolved > 0 ? "，\(unresolved) 项待补全 cid" : "")"
                + "\(r.season.map { "，所属合集 \($0.title)(\($0.count))" } ?? "")，用时 \(watch.text)")
            return r
        } catch {
            Log.error("解析「\(input.prefix(200))」失败（\(watch.text)）：\(error.localizedDescription)")
            throw error
        }
    }

    private func parseInput(_ input: String) async throws -> ParsedList {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 支持直接粘贴 App 里的分享文案：「【标题】 https://b23.tv/xxxx」
        if let url = firstMatch(#"(https?://[^\s，。]+)"#, in: text) { text = url }
        if text.contains("b23.tv") || text.contains("bili2233.cn") {
            text = try await resolveShortLink(text)
        }

        if let midStr = firstMatch(#"space\.bilibili\.com/(\d+)"#, in: text), let mid = Int(midStr) {
            if let fid = firstMatch(#"[?&]fid=(\d+)"#, in: text).flatMap(Int.init) {
                return try await favorites(mediaId: fid)
            }
            if let sid = firstMatch(#"collectiondetail\?sid=(\d+)"#, in: text).flatMap(Int.init) {
                return try await season(mid: mid, seasonId: sid)
            }
            if let sid = firstMatch(#"seriesdetail\?sid=(\d+)"#, in: text).flatMap(Int.init) {
                return try await series(mid: mid, seriesId: sid)
            }
            if let sid = firstMatch(#"/lists/(\d+)"#, in: text).flatMap(Int.init) {
                return text.contains("type=series")
                    ? try await series(mid: mid, seriesId: sid)
                    : try await season(mid: mid, seasonId: sid)
            }
            if text.contains("favlist") {
                throw BiliError.invalidInput("请打开具体的收藏夹后再复制链接（链接里需要带 fid=）")
            }
            return try await uploads(mid: mid)
        }
        if let ml = firstMatch(#"ml(\d+)"#, in: text).flatMap(Int.init), text.contains("medialist") || text.contains("/list/ml") {
            return try await favorites(mediaId: ml)
        }

        let isBangumi = text.contains("bangumi") || text.range(of: #"^(ep|ss|md)\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        if isBangumi {
            if let ep = firstMatch(#"ep(\d+)"#, in: text, options: .caseInsensitive).flatMap(Int.init) {
                return try await bangumi(epid: ep, seasonId: nil)
            }
            if let ss = firstMatch(#"ss(\d+)"#, in: text, options: .caseInsensitive).flatMap(Int.init) {
                return try await bangumi(epid: nil, seasonId: ss)
            }
            if let md = firstMatch(#"md(\d+)"#, in: text, options: .caseInsensitive) {
                let r = try await getJSON("https://api.bilibili.com/pgc/review/user", ["media_id": md])
                guard let ss = r["result"]["media"]["season_id"].int else { throw BiliError.invalidInput("找不到该番剧") }
                return try await bangumi(epid: nil, seasonId: ss)
            }
        }

        let page = firstMatch(#"[?&]p=(\d+)"#, in: text).flatMap(Int.init)
        if let bv = firstMatch(#"(BV[0-9A-Za-z]{10})"#, in: text) {
            return try await video(params: ["bvid": bv], page: page)
        }
        if let av = firstMatch(#"(?:^|[^A-Za-z])av(\d+)"#, in: text, options: .caseInsensitive) {
            return try await video(params: ["aid": av], page: page)
        }
        throw BiliError.invalidInput("无法识别的链接：\(input)")
    }

    private func resolveShortLink(_ link: String) async throws -> String {
        guard let url = URL(string: link) else { throw BiliError.invalidInput("无效短链") }
        let (_, resp) = try await fetch(url, withCookies: false)
        return resp.url?.absoluteString ?? link
    }

    // MARK: 普通视频 / 多P

    func video(params: [String: String], page: Int?) async throws -> ParsedList {
        let d = try await getJSON("https://api.bilibili.com/x/web-interface/view", params)["data"]
        let title = d["title"].string ?? "未命名"
        let aid = d["aid"].int ?? 0
        let bvid = d["bvid"].string ?? ""
        let pages = d["pages"].array
        var entries: [VideoEntry] = []
        if pages.count <= 1 {
            entries.append(VideoEntry(aid: aid, bvid: bvid, cid: d["cid"].int ?? pages.first?["cid"].int ?? 0,
                                      title: title, duration: d["duration"].int ?? 0))
        } else {
            let width = max(2, String(pages.count).count)
            for p in pages {
                let n = p["page"].int ?? 1
                let part = p["part"].string ?? ""
                entries.append(VideoEntry(aid: aid, bvid: bvid, cid: p["cid"].int ?? 0, page: n,
                                          title: "P\(n) \(part)",
                                          fileName: "P" + String(format: "%0\(width)d", n) + " \(part)",
                                          folder: title, duration: p["duration"].int ?? 0,
                                          defaultSelected: page == nil || page == n))
            }
        }
        var season: SeasonRef?
        let s = d["ugc_season"]
        if let sid = s["id"].int, let mid = s["mid"].int {
            season = SeasonRef(mid: mid, id: sid, title: s["title"].string ?? "合集", count: s["ep_count"].int ?? 0)
        }
        return ParsedList(title: title, kind: pages.count > 1 ? .multiPart : .video, entries: entries, season: season)
    }

    /// 把 cid 为 0 的条目补全；多P视频会展开成多个条目。
    func expand(_ e: VideoEntry) async throws -> [VideoEntry] {
        let params = e.bvid.isEmpty ? ["aid": String(e.aid)] : ["bvid": e.bvid]
        let d = try await getJSON("https://api.bilibili.com/x/web-interface/view", params)["data"]
        let pages = d["pages"].array
        if pages.count <= 1 {
            var e = e
            e.cid = d["cid"].int ?? pages.first?["cid"].int ?? 0
            if e.duration == 0 { e.duration = d["duration"].int ?? 0 }
            return [e]
        }
        let width = max(2, String(pages.count).count)
        return pages.map { p in
            let n = p["page"].int ?? 1
            let part = p["part"].string ?? ""
            return VideoEntry(aid: e.aid, bvid: e.bvid, cid: p["cid"].int ?? 0, page: n,
                              title: "\(e.title) - P\(n) \(part)",
                              fileName: "\(e.fileName) - P" + String(format: "%0\(width)d", n) + " \(part)",
                              folder: e.folder, duration: p["duration"].int ?? 0)
        }
    }

    // MARK: 合集

    func season(mid: Int, seasonId: Int) async throws -> ParsedList {
        // 列表接口不带 cid，取第一集的 view，其中 ugc_season 含全部剧集和 cid
        let list = try await getJSON("https://api.bilibili.com/x/polymer/web-space/seasons_archives_list",
                                     ["mid": String(mid), "season_id": String(seasonId),
                                      "page_num": "1", "page_size": "1"])
        guard let bvid = list["data"]["archives"][0]["bvid"].string else {
            throw BiliError.invalidInput("合集为空或不可见")
        }
        let d = try await getJSON("https://api.bilibili.com/x/web-interface/view", ["bvid": bvid])["data"]
        return seasonList(from: d["ugc_season"])
    }

    func seasonList(from s: JSON) -> ParsedList {
        let title = s["title"].string ?? "合集"
        var entries: [VideoEntry] = []
        for section in s["sections"].array {
            for ep in section["episodes"].array {
                let aid = ep["aid"].int ?? 0
                let bvid = ep["bvid"].string ?? ""
                let epTitle = ep["title"].string ?? bvid
                let pages = ep["pages"].array
                if pages.count > 1 {
                    for p in pages {
                        let n = p["page"].int ?? 1
                        let part = p["part"].string ?? ""
                        entries.append(VideoEntry(aid: aid, bvid: bvid, cid: p["cid"].int ?? 0, page: n,
                                                  title: "\(epTitle) - P\(n) \(part)",
                                                  duration: p["duration"].int ?? 0))
                    }
                } else {
                    entries.append(VideoEntry(aid: aid, bvid: bvid, cid: ep["cid"].int ?? 0, title: epTitle,
                                              duration: ep["arc"]["duration"].int ?? ep["page"]["duration"].int ?? 0))
                }
            }
        }
        return ParsedList(title: title, kind: .season, entries: numbered(entries, folder: title), season: nil)
    }

    // MARK: 系列

    func series(mid: Int, seriesId: Int) async throws -> ParsedList {
        let meta = try? await getJSON("https://api.bilibili.com/x/series/series", ["series_id": String(seriesId)])
        let title = meta?["data"]["meta"]["name"].string ?? "系列 \(seriesId)"
        var entries: [VideoEntry] = []
        var pn = 1
        while true {
            let d = try await getJSON("https://api.bilibili.com/x/series/archives",
                                      ["mid": String(mid), "series_id": String(seriesId), "only_normal": "true",
                                       "sort": "asc", "pn": String(pn), "ps": "100"])["data"]
            let arcs = d["archives"].array
            for a in arcs {
                entries.append(VideoEntry(aid: a["aid"].int ?? 0, bvid: a["bvid"].string ?? "", cid: 0,
                                          title: a["title"].string ?? "", duration: a["duration"].int ?? 0))
            }
            let total = d["page"]["total"].int ?? 0
            if arcs.isEmpty || entries.count >= total { break }
            pn += 1
        }
        return ParsedList(title: title, kind: .series, entries: numbered(entries, folder: title), season: nil)
    }

    // MARK: 收藏夹

    func favorites(mediaId: Int) async throws -> ParsedList {
        let info = try await getJSON("https://api.bilibili.com/x/v3/fav/folder/info", ["media_id": String(mediaId)])
        let title = info["data"]["title"].string ?? "收藏夹 \(mediaId)"
        var entries: [VideoEntry] = []
        var pn = 1
        while true {
            let d = try await getJSON("https://api.bilibili.com/x/v3/fav/resource/list",
                                      ["media_id": String(mediaId), "pn": String(pn), "ps": "20",
                                       "platform": "web", "order": "mtime"])["data"]
            for m in d["medias"].array {
                // type 2 = 视频；跳过音频和已失效内容
                guard m["type"].int == 2, m["title"].string != "已失效视频" else { continue }
                let pages = m["page"].int ?? 1
                let cid = pages == 1 ? (m["ugc"]["first_cid"].int ?? 0) : 0
                entries.append(VideoEntry(aid: m["id"].int ?? 0, bvid: m["bvid"].string ?? "", cid: cid,
                                          title: m["title"].string ?? "", duration: m["duration"].int ?? 0))
            }
            if d["has_more"].bool != true { break }
            pn += 1
        }
        return ParsedList(title: title, kind: .favorites, entries: numbered(entries, folder: title), season: nil)
    }

    // MARK: UP 主投稿

    func uploads(mid: Int) async throws -> ParsedList {
        var entries: [VideoEntry] = []
        var author = "UP主 \(mid)"
        var pn = 1
        while true {
            let d = try await getJSON("https://api.bilibili.com/x/space/wbi/arc/search",
                                      ["mid": String(mid), "ps": "50", "pn": String(pn), "order": "pubdate",
                                       "platform": "web", "web_location": "1550101",
                                       "dm_img_list": "[]",
                                       "dm_img_str": "V2ViR0wgMS4wIChPcGVuR0wgRVMgMi4wIENocm9taXVtKQ",
                                       "dm_cover_img_str": "QU5HTEUgKEFwcGxlLCBBTkdMRSBNZXRhbCBSZW5kZXJlcjogQXBwbGUgTTEsIFVuc3BlY2lmaWVkIFZlcnNpb24pR29vZ2xlIEluYy4gKEFwcGxlKQ",
                                       "dm_img_inter": #"{"ds":[],"wh":[0,0,0],"of":[0,0,0]}"#],
                                      wbi: true)["data"]
            let list = d["list"]["vlist"].array
            for v in list {
                if let a = v["author"].string { author = a }
                entries.append(VideoEntry(aid: v["aid"].int ?? 0, bvid: v["bvid"].string ?? "", cid: 0,
                                          title: v["title"].string ?? ""))
            }
            let total = d["page"]["count"].int ?? 0
            if list.isEmpty || entries.count >= total { break }
            pn += 1
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let folder = "\(author) 的投稿"
        // 按发布时间从早到晚编号
        return ParsedList(title: folder, kind: .uploads, entries: numbered(entries.reversed(), folder: folder), season: nil)
    }

    // MARK: 番剧 / 影视

    func bangumi(epid: Int?, seasonId: Int?) async throws -> ParsedList {
        let params = epid.map { ["ep_id": String($0)] } ?? ["season_id": String(seasonId ?? 0)]
        let r = try await getJSON("https://api.bilibili.com/pgc/view/web/season", params)["result"]
        let title = r["season_title"].string ?? r["title"].string ?? "番剧"
        var entries: [VideoEntry] = []
        for ep in r["episodes"].array {
            let id = ep["id"].int ?? ep["ep_id"].int ?? 0
            let short = ep["title"].string ?? ""
            let long = ep["long_title"].string ?? ""
            let name = Int(short) != nil ? "第\(short)话 \(long)" : [short, long].filter { !$0.isEmpty }.joined(separator: " ")
            entries.append(VideoEntry(aid: ep["aid"].int ?? 0, bvid: ep["bvid"].string ?? "", cid: ep["cid"].int ?? 0,
                                      epid: id, title: name.trimmingCharacters(in: .whitespaces),
                                      duration: (ep["duration"].int ?? 0) / 1000,
                                      defaultSelected: epid == nil || epid == id))
        }
        if entries.isEmpty {
            let extras = r["section"].array.reduce(0) { $0 + $1["episodes"].array.count }
            Log.warn("影视《\(title)》未返回正片，附加片段 \(extras) 个，season_id=\(seasonId ?? 0)")
            throw BiliError.noStream("《\(title)》当前未提供可下载的正片" + (extras > 0 ? "，仅有 \(extras) 个预告/花絮。请在 B 站确认正片是否可播放及账号权限" : "，请确认播放权限或地区限制"))
        }
        return ParsedList(title: title, kind: .bangumi, entries: numbered(entries, folder: title), season: nil)
    }
}
