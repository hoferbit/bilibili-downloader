import Foundation

/// 单个队列内分别限制下载与合成；等待合成时保留下载名额，最多预取一个视频。
public actor PipelineSchedule {
    public static let shared = PipelineSchedule()

    /// 后一项只有在前一项已获得下载名额后才能提交，避免并发启动抢跑。
    public nonisolated static func canSubmitNext(activeDownloadStarted: [Bool]) -> Bool {
        activeDownloadStarted.count < 2 && activeDownloadStarted.allSatisfy { $0 }
    }
    private let download = PipelineGate()
    private let processing = PipelineGate()

    func begin() async throws -> PipelineLease {
        try await download.acquire()
        return PipelineLease(download: download, processing: processing)
    }
}

actor PipelineGate {
    private var occupied = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if !occupied { occupied = true; c.resume() }
                else { waiters.append((id, c)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        if Task.isCancelled { release(); throw CancellationError() }
    }

    private func cancel(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: i).1.resume(throwing: CancellationError())
    }

    func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().1.resume() }
    }
}

actor PipelineLease {
    private let download: PipelineGate
    private let processing: PipelineGate
    private var downloading = true
    private var composing = false

    init(download: PipelineGate, processing: PipelineGate) {
        self.download = download
        self.processing = processing
    }

    func compose() async throws {
        guard !composing else { return }
        try await processing.acquire()
        composing = true
        if downloading { downloading = false; await download.release() }
    }

    func finish() async {
        if downloading { downloading = false; await download.release() }
        if composing { composing = false; await processing.release() }
    }
}
