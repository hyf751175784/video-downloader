import Foundation
import AppKit
import UserNotifications

private final class ProgressPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let prefix = "__vd_event__"
    private let stderrCollector = PipeDataCollector(limit: 2 * 1024 * 1024, keepTail: true)

    func append(_ data: Data, onProgress: (BackendProgressEvent) -> Void) {
        lock.lock()
        buffer.append(data)
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            var handledProgress = false
            if let line = String(data: lineData, encoding: .utf8), line.hasPrefix(prefix) {
                let jsonText = String(line.dropFirst(prefix.count))
                if let data = jsonText.data(using: .utf8),
                   let event = try? JSONDecoder().decode(BackendProgressEvent.self, from: data) {
                    handledProgress = true
                    lock.unlock()
                    onProgress(event)
                    lock.lock()
                }
            }
            if !handledProgress {
                stderrCollector.append(lineData)
                stderrCollector.append(Data([0x0A]))
            }
        }
        if buffer.count > 2 * 1024 * 1024 {
            stderrCollector.append(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        lock.unlock()
    }

    func collectedText() -> String {
        lock.lock()
        defer { lock.unlock() }
        if !buffer.isEmpty {
            stderrCollector.append(buffer)
            buffer.removeAll()
        }
        return stderrCollector.collectedText()
    }
}

private final class PipeDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let keepTail: Bool
    private var data = Data()
    private var droppedBytes = 0

    init(limit: Int, keepTail: Bool = false) {
        self.limit = limit
        self.keepTail = keepTail
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if keepTail {
            data.append(chunk)
            let overflow = max(data.count - limit, 0)
            if overflow > 0 {
                data.removeFirst(overflow)
                droppedBytes += overflow
            }
            return
        }
        let remaining = max(limit - data.count, 0)
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        droppedBytes += max(chunk.count - remaining, 0)
    }

    func collectedData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func collectedText() -> String {
        lock.lock()
        defer { lock.unlock() }
        var text = String(data: data, encoding: .utf8) ?? ""
        if droppedBytes > 0 {
            text += "\n… 后端输出过大，已丢弃 \(droppedBytes) 字节"
        }
        return text
    }

    var isTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return droppedBytes > 0
    }
}

struct PersistedQueueItem: Codable {
    let id: UUID
    let title: String
    let webpageURL: String
    let referer: String?
    let format: VideoFormat?
    let addedAt: Date

    init(_ item: DownloadQueueItem) {
        id = item.id
        title = item.title
        webpageURL = item.video.webpageUrl
        referer = item.video.referer
        format = item.format
        addedAt = item.addedAt
    }

    var queueItem: DownloadQueueItem {
        let restoredFormat = format ?? VideoFormat(
            formatId: "best",
            ext: "mp4",
            height: nil,
            filesize: nil,
            filesizeHuman: "??",
            label: "最佳",
            hasVideo: true,
            hasAudio: true
        )
        let video = VideoInfo(
            id: webpageURL,
            title: title,
            duration: nil,
            durationHuman: "??:??",
            webpageUrl: webpageURL,
            referer: referer,
            thumbnail: "",
            description: "restored queue item",
            uploader: "",
            formats: [restoredFormat],
            formatCount: 1
        )
        return DownloadQueueItem(id: id, video: video, format: format, addedAt: addedAt)
    }
}

final class DownloadViewModel: ObservableObject {
    @Published var url = ""
    @Published var state: VideoDownloadState = .idle
    @Published var statusLog: [String] = []
    @Published var outputDir: String {
        didSet { UserDefaults.standard.set(outputDir, forKey: "outputDir") }
    }
    @Published var proxyEnabled: Bool {
        didSet { UserDefaults.standard.set(proxyEnabled, forKey: "proxyEnabled") }
    }
    @Published var proxyHost: String {
        didSet { UserDefaults.standard.set(proxyHost, forKey: "proxyHost") }
    }
    @Published var proxyPort: String {
        didSet { UserDefaults.standard.set(proxyPort, forKey: "proxyPort") }
    }
    @Published var directMode = false
    @Published var directReferer: String {
        didSet { UserDefaults.standard.set(directReferer, forKey: "directReferer") }
    }
    @Published var outputFormat: String {
        didSet { UserDefaults.standard.set(outputFormat, forKey: "outputFormat") }
    }
    @Published var browserCookiesEnabled: Bool {
        didSet { UserDefaults.standard.set(browserCookiesEnabled, forKey: "browserCookiesEnabled") }
    }
    @Published var diagnostics: DiagnosticResponse?
    @Published var diagnosticsError: String?
    @Published var diagnosticsRunning = false
    @Published var history: [DownloadRecord] = []
    @Published var captureModeActive = false
    @Published var progress = ProgressSnapshot()
    @Published var activeDownload: DownloadQueueItem? {
        didSet { saveQueueSnapshot() }
    }
    @Published var downloadQueue: [DownloadQueueItem] = [] {
        didSet { saveQueueSnapshot() }
    }
    @Published private(set) var failedDownloads: [DownloadQueueItem] = [] {
        didSet { saveFailedDownloadSnapshot() }
    }
    @Published var queueAutoContinue: Bool {
        didSet {
            UserDefaults.standard.set(queueAutoContinue, forKey: "queueAutoContinue")
            reconcileRunTotal()
        }
    }
    @Published var notificationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationEnabled, forKey: "notificationEnabled")
            if notificationEnabled { requestNotificationAuthorization() }
        }
    }
    @Published var keepAwakeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(keepAwakeEnabled, forKey: "keepAwakeEnabled")
            updateSystemActivity()
        }
    }
    @Published private(set) var runCompletedCount = 0
    @Published private(set) var runFailedCount = 0
    @Published private(set) var runTotalCount = 0
    @Published private(set) var terminalRunReady = false
    @Published private(set) var terminalFailedDownload: DownloadQueueItem?
    @Published private(set) var systemActivityActive = false
    @Published var batchDetection: BatchDetectionSnapshot?
    private let processLock = NSLock()
    private var activeProcess: Process?
    private let activityLock = NSLock()
    private var systemActivity: NSObjectProtocol?
    private let historyKey = "downloadHistory"
    private let queueKey = "downloadQueueSnapshot"
    private let failedDownloadKey = "failedDownloadSnapshot"
    private let pendingBatchKey = "pendingBatchDetectionURLs"
    private let isUITestPreview = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--ui-test-") }
    private var loadingQueueSnapshot = false
    private var loadingFailedDownloadSnapshot = false
    private var pendingBatchURLs: [String] = []

    init() {
        let defaultOutput = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/VideoDownloader").path
        outputDir = UserDefaults.standard.string(forKey: "outputDir") ?? defaultOutput
        proxyEnabled = UserDefaults.standard.object(forKey: "proxyEnabled") as? Bool ?? false
        proxyHost = UserDefaults.standard.string(forKey: "proxyHost") ?? "127.0.0.1"
        proxyPort = UserDefaults.standard.string(forKey: "proxyPort") ?? "7890"
        directReferer = UserDefaults.standard.string(forKey: "directReferer") ?? ""
        let savedFormat = UserDefaults.standard.string(forKey: "outputFormat") ?? "mp4"
        outputFormat = ["mp4", "mkv", "webm"].contains(savedFormat) ? savedFormat : "mp4"
        browserCookiesEnabled = UserDefaults.standard.object(forKey: "browserCookiesEnabled") as? Bool ?? false
        queueAutoContinue = UserDefaults.standard.object(forKey: "queueAutoContinue") as? Bool ?? true
        notificationEnabled = UserDefaults.standard.object(forKey: "notificationEnabled") as? Bool ?? false
        keepAwakeEnabled = UserDefaults.standard.object(forKey: "keepAwakeEnabled") as? Bool ?? true
        loadHistory()
        loadQueueSnapshot()
        loadFailedDownloadSnapshot()
        loadPendingBatchDetection()
        if notificationEnabled { requestNotificationAuthorization() }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-batch-progress") {
            configureUITestBatchProgress()
        } else if ProcessInfo.processInfo.arguments.contains("--ui-test-batch-complete") {
            configureUITestBatchComplete()
        } else if ProcessInfo.processInfo.arguments.contains("--ui-test-download-failure") {
            configureUITestDownloadFailure()
        }
    }

    var proxyArg: String? {
        guard proxyEnabled else { return nil }
        let h = proxyHost.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        return "http://\(h):\(Int(proxyPort.trimmingCharacters(in: .whitespaces)) ?? 7890)"
    }

    private func configureUITestBatchProgress() {
        let format = VideoFormat(
            formatId: "137",
            ext: "mp4",
            height: 1080,
            filesize: 420_000_000,
            filesizeHuman: "420 MB",
            label: "1080p",
            hasVideo: true,
            hasAudio: false
        )
        func item(_ id: String, _ title: String) -> DownloadQueueItem {
            DownloadQueueItem(
                video: VideoInfo(
                    id: id,
                    title: title,
                    duration: 3600,
                    durationHuman: "01:00:00",
                    webpageUrl: "https://example.com/watch/\(id)",
                    referer: "https://example.com/show",
                    thumbnail: "",
                    description: "",
                    uploader: "QA",
                    formats: [format],
                    formatCount: 1
                ),
                format: format
            )
        }

        loadingQueueSnapshot = true
        activeDownload = item("active", "示例：正在合并第二集音视频")
        downloadQueue = [
            item("next", "示例：下一集等待下载"),
            item("later", "示例：片尾特别篇")
        ]
        loadingQueueSnapshot = false
        runCompletedCount = 1
        runFailedCount = 0
        runTotalCount = 4
        progress = ProgressSnapshot(
            stage: "merging",
            title: "合并中",
            detail: "正在拼接视频与音频轨道",
            percent: 62,
            speed: "5.8 MiB/s",
            eta: "00:42",
            downloaded: "286 MiB",
            total: "420 MiB"
        )
        state = .downloading("1080p", 62)
    }

    private func configureUITestBatchComplete() {
        runCompletedCount = 3
        runFailedCount = 1
        runTotalCount = 4
        terminalRunReady = true
        state = .completed(DownloadResponse(
            success: true,
            filePath: "/Users/example/Downloads/VideoDownloader/示例-最后一集.mp4",
            fileName: "示例-最后一集.mp4",
            fileSize: 420_000_000,
            fileSizeHuman: "420 MB",
            format: "mp4",
            error: nil,
            details: nil,
            durationHuman: "42:18",
            videoCodec: "h264",
            audioCodec: "aac",
            compatibility: "compatible",
            compatibilityNote: nil
        ))
        configureUITestFailedItems()
    }

    private func configureUITestDownloadFailure() {
        runCompletedCount = 0
        runFailedCount = 1
        runTotalCount = 1
        terminalRunReady = true
        configureUITestFailedItems()
        terminalFailedDownload = failedDownloads.first
        state = .failed("CDN 返回 403：请检查代理、Cookies 或 Referer 后重新下载")
    }

    private func configureUITestFailedItems() {
        let format = VideoFormat(
            formatId: "137",
            ext: "mp4",
            height: 1080,
            filesize: 420_000_000,
            filesizeHuman: "420 MB",
            label: "1080p",
            hasVideo: true,
            hasAudio: false
        )
        let video = VideoInfo(
            id: "failed-preview",
            title: "示例：保留清晰度与 Referer 的失败任务",
            duration: nil,
            durationHuman: "??:??",
            webpageUrl: "https://example.com/watch/failed-preview",
            referer: "https://example.com/show",
            thumbnail: "",
            description: "",
            uploader: "QA",
            formats: [format],
            formatCount: 1
        )
        failedDownloads = [DownloadQueueItem(video: video, format: format)]
    }

    private var pythonPath: String {
        let p = (Bundle.main.resourcePath ?? "") + "/venv/bin/python3"
        return FileManager.default.fileExists(atPath: p) ? p : "/usr/bin/python3"
    }
    private var backendScript: String {
        if let override = ProcessInfo.processInfo.environment["VIDEO_DOWNLOADER_BACKEND_SCRIPT_OVERRIDE"],
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        let p = (Bundle.main.resourcePath ?? "") + "/backend/downloader.py"
        return FileManager.default.fileExists(atPath: p) ? p : ""
    }

    var shortOutputPath: String {
        outputDir.hasPrefix(NSHomeDirectory()) ? "~" + outputDir.dropFirst(NSHomeDirectory().count) : outputDir
    }

    var runFinishedCount: Int {
        runCompletedCount + runFailedCount
    }

    var runCurrentIndex: Int {
        guard runTotalCount > 0 else { return 0 }
        return min(runFinishedCount + (activeDownload == nil ? 0 : 1), runTotalCount)
    }

    var runOverallPercent: Double {
        guard runTotalCount > 0 else { return 0 }
        let activeContribution = activeDownload == nil ? 0 : max(0, min(progress.percent, 100)) / 100
        return min((Double(runFinishedCount) + activeContribution) / Double(runTotalCount) * 100, 100)
    }

    var runPositionLabel: String {
        guard runTotalCount > 0 else { return "" }
        return "\(runCurrentIndex)/\(runTotalCount)"
    }

    func cancel() {
        stopCurrentTask(preserveActiveDownload: true)
    }

    private func stopCurrentTask(preserveActiveDownload: Bool) {
        processLock.lock()
        let process = activeProcess
        activeProcess = nil
        processLock.unlock()
        process?.terminate()
        updateSystemActivity()
        currentTask?.cancel()
        currentTask = nil
        if var batch = batchDetection, batch.isRunning {
            batch.isRunning = false
            batch.wasCancelled = true
            batch.currentURL = ""
            batchDetection = batch
            log("⏹ 已停止批量侦测")
        }
        if let activeDownload {
            if preserveActiveDownload {
                if !downloadQueue.contains(where: { queueKey(for: $0) == queueKey(forOptional: activeDownload) }) {
                    downloadQueue.insert(activeDownload, at: 0)
                }
                log("⏸ 已停止并保留：\(activeDownload.title)")
            } else {
                log("⏹ 已停止：\(activeDownload.title)")
            }
        }
        activeDownload = nil
        captureModeActive = false
        progress = ProgressSnapshot()
        state = .idle
    }

    func cancelAll() {
        downloadQueue.removeAll()
        failedDownloads.removeAll()
        stopCurrentTask(preserveActiveDownload: false)
        resetRunCounters(total: 0)
        clearTerminalRun()
        clearPendingBatchDetection()
        batchDetection = nil
        log("🧹 已停止并清空下载队列")
    }

    func prepareForTermination() {
        saveQueueSnapshot()
        processLock.lock()
        let process = activeProcess
        activeProcess = nil
        processLock.unlock()
        process?.terminate()
        currentTask?.cancel()
        currentTask = nil
        endSystemActivity()
    }

    private func setActiveProcess(_ process: Process?) {
        processLock.lock()
        activeProcess = process
        processLock.unlock()
        updateSystemActivity()
    }

    private func updateSystemActivity() {
        processLock.lock()
        let hasProcess = activeProcess != nil
        processLock.unlock()

        activityLock.lock()
        defer { activityLock.unlock() }
        if keepAwakeEnabled, hasProcess, systemActivity == nil {
            systemActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Video Downloader 正在处理媒体任务"
            )
        } else if (!keepAwakeEnabled || !hasProcess), let activity = systemActivity {
            ProcessInfo.processInfo.endActivity(activity)
            systemActivity = nil
        }
        let isActive = systemActivity != nil
        DispatchQueue.main.async {
            self.systemActivityActive = isActive
        }
    }

    private func endSystemActivity() {
        activityLock.lock()
        defer { activityLock.unlock() }
        guard let activity = systemActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        systemActivity = nil
        DispatchQueue.main.async {
            self.systemActivityActive = false
        }
    }

    private var currentTask: Task<Void, Never>?

    private func mediaExtension(for value: String) -> String? {
        let lower = value.lowercased()
        for ext in ["m3u8", "mp4", "mpd", "webm", "mkv", "flv", "mov", "avi"] {
            if lower.contains(".\(ext)") || lower.contains(ext) && ext == "m3u8" {
                return ext
            }
        }
        return nil
    }

    static func extractURLs(from text: String) -> [String] {
        let pattern = #"https?://\S+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var urls: [String] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            var value = ns.substring(with: match.range)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r.,;:!?)]}）】》，。、《》\"'"))
            if !urls.contains(value) {
                urls.append(value)
            }
        }
        return urls
    }

    @discardableResult
    func normalizeInputURL() -> Bool {
        let current = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return false }
        let urls = Self.extractURLs(from: current)
        if let first = urls.first {
            url = first
            if urls.count > 1 {
                log("🔗 发现 \(urls.count) 个链接，先处理第一个")
            } else if first != current {
                log("🔗 已从文本中提取链接")
            }
            return true
        }
        return URL(string: current) != nil
    }

    func setInputAndDetect(_ text: String) {
        url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        detectVideos()
    }

    func pasteAndDetect() {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        setInputAndDetect(string)
    }

    // ── detect ──
    func detectVideos() {
        guard !state.isDownloading, !state.isDetecting else { return }
        clearTerminalRun()
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let extracted = Self.extractURLs(from: raw)
        if extracted.count > 1 {
            let urls = Array(extracted.prefix(50))
            if extracted.count > urls.count {
                log("⚠️ 发现 \(extracted.count) 个链接，本次处理前 \(urls.count) 个")
            }
            if directMode {
                enqueueDirectBatch(urls)
            } else {
                detectBatch(urls)
            }
            return
        }
        clearPendingBatchDetection()
        batchDetection = nil
        guard normalizeInputURL() else { return }
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        if directMode {
            guard let ext = mediaExtension(for: u) else {
                state = .failed("直链模式需要 m3u8/mp4/mpd 等媒体地址")
                return
            }
            let referer = directReferer.trimmingCharacters(in: .whitespacesAndNewlines)
            downloadVideo(VideoInfo(id:"d", title:u, duration:nil, durationHuman:"??:??",
                webpageUrl:u, referer:referer.isEmpty ? nil : referer, thumbnail:"", description:"", uploader:"",
                formats:[VideoFormat(formatId:"best", ext:ext,
                    height:nil, filesize:nil, filesizeHuman:"??", label:"直链", hasVideo:true, hasAudio:true)], formatCount:1))
            return
        }

        captureModeActive = false
        progress = ProgressSnapshot(stage: "detecting", title: "检测中", detail: "正在分析网页和播放器网络", percent: 0)
        let isBili = u.contains("bilibili")
        state = .detecting
        log(String(u.prefix(60)))

        let args = detectArguments(for: u, forceCookies: isBili)

        currentTask?.cancel()
        currentTask = Task.detached(priority: .userInitiated) {
            let (ok, stdout, stderr) = await Self.exec(python: self.pythonPath, args: args, timeout: 140) { process in
                self.setActiveProcess(process)
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard ok, let d = stdout else {
                    let err = stderr.prefix(200)
                    self.state = .failed("exit≠0: \(err)")
                    self.log("❌ \(err)")
                    return
                }
                guard let r = Self.decodeJSON(DetectResponse.self, from: d) else {
                    let dbg = Self.outputPreview(d)
                    self.state = .failed("后端结果解析失败：\(dbg)")
                    self.log("❌ decode fail: \(dbg)")
                    return
                }
                if r.success, let vs = r.videos, !vs.isEmpty {
                    self.state = .detected(vs)
                    self.log("✅ \(vs.count)个视频")
                    for v in vs { self.log("  \(v.title.prefix(40)) ⏱\(v.durationHuman)") }
                } else {
                    self.state = .failed(r.error ?? "未找到")
                    self.log("❌ \(r.error ?? "no video")")
                    self.addHistory(
                        title: "检测失败",
                        url: u,
                        filePath: nil,
                        fileName: nil,
                        fileSize: "",
                        status: "failed",
                        error: r.error ?? "未找到",
                        referer: nil
                    )
                }
            }
        }
    }

    private func detectBatch(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        pendingBatchURLs = urls
        savePendingBatchDetection()
        captureModeActive = false
        batchDetection = BatchDetectionSnapshot(total: urls.count)
        state = .detecting
        progress = ProgressSnapshot(
            stage: "detecting",
            title: "批量侦测",
            detail: "准备处理 \(urls.count) 个链接",
            percent: 0
        )
        log("🔗 开始批量侦测 \(urls.count) 个链接")

        currentTask?.cancel()
        currentTask = Task.detached(priority: .userInitiated) {
            for (index, itemURL) in urls.enumerated() {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard var batch = self.batchDetection else { return }
                    batch.currentURL = itemURL
                    self.batchDetection = batch
                    self.progress = ProgressSnapshot(
                        stage: "detecting",
                        title: "批量侦测 \(index + 1)/\(urls.count)",
                        detail: URL(string: itemURL)?.host ?? itemURL,
                        percent: batch.percent
                    )
                }

                let (ok, stdout, stderr) = await Self.exec(
                    python: self.pythonPath,
                    args: self.detectArguments(for: itemURL, forceCookies: itemURL.contains("bilibili")),
                    timeout: 140
                ) { process in
                    self.setActiveProcess(process)
                }
                if Task.isCancelled { return }

                await MainActor.run {
                    guard var batch = self.batchDetection else { return }
                    batch.completed = index + 1
                    if ok, let data = stdout,
                       let response = Self.decodeJSON(DetectResponse.self, from: data),
                       response.success, let recommended = response.videos?.first {
                        if self.enqueueDownload(recommended) {
                            batch.added += 1
                        } else {
                            batch.skipped += 1
                        }
                    } else {
                        batch.failed += 1
                        let message: String
                        if let data = stdout,
                           let response = Self.decodeJSON(DetectResponse.self, from: data) {
                            message = response.error ?? "未找到视频"
                        } else {
                            message = String(stderr.prefix(160))
                        }
                        self.log("❌ 批量侦测失败：\(URL(string: itemURL)?.host ?? itemURL) · \(message)")
                        self.addHistory(
                            title: "批量侦测失败",
                            url: itemURL,
                            filePath: nil,
                            fileName: nil,
                            fileSize: "",
                            status: "failed",
                            error: message,
                            referer: nil
                        )
                    }
                    batch.currentURL = index + 1 == urls.count ? "" : batch.currentURL
                    self.pendingBatchURLs = Array(urls.dropFirst(index + 1))
                    self.savePendingBatchDetection()
                    self.batchDetection = batch
                    self.progress = ProgressSnapshot(
                        stage: "detecting",
                        title: "批量侦测 \(batch.completed)/\(batch.total)",
                        detail: batch.summary,
                        percent: batch.percent
                    )
                }
            }

            await MainActor.run {
                guard var batch = self.batchDetection else { return }
                batch.isRunning = false
                batch.currentURL = ""
                self.clearPendingBatchDetection()
                self.batchDetection = batch
                self.currentTask = nil
                self.state = .idle
                self.progress = ProgressSnapshot()
                self.log("✅ 批量侦测完成：\(batch.added) 入队 · \(batch.failed) 失败 · \(batch.skipped) 跳过")
            }
        }
    }

    private func enqueueDirectBatch(_ urls: [String]) {
        clearPendingBatchDetection()
        var batch = BatchDetectionSnapshot(total: urls.count, isRunning: false)
        let referer = directReferer.trimmingCharacters(in: .whitespacesAndNewlines)
        for itemURL in urls {
            batch.completed += 1
            guard let ext = mediaExtension(for: itemURL) else {
                batch.failed += 1
                continue
            }
            let pathName = URL(string: itemURL)?.lastPathComponent ?? ""
            let video = VideoInfo(
                id: itemURL,
                title: pathName.isEmpty ? itemURL : pathName,
                duration: nil,
                durationHuman: "??:??",
                webpageUrl: itemURL,
                referer: referer.isEmpty ? nil : referer,
                thumbnail: "",
                description: "direct batch item",
                uploader: "",
                formats: [VideoFormat(formatId: "best", ext: ext, height: nil, filesize: nil, filesizeHuman: "??", label: "直链", hasVideo: true, hasAudio: true)],
                formatCount: 1
            )
            if enqueueDownload(video) {
                batch.added += 1
            } else {
                batch.skipped += 1
            }
        }
        batchDetection = batch
        state = .idle
        log("✅ 直链批量入队：\(batch.added) 个 · \(batch.failed) 无效")
    }

    private func detectArguments(for itemURL: String, forceCookies: Bool) -> [String] {
        var args = [backendScript, "detect", itemURL]
        if let p = proxyArg { args += ["--proxy", p] }
        if forceCookies || browserCookiesEnabled { args += ["--cookies-from-browser", "chrome"] }
        return args
    }

    func dismissBatchDetection() {
        guard batchDetection?.isRunning != true else { return }
        clearPendingBatchDetection()
        batchDetection = nil
    }

    var hasPendingBatchDetection: Bool {
        !pendingBatchURLs.isEmpty
    }

    func resumeBatchDetection() {
        guard !pendingBatchURLs.isEmpty, !state.isDetecting, !state.isDownloading else { return }
        detectBatch(pendingBatchURLs)
    }

    private func savePendingBatchDetection() {
        if pendingBatchURLs.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingBatchKey)
        } else {
            UserDefaults.standard.set(pendingBatchURLs, forKey: pendingBatchKey)
        }
    }

    private func clearPendingBatchDetection() {
        pendingBatchURLs.removeAll()
        UserDefaults.standard.removeObject(forKey: pendingBatchKey)
    }

    private func loadPendingBatchDetection() {
        guard let saved = UserDefaults.standard.stringArray(forKey: pendingBatchKey), !saved.isEmpty else { return }
        pendingBatchURLs = saved
        batchDetection = BatchDetectionSnapshot(total: saved.count, isRunning: false, wasCancelled: true)
        log("↩︎ 已恢复 \(saved.count) 个待侦测链接")
    }

    func captureInBrowser() {
        clearTerminalRun()
        guard normalizeInputURL() else { return }
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        captureModeActive = true
        progress = ProgressSnapshot(stage: "capture", title: "捕获中", detail: "在 Chrome 窗口里通过验证并点击播放", percent: 0)
        state = .detecting
        log("🧭 浏览器捕获：在 Chrome 里通过验证并点播放")

        var args = [backendScript, "capture", u, "--timeout", "600"]
        if let p = proxyArg { args += ["--proxy", p] }

        currentTask?.cancel()
        currentTask = Task.detached(priority: .userInitiated) {
            let (ok, stdout, stderr) = await Self.exec(python: self.pythonPath, args: args, timeout: 660) { process in
                self.setActiveProcess(process)
            }
            if Task.isCancelled { return }
            await MainActor.run {
                self.captureModeActive = false
                guard ok, let d = stdout else {
                    let err = stderr.prefix(200)
                    self.state = .failed("浏览器捕获失败: \(err)")
                    self.log("❌ capture: \(err)")
                    return
                }
                guard let r = Self.decodeJSON(DetectResponse.self, from: d) else {
                    let dbg = Self.outputPreview(d)
                    self.state = .failed("捕获结果解析失败：\(dbg)")
                    self.log("❌ capture decode: \(dbg)")
                    return
                }
                if r.success, let vs = r.videos, !vs.isEmpty {
                    self.state = .detected(vs)
                    self.log("✅ 捕获到 \(vs.count) 个媒体地址")
                    for v in vs { self.log("  \(v.title.prefix(40))") }
                } else {
                    self.state = .failed(r.error ?? "没有捕获到媒体地址")
                    self.log("❌ \(r.error ?? "no capture")")
                    self.addHistory(
                        title: "捕获失败",
                        url: u,
                        filePath: nil,
                        fileName: nil,
                        fileSize: "",
                        status: "failed",
                        error: r.error ?? "没有捕获到媒体地址",
                        referer: nil
                    )
                }
            }
        }
    }

    // ── download ──
    func downloadVideo(_ video: VideoInfo, format: VideoFormat? = nil) {
        let item = DownloadQueueItem(video: video, format: format)
        if activeDownload != nil || state.isDownloading {
            enqueueDownload(video, format: format)
            return
        }
        resetRunCounters(total: 1 + (queueAutoContinue ? downloadQueue.count : 0))
        startDownload(item)
    }

    @discardableResult
    func enqueueDownload(_ video: VideoInfo, format: VideoFormat? = nil) -> Bool {
        guard downloadQueue.count < 200 else {
            log("⚠️ 等待队列已达到 200 个任务")
            return false
        }
        let key = queueKey(video: video, format: format)
        if queueKey(forOptional: activeDownload) == key || downloadQueue.contains(where: { queueKey(for: $0) == key }) {
            log("↪︎ 已在任务列表：\(video.title)")
            return false
        }
        downloadQueue.append(DownloadQueueItem(video: video, format: format))
        reconcileRunTotal()
        log("＋ 已加入队列：\(video.title)")
        return true
    }

    func startQueue() {
        guard activeDownload == nil, !state.isDownloading, !state.isDetecting else { return }
        resetRunCounters(total: queueAutoContinue ? downloadQueue.count : min(downloadQueue.count, 1))
        startNextQueuedDownload()
    }

    func removeQueued(_ item: DownloadQueueItem) {
        let wasQueued = downloadQueue.contains { $0.id == item.id }
        downloadQueue.removeAll { $0.id == item.id }
        if wasQueued { reconcileRunTotal() }
    }

    func prioritizeQueued(_ item: DownloadQueueItem) {
        guard let index = downloadQueue.firstIndex(where: { $0.id == item.id }), index > 0 else { return }
        downloadQueue.remove(at: index)
        downloadQueue.insert(item, at: 0)
        log("↑ 已设为下一个：\(item.title)")
    }

    func clearQueue() {
        guard !downloadQueue.isEmpty else { return }
        downloadQueue.removeAll()
        reconcileRunTotal()
        log("🧹 已清空等待队列")
    }

    func retryFailed(_ item: DownloadQueueItem) {
        failedDownloads.removeAll { queueKey(for: $0) == queueKey(for: item) }
        guard queueKey(forOptional: activeDownload) != queueKey(for: item),
              !downloadQueue.contains(where: { queueKey(for: $0) == queueKey(for: item) }) else {
            log("↪︎ 已在任务列表：\(item.title)")
            return
        }
        downloadQueue.insert(item, at: 0)
        reconcileRunTotal()
        log("↩︎ 已重新入队：\(item.title)")
    }

    func retryAllFailed() {
        guard !failedDownloads.isEmpty else { return }
        let retryItems = failedDownloads
        failedDownloads.removeAll()
        var existing = Set(downloadQueue.map { queueKey(for: $0) })
        if let activeKey = queueKey(forOptional: activeDownload) {
            existing.insert(activeKey)
        }
        let unique = retryItems.filter { existing.insert(queueKey(for: $0)).inserted }
        downloadQueue.insert(contentsOf: unique, at: 0)
        reconcileRunTotal()
        log("↩︎ 已重新入队 \(unique.count) 个失败任务")
    }

    func retryTerminalDownload() {
        guard activeDownload == nil, let item = terminalFailedDownload else { return }
        terminalRunReady = false
        terminalFailedDownload = nil
        failedDownloads.removeAll { queueKey(for: $0) == queueKey(for: item) }
        downloadQueue.removeAll { queueKey(for: $0) == queueKey(for: item) }
        downloadQueue.insert(item, at: 0)
        startQueue()
    }

    func retryAllFailedNow() {
        guard activeDownload == nil, !failedDownloads.isEmpty else { return }
        terminalRunReady = false
        terminalFailedDownload = nil
        retryAllFailed()
        startQueue()
    }

    func removeFailed(_ item: DownloadQueueItem) {
        failedDownloads.removeAll { queueKey(for: $0) == queueKey(for: item) }
    }

    func clearFailedDownloads() {
        guard !failedDownloads.isEmpty else { return }
        failedDownloads.removeAll()
        log("🧹 已清空失败任务")
    }

    func isQueued(_ video: VideoInfo) -> Bool {
        activeDownload?.video.webpageUrl == video.webpageUrl ||
            downloadQueue.contains { $0.video.webpageUrl == video.webpageUrl }
    }

    private func startNextQueuedDownload() {
        guard activeDownload == nil, !downloadQueue.isEmpty else { return }
        let item = downloadQueue[0]
        activeDownload = item
        downloadQueue.removeFirst()
        startDownload(item)
    }

    private func startDownload(_ item: DownloadQueueItem) {
        let video = item.video
        let format = item.format
        let fid = formatExpression(for: format)
        failedDownloads.removeAll { queueKey(for: $0) == queueKey(for: item) }
        terminalRunReady = false
        terminalFailedDownload = nil
        activeDownload = item
        state = .downloading(format?.displayLabel ?? "最佳", 0)
        progress = ProgressSnapshot(stage: "starting", title: "准备下载", detail: video.title, percent: 0)
        log("⬇️ \(video.title)")
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        var args = [
            backendScript, "download", video.webpageUrl, fid,
            "--output-dir", outputDir,
            "--output-format", outputFormat,
            "--title", video.title,
            "--progress-json"
        ]
        if let referer = video.referer, !referer.isEmpty {
            args += ["--referer", referer]
        }
        if let p = proxyArg { args += ["--proxy", p] }
        if video.webpageUrl.contains("bilibili") || browserCookiesEnabled {
            args += ["--cookies-from-browser", "chrome"]
        }

        currentTask = Task.detached(priority: .userInitiated) {
            let (ok, stdout, stderr) = await Self.execDownload(python: self.pythonPath, args: args, timeout: 7200) { event in
                Task { @MainActor in
                    self.applyProgress(event, fallbackLabel: format?.displayLabel ?? "最佳")
                }
            } onProcess: { process in
                self.setActiveProcess(process)
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard ok, let d = stdout else {
                    self.runFailedCount += 1
                    let error = "下载失败: \(stderr.prefix(200))"
                    self.recordFailedDownload(item)
                    self.log("❌ \(error)")
                    self.addHistory(
                        title: video.title,
                        url: video.webpageUrl,
                        filePath: nil,
                        fileName: nil,
                        fileSize: "",
                        status: "failed",
                        error: error,
                        referer: video.referer
                    )
                    self.finishDownload(with: .failed(error))
                    return
                }
                guard let r = Self.decodeJSON(DownloadResponse.self, from: d) else {
                    self.runFailedCount += 1
                    let error = "后端结果解析失败：\(Self.outputPreview(d))"
                    self.recordFailedDownload(item)
                    self.log("❌ \(error)")
                    self.addHistory(
                        title: video.title,
                        url: video.webpageUrl,
                        filePath: nil,
                        fileName: nil,
                        fileSize: "",
                        status: "failed",
                        error: error,
                        referer: video.referer
                    )
                    self.finishDownload(with: .failed(error))
                    return
                }
                if r.success {
                    self.runCompletedCount += 1
                    self.failedDownloads.removeAll { self.queueKey(for: $0) == self.queueKey(for: item) }
                    self.log("✅ \(r.fileName ?? "") \(r.fileSizeHuman ?? "")")
                    self.addHistory(
                        title: video.title,
                        url: video.webpageUrl,
                        filePath: r.filePath,
                        fileName: r.fileName,
                        fileSize: r.fileSizeHuman ?? "",
                        status: "success",
                        error: nil,
                        referer: video.referer
                    )
                    if let p = r.filePath, !self.queueAutoContinue || self.downloadQueue.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                    }
                    self.finishDownload(with: .completed(r))
                } else {
                    self.runFailedCount += 1
                    self.recordFailedDownload(item)
                    self.log("❌ \(r.error ?? "?")")
                    self.addHistory(
                        title: video.title,
                        url: video.webpageUrl,
                        filePath: nil,
                        fileName: nil,
                        fileSize: "",
                        status: "failed",
                        error: r.error ?? "下载失败",
                        referer: video.referer
                    )
                    self.finishDownload(with: .failed(r.error ?? "下载失败"))
                }
            }
        }
    }

    private func finishDownload(with finalState: VideoDownloadState) {
        activeDownload = nil
        if queueAutoContinue, !downloadQueue.isEmpty {
            log("→ 继续下一个任务（剩余 \(downloadQueue.count)）")
            startNextQueuedDownload()
        } else {
            currentTask = nil
            state = finalState
            terminalRunReady = true
            if case .failed = finalState {
                terminalFailedDownload = failedDownloads.first
            } else {
                terminalFailedDownload = nil
            }
            notifyRunFinished(finalState)
        }
    }

    private func resetRunCounters(total: Int) {
        runCompletedCount = 0
        runFailedCount = 0
        runTotalCount = max(total, 0)
    }

    private func clearTerminalRun() {
        terminalRunReady = false
        terminalFailedDownload = nil
    }

    private func reconcileRunTotal() {
        guard activeDownload != nil else { return }
        runTotalCount = runFinishedCount + 1 + (queueAutoContinue ? downloadQueue.count : 0)
    }

    private func queueKey(video: VideoInfo, format: VideoFormat?) -> String {
        "\(video.webpageUrl)|\(formatExpression(for: format))"
    }

    private func queueKey(forOptional item: DownloadQueueItem?) -> String? {
        guard let item else { return nil }
        return queueKey(video: item.video, format: item.format)
    }

    private func queueKey(for item: DownloadQueueItem) -> String {
        queueKey(video: item.video, format: item.format)
    }

    private func recordFailedDownload(_ item: DownloadQueueItem) {
        let key = queueKey(for: item)
        failedDownloads.removeAll { queueKey(for: $0) == key }
        failedDownloads.insert(item, at: 0)
        terminalFailedDownload = item
        if failedDownloads.count > 50 {
            failedDownloads.removeLast(failedDownloads.count - 50)
        }
    }

    private func saveQueueSnapshot() {
        guard !loadingQueueSnapshot, !isUITestPreview else { return }
        var items: [DownloadQueueItem] = []
        if let activeDownload { items.append(activeDownload) }
        items.append(contentsOf: downloadQueue)
        if items.isEmpty {
            UserDefaults.standard.removeObject(forKey: queueKey)
        } else if let data = try? JSONEncoder().encode(items.prefix(200).map(PersistedQueueItem.init)) {
            UserDefaults.standard.set(data, forKey: queueKey)
        }
    }

    private func loadQueueSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: queueKey),
              let saved = try? JSONDecoder().decode([PersistedQueueItem].self, from: data) else {
            return
        }
        loadingQueueSnapshot = true
        var seen = Set<String>()
        downloadQueue = saved.map(\.queueItem).filter { seen.insert(queueKey(video: $0.video, format: $0.format)).inserted }
        loadingQueueSnapshot = false
        saveQueueSnapshot()
        if !downloadQueue.isEmpty {
            log("↩︎ 已恢复 \(downloadQueue.count) 个等待任务")
        }
    }

    private func saveFailedDownloadSnapshot() {
        guard !loadingFailedDownloadSnapshot, !isUITestPreview else { return }
        if failedDownloads.isEmpty {
            UserDefaults.standard.removeObject(forKey: failedDownloadKey)
        } else if let data = try? JSONEncoder().encode(failedDownloads.prefix(50).map(PersistedQueueItem.init)) {
            UserDefaults.standard.set(data, forKey: failedDownloadKey)
        }
    }

    private func loadFailedDownloadSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: failedDownloadKey),
              let saved = try? JSONDecoder().decode([PersistedQueueItem].self, from: data) else {
            return
        }
        loadingFailedDownloadSnapshot = true
        var seen = Set<String>()
        failedDownloads = saved.map(\.queueItem).filter {
            seen.insert(queueKey(video: $0.video, format: $0.format)).inserted
        }
        loadingFailedDownloadSnapshot = false
        saveFailedDownloadSnapshot()
        if !failedDownloads.isEmpty {
            log("↩︎ 已恢复 \(failedDownloads.count) 个失败任务")
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard !granted else { return }
            DispatchQueue.main.async {
                if self.notificationEnabled {
                    self.notificationEnabled = false
                    self.log("⚠️ 系统通知权限未开启")
                }
            }
        }
    }

    func sendTestNotification() {
        guard notificationEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Video Downloader 通知已就绪"
        content.body = "下载完成后会在这里提醒你"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            DispatchQueue.main.async {
                if let error {
                    self.log("⚠️ 通知测试失败：\(error.localizedDescription)")
                } else {
                    self.log("🔔 已发送测试通知")
                }
            }
        }
    }

    private func notifyRunFinished(_ finalState: VideoDownloadState) {
        guard notificationEnabled else { return }
        let content = UNMutableNotificationContent()
        content.sound = .default
        if runFailedCount == 0 {
            content.title = runCompletedCount > 1 ? "批量下载完成" : "下载完成"
            content.body = runCompletedCount > 1 ? "\(runCompletedCount) 个视频已保存" : completionNotificationBody(finalState)
        } else {
            content.title = "下载任务已结束"
            content.body = "\(runCompletedCount) 个成功 · \(runFailedCount) 个失败"
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func completionNotificationBody(_ state: VideoDownloadState) -> String {
        if case .completed(let response) = state {
            return response.fileName ?? "视频已保存"
        }
        return "任务已完成"
    }

    private func formatExpression(for format: VideoFormat?) -> String {
        guard let format else { return "best" }
        if format.hasVideo && !format.hasAudio {
            return "\(format.formatId)+bestaudio/best"
        }
        if !format.hasVideo && format.hasAudio {
            return "\(format.formatId)/bestaudio/best"
        }
        return format.formatId.isEmpty ? "best" : format.formatId
    }

    func runDiagnostics() {
        diagnosticsRunning = true
        diagnosticsError = nil
        diagnostics = nil

        var args = [backendScript, "diagnose", "--output-dir", outputDir, "--output-format", outputFormat]
        if let p = proxyArg { args += ["--proxy", p] }
        if browserCookiesEnabled { args += ["--cookies-from-browser", "chrome"] }
        let referer = directReferer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !referer.isEmpty { args += ["--referer", referer] }

        Task.detached(priority: .userInitiated) {
            let (ok, stdout, stderr) = await Self.exec(python: self.pythonPath, args: args, timeout: 25)
            await MainActor.run {
                self.diagnosticsRunning = false
                guard ok, let data = stdout else {
                    self.diagnosticsError = String(stderr.prefix(300))
                    return
                }
                guard let diagnostics = Self.decodeJSON(DiagnosticResponse.self, from: data) else {
                    self.diagnosticsError = "诊断结果解析失败: \(Self.outputPreview(data))"
                    return
                }
                self.diagnostics = diagnostics
            }
        }
    }

    func copyDiagnostics() {
        var lines = [
            "Video Downloader Diagnostics",
            "Proxy: \(proxyArg ?? "direct")",
            "Cookies: \(browserCookiesEnabled ? "Chrome" : "disabled")",
            "Output format: \(outputFormat)",
            "Output: \(outputDir)",
        ]
        if let diagnostics {
            lines.append("Summary: \(diagnostics.summary) · \(diagnostics.warnings) warnings · \(diagnostics.failures) failures")
            for item in diagnostics.checks {
                lines.append("[\(item.status.uppercased())] \(item.name): \(item.detail)")
            }
        } else if let diagnosticsError {
            lines.append("Error: \(diagnosticsError)")
        } else {
            lines.append("No diagnostic result yet.")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        log("📋 已复制诊断结果")
    }

    // ── Pure async exec ──
    static func exec(
        python: String,
        args: [String],
        timeout: Int,
        onProcess: @escaping (Process?) -> Void = { _ in }
    ) async -> (Bool, Data?, String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            let stdoutCollector = PipeDataCollector(limit: 64 * 1024 * 1024)
            let stderrCollector = PipeDataCollector(limit: 2 * 1024 * 1024, keepTail: true)
            let readGroup = DispatchGroup()
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                stdoutCollector.append(out.fileHandleForReading.readDataToEndOfFile())
                readGroup.leave()
            }
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                stderrCollector.append(err.fileHandleForReading.readDataToEndOfFile())
                readGroup.leave()
            }
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + .seconds(timeout))
            timer.setEventHandler { p.terminate() }
            timer.resume()
            p.terminationHandler = { _ in timer.cancel() }
            do {
                try p.run()
                onProcess(p)
                p.waitUntilExit()
                onProcess(nil)
                readGroup.wait()
                let data = stdoutCollector.collectedData()
                let stderr = stderrCollector.collectedText()
                if stdoutCollector.isTruncated {
                    cont.resume(returning: (false, nil, "后端结果超过 64 MB，已停止解析；请缩小任务范围后重试"))
                } else {
                    cont.resume(returning: (p.terminationStatus == 0, data.isEmpty ? nil : data, stderr))
                }
            } catch {
                timer.cancel()
                onProcess(nil)
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                cont.resume(returning: (false, nil, error.localizedDescription))
            }
        }
    }

    static func execDownload(
        python: String,
        args: [String],
        timeout: Int,
        onProgress: @escaping (BackendProgressEvent) -> Void,
        onProcess: @escaping (Process?) -> Void = { _ in }
    ) async -> (Bool, Data?, String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let stdoutCollector = PipeDataCollector(limit: 64 * 1024 * 1024)
            let collector = ProgressPipeCollector()

            let stdoutReadGroup = DispatchGroup()
            stdoutReadGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                stdoutCollector.append(out.fileHandleForReading.readDataToEndOfFile())
                stdoutReadGroup.leave()
            }
            err.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collector.append(data, onProgress: onProgress)
            }

            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + .seconds(timeout))
            timer.setEventHandler { p.terminate() }
            timer.resume()
            p.terminationHandler = { _ in timer.cancel() }
            do {
                try p.run()
                onProcess(p)
                p.waitUntilExit()
                onProcess(nil)
                err.fileHandleForReading.readabilityHandler = nil
                stdoutReadGroup.wait()
                collector.append(err.fileHandleForReading.readDataToEndOfFile(), onProgress: onProgress)
                let stderrText = collector.collectedText()
                let data = stdoutCollector.collectedData()
                if stdoutCollector.isTruncated {
                    cont.resume(returning: (false, nil, "后端结果超过 64 MB，已停止解析；请缩小任务范围后重试"))
                } else {
                    cont.resume(returning: (p.terminationStatus == 0, data.isEmpty ? nil : data, stderrText))
                }
            } catch {
                timer.cancel()
                onProcess(nil)
                err.fileHandleForReading.readabilityHandler = nil
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                cont.resume(returning: (false, nil, error.localizedDescription))
            }
        }
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        if let value = try? decoder.decode(T.self, from: data) {
            return value
        }
        guard let text = String(data: data, encoding: .utf8),
              let jsonText = extractJSONObject(from: text),
              let extracted = jsonText.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(T.self, from: extracted)
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if escape {
                escape = false
            } else if ch == "\\" {
                escape = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func outputPreview(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? "binary"
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        return String(collapsed.prefix(180))
    }

    @MainActor
    private func applyProgress(_ event: BackendProgressEvent, fallbackLabel: String) {
        let percent = max(0, min(event.percent ?? 0, 100))
        let stage = event.stage ?? "downloading"
        var label = fallbackLabel
        var title = "下载中"
        switch stage {
        case "starting":
            title = "准备下载"
            label = event.message ?? "解析媒体地址"
        case "downloading":
            title = "下载中"
            if let speed = event.speed, let eta = event.eta {
                label = "\(speed) · ETA \(eta)"
            } else if let message = event.message {
                label = String(message.prefix(56))
            }
        case "merging":
            title = "合并中"
            label = "合并音视频/分段"
        case "remuxing":
            title = "封装中"
            label = "封装为目标格式"
        case "fixing":
            title = "修复中"
            label = "修复媒体容器"
        case "converting":
            title = "转换中"
            label = "转换编码/格式"
        case "finalizing":
            title = "校验中"
            label = event.message ?? "校验输出文件"
        case "done":
            title = "完成"
            label = "下载完成"
        default:
            if let message = event.message { label = String(message.prefix(56)) }
        }
        progress = ProgressSnapshot(
            stage: stage,
            title: title,
            detail: label,
            percent: percent,
            speed: event.speed ?? "",
            eta: event.eta ?? "",
            downloaded: event.downloaded ?? "",
            total: event.total ?? ""
        )
        state = .downloading(label, percent)
    }

    func selectOutputDir() {
        let p = NSOpenPanel(); p.title = "下载目录"; p.canChooseFiles = false
        p.canChooseDirectories = true; p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: outputDir)
        if p.runModal() == .OK, let u = p.url { outputDir = u.path }
    }
    func openInFinder(_ path: String) { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
    func playFile(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    func resetState() {
        progress = ProgressSnapshot()
        state = .idle
        clearTerminalRun()
    }
    func log(_ msg: String) { statusLog.append(msg); if statusLog.count > 200 { statusLog.removeFirst(50) } }

    func retry(_ record: DownloadRecord) {
        url = record.url
        directReferer = record.referer ?? directReferer
        directMode = mediaExtension(for: record.url) != nil
        resetState()
        detectVideos()
    }

    func openRecord(_ record: DownloadRecord) {
        guard let path = record.filePath else { return }
        openInFinder(path)
    }

    func playRecord(_ record: DownloadRecord) {
        guard let path = record.filePath else { return }
        playFile(path)
    }

    func copyRecordInfo(_ record: DownloadRecord) {
        var parts = [record.url]
        if let referer = record.referer, !referer.isEmpty {
            parts.append("Referer: \(referer)")
        }
        if let path = record.filePath {
            parts.append("File: \(path)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "\n"), forType: .string)
        log("📋 已复制历史记录")
    }

    func copyMediaInfo(_ video: VideoInfo) {
        var text = video.webpageUrl
        if let referer = video.referer, !referer.isEmpty {
            text += "\nReferer: \(referer)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        log("📋 已复制媒体地址")
    }

    func copyFilePath(_ response: DownloadResponse) {
        guard let path = response.filePath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        log("📋 已复制文件路径")
    }

    func removeHistory(_ record: DownloadRecord) {
        history.removeAll { $0.id == record.id }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func addHistory(
        title: String,
        url: String,
        filePath: String?,
        fileName: String?,
        fileSize: String,
        status: String,
        error: String?,
        referer: String?
    ) {
        let record = DownloadRecord(
            title: title,
            url: url,
            filePath: filePath,
            fileName: fileName,
            fileSize: fileSize,
            outputFormat: outputFormat,
            status: status,
            error: error,
            referer: referer,
            date: Date()
        )
        history.insert(record, at: 0)
        if history.count > 80 {
            history.removeLast(history.count - 80)
        }
        saveHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([DownloadRecord].self, from: data) else {
            history = []
            return
        }
        history = decoded
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
}
