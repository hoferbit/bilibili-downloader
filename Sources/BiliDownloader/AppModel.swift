import AppKit
import BiliCore
import Observation
import SwiftUI

@MainActor @Observable
final class DownloadJob: Identifiable {
    let id = UUID()
    var entry: VideoEntry
    var stage: JobStage = .waiting
    var progress: Double?
    var detail = "等待中"
    var quality = ""
    var output: URL?
    var task: Task<Void, Never>?
    var downloadStarted = false

    init(entry: VideoEntry) { self.entry = entry }

    var isActive: Bool { task != nil }

    func apply(_ u: JobUpdate) {
        guard !stage.isTerminal else { return }
        stage = u.stage
        progress = u.progress
        detail = u.detail
        if let q = u.quality { quality = q }
    }
}

/// 解析结果 + 用户勾选
@MainActor @Observable
final class Selection: Identifiable {
    let id = UUID()
    var list: ParsedList
    var selected: Set<String>
    var loadingSeason = false

    init(_ list: ParsedList) {
        self.list = list
        selected = Set(list.entries.filter(\.defaultSelected).map(\.id))
    }
}

@MainActor @Observable
final class AppModel {
    let client = BiliClient()
    var settings: AppSettings { didSet { if settings != oldValue { settings.save(); pump() } } }
    var account: Account?
    var avatar: NSImage?
    var urlText = ""
    var parsing = false
    var errorMessage: String?
    var selection: Selection?
    var jobs: [DownloadJob] = []
    var showLogin = false
    var ffmpeg: FFmpeg?

    init() {
        settings = AppSettings.load()
        ffmpeg = FFmpeg.locate(custom: settings.ffmpegPath)
        let (ff, s) = (ffmpeg, settings)
        Task.detached { Log.environment(ffmpeg: ff, settings: s, app: "B站下载器") }
        restoreQueue()
        Task { await refreshAccount() }
    }

    func refreshFFmpeg() {
        ffmpeg = FFmpeg.locate(custom: settings.ffmpegPath)
    }

    func refreshAccount() async {
        account = try? await client.account()
        Log.info(account.map { "账号：\($0.name)\($0.isVip ? "（大会员）" : "")" } ?? "未登录")
        avatar = nil
        if let face = account?.face, let url = URL(string: face.replacingOccurrences(of: "http://", with: "https://") + "@96w_96h.webp"),
           let (data, _) = try? await client.fetch(url, withCookies: false) {
            avatar = NSImage(data: data)
        }
    }

    func logout() {
        client.logout()
        account = nil
        avatar = nil
    }

    // MARK: 解析

    func parse() async {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !parsing else { return }
        parsing = true
        defer { parsing = false }
        do {
            let list = try await client.parse(text)
            // 单个视频且不属于合集，直接开始下载
            if list.kind == .video && list.season == nil {
                enqueue(list.entries)
                urlText = ""
            } else {
                selection = Selection(list)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pasteAndParse() async {
        if let s = NSPasteboard.general.string(forType: .string) {
            urlText = s
            await parse()
        }
    }

    func loadSeason(into sel: Selection) async {
        guard let ref = sel.list.season else { return }
        sel.loadingSeason = true
        defer { sel.loadingSeason = false }
        do {
            let current = Set(sel.list.entries.map(\.bvid))
            let list = try await client.season(mid: ref.mid, seasonId: ref.id)
            sel.list = list
            // 保留原先那个视频的勾选
            sel.selected = Set(list.entries.filter { current.contains($0.bvid) }.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirm(_ sel: Selection) {
        let picked = sel.list.entries.filter { sel.selected.contains($0.id) }
        enqueue(picked)
        selection = nil
        urlText = ""
    }

    // MARK: 队列持久化：退出时未完成的任务，下次打开继续

    private struct SavedJob: Codable {
        var entry: VideoEntry
        var failed: Bool
        var detail: String
    }

    private var queueFile: URL { AppPaths.supportDir.appendingPathComponent("queue.json") }

    func persistQueue() {
        let saved = jobs.filter { ![.finished, .skipped, .cancelled].contains($0.stage) }
            .map { SavedJob(entry: $0.entry, failed: $0.stage == .failed, detail: $0.detail) }
        try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: queueFile, options: .atomic) }
    }

    private func restoreQueue() {
        guard let data = try? Data(contentsOf: queueFile),
              let saved = try? JSONDecoder().decode([SavedJob].self, from: data), !saved.isEmpty else { return }
        for s in saved {
            let job = DownloadJob(entry: s.entry)
            if s.failed {
                job.stage = .failed
                job.detail = s.detail
            } else {
                job.detail = "上次未完成，继续（已完成的部分会复用）"
            }
            jobs.append(job)
        }
        Log.info("恢复上次未完成的任务 \(saved.count) 个（其中失败 \(saved.filter(\.failed).count) 个）")
        pump()
    }

    // MARK: 队列

    func enqueue(_ entries: [VideoEntry]) {
        let existing = Set(jobs.filter { !$0.stage.isTerminal }.map(\.entry.id))
        for e in entries where !existing.contains(e.id) {
            jobs.append(DownloadJob(entry: e))
        }
        persistQueue()
        pump()
    }

    func pump() {
        // 首项真正拿到下载通道后，才启动下一项，避免 Task 调度顺序颠倒。
        let active = jobs.filter(\.isActive)
        guard PipelineSchedule.canSubmitNext(activeDownloadStarted: active.map(\.downloadStarted)),
              let job = jobs.first(where: { $0.stage == .waiting && !$0.isActive }) else { return }
        start(job)
    }

    private func start(_ job: DownloadJob) {
        job.downloadStarted = false
        job.task = Task { [weak self] in
            await self?.run(job)
            job.task = nil
            self?.persistQueue()
            self?.pump()
        }
    }

    private func run(_ job: DownloadJob) async {
        guard let ffmpeg else {
            job.stage = .failed
            job.detail = BiliError.ffmpegMissing.localizedDescription
            return
        }
        do {
            if job.entry.cid == 0 {
                job.stage = .resolving
                job.detail = "获取视频信息…"
                let expanded = try await client.expand(job.entry)
                job.entry = expanded[0]
                if expanded.count > 1, let idx = jobs.firstIndex(where: { $0 === job }) {
                    jobs.insert(contentsOf: expanded.dropFirst().map(DownloadJob.init), at: idx + 1)
                }
                persistQueue()
            }
            if job.entry.cid == 0 { throw BiliError.invalidInput("无法获取视频 cid") }
            let pipeline = DownloadPipeline(client: client, settings: settings, ffmpeg: ffmpeg)
            let result = try await pipeline.run(job.entry, downloadStarted: { [weak self] in
                Task { @MainActor in
                    guard job.isActive, !job.stage.isTerminal else { return }
                    job.downloadStarted = true
                    self?.pump()
                }
            }) { u in
                Task { @MainActor in job.apply(u) }
            }
            job.output = result.file
            job.progress = 1
            job.stage = result.skipped ? .skipped : .finished
            job.detail = result.note.isEmpty ? (result.skipped ? "已存在" : "完成") : result.note
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                job.stage = .cancelled
                job.detail = "已取消"
            } else {
                job.stage = .failed
                job.detail = error.localizedDescription
            }
        }
    }

    func cancel(_ job: DownloadJob) {
        if let t = job.task {
            t.cancel()
        } else if job.stage == .waiting {
            job.stage = .cancelled
            job.detail = "已取消"
        }
    }

    func retry(_ job: DownloadJob) {
        guard job.stage == .failed || job.stage == .cancelled else { return }
        job.stage = .waiting
        job.progress = nil
        job.detail = "等待中"
        persistQueue()
        pump()
    }

    func remove(_ job: DownloadJob) {
        job.task?.cancel()
        jobs.removeAll { $0 === job }
        persistQueue()
    }

    func clearFinished() {
        jobs.removeAll { $0.stage == .finished || $0.stage == .skipped || $0.stage == .cancelled }
        persistQueue()
    }

    func retryAllFailed() {
        for job in jobs where job.stage == .failed { retry(job) }
    }

    func reveal(_ job: DownloadJob) {
        if let url = job.output, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            openDownloadFolder()
        }
    }

    func openLogFolder() {
        try? FileManager.default.createDirectory(at: Log.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Log.directory)
    }

    func openDownloadFolder() {
        let url = URL(fileURLWithPath: (settings.downloadDir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    var activeCount: Int { jobs.filter { !$0.stage.isTerminal }.count }
    var failedCount: Int { jobs.filter { $0.stage == .failed }.count }
}
