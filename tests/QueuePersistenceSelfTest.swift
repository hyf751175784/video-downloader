import Foundation

@main
struct QueuePersistenceSelfTest {
    static func main() throws {
        let selected = VideoFormat(
            formatId: "137",
            ext: "mp4",
            height: 1080,
            filesize: 42_000_000,
            filesizeHuman: "42 MB",
            label: "1080p",
            hasVideo: true,
            hasAudio: false
        )
        let noisyFormats = (0..<500).map { index in
            VideoFormat(
                formatId: "\(index)",
                ext: "mp4",
                height: index,
                filesize: index * 1_000,
                filesizeHuman: "\(index) KB",
                label: "Format \(index)",
                hasVideo: true,
                hasAudio: index.isMultiple(of: 2)
            )
        }
        let video = VideoInfo(
            id: "sample",
            title: "Readable episode title",
            duration: 120,
            durationHuman: "02:00",
            webpageUrl: "https://example.com/watch/episode",
            referer: "https://example.com/show",
            thumbnail: "https://example.com/large-thumbnail.jpg",
            description: String(repeating: "large extractor metadata ", count: 2_000),
            uploader: "Example",
            formats: noisyFormats,
            formatCount: noisyFormats.count
        )
        let original = DownloadQueueItem(video: video, format: selected)
        let data = try JSONEncoder().encode(PersistedQueueItem(original))
        guard data.count < 4_096 else {
            throw TestFailure("queue snapshot unexpectedly large: \(data.count) bytes")
        }

        let restored = try JSONDecoder().decode(PersistedQueueItem.self, from: data).queueItem
        guard restored.id == original.id,
              restored.title == original.title,
              restored.video.webpageUrl == original.video.webpageUrl,
              restored.video.referer == original.video.referer,
              restored.format == selected else {
            throw TestFailure("restored queue item lost required download metadata")
        }

        let extracted = DownloadViewModel.extractURLs(from: """
        first https://example.com/a.mp4,
        duplicate https://example.com/a.mp4
        second https://cdn.example.com/live/index.m3u8）。
        """)
        guard extracted == ["https://example.com/a.mp4", "https://cdn.example.com/live/index.m3u8"] else {
            throw TestFailure("multi-link extraction did not deduplicate or trim punctuation: \(extracted)")
        }

        let batch = BatchDetectionSnapshot(total: 4, completed: 2, added: 1, failed: 1)
        guard batch.percent == 50, batch.summary.contains("2/4") else {
            throw TestFailure("batch detection progress summary is inconsistent")
        }

        let legacyHistoryJSON = """
        [{
            "title": "Legacy item",
            "url": "https://example.com/legacy",
            "filePath": "/tmp/legacy.mp4",
            "fileName": "legacy.mp4",
            "fileSize": "12 MB",
            "outputFormat": "mp4",
            "status": "success",
            "date": 0
        }]
        """
        let legacyHistory = try JSONDecoder().decode([DownloadRecord].self, from: Data(legacyHistoryJSON.utf8))
        guard legacyHistory.first?.isSuccess == true,
              legacyHistory.first?.compatibility == nil else {
            throw TestFailure("legacy history record did not decode without media-summary fields")
        }
        let richRecord = DownloadRecord(
            title: "Rich item",
            url: "https://example.com/rich",
            filePath: "/tmp/rich.mp4",
            fileName: "rich.mp4",
            fileSize: "42 MB",
            outputFormat: "mp4",
            status: "success",
            error: nil,
            referer: nil,
            durationHuman: "02:00",
            videoCodec: "H264",
            audioCodec: "AAC",
            compatibility: "compatible",
            compatibilityNote: "mp4-compatible",
            date: Date(timeIntervalSince1970: 0)
        )
        let richData = try JSONEncoder().encode(richRecord)
        let restoredRich = try JSONDecoder().decode(DownloadRecord.self, from: richData)
        guard restoredRich.isPlayable,
              restoredRich.durationHuman == "02:00",
              restoredRich.videoCodec == "H264",
              restoredRich.audioCodec == "AAC" else {
            throw TestFailure("rich history record lost media-summary fields")
        }

        let vm = DownloadViewModel()
        vm.clearQueue()
        vm.clearFailedDownloads()
        vm.directMode = true
        vm.url = "https://example.com/a.mp4\nhttps://cdn.example.com/live/index.m3u8\nhttps://example.com/page"
        vm.detectVideos()
        guard vm.downloadQueue.count == 2,
              vm.batchDetection?.total == 3,
              vm.batchDetection?.added == 2,
              vm.batchDetection?.failed == 1 else {
            throw TestFailure("direct multi-link import did not isolate invalid links and queue valid media")
        }
        vm.clearQueue()
        vm.dismissBatchDetection()

        let fakeBackend = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-downloader-batch-\(UUID().uuidString).py")
        let fakeScript = """
        import json
        import sys
        import time
        if sys.argv[1] == "large-output":
            sys.stderr.write("E" * 2500000 + "TAIL_WITHOUT_NEWLINE")
            print(json.dumps({"success": True, "blob": "x" * 4000000}))
            raise SystemExit(0)
        if sys.argv[1] == "large-download-output":
            sys.stderr.write("E" * 2500000 + "\\n")
            sys.stderr.write('__vd_event__{"type":"progress","stage":"finalizing","percent":98,"message":"synthetic"}\\n')
            sys.stderr.write("DOWNLOAD_TAIL_WITHOUT_NEWLINE")
            print(json.dumps({"success": True, "blob": "x" * 4000000}))
            raise SystemExit(0)
        url = sys.argv[2]
        if sys.argv[1] == "download":
            if "slow-fail-download" in url:
                time.sleep(1)
            if "slow-download" in url:
                time.sleep(3)
            if "fail-download" in url:
                print(json.dumps({"success": False, "error": "synthetic download failure"}))
            else:
                print(json.dumps({"success": False, "error": "synthetic stopped download"}))
            raise SystemExit(0)
        if "slow" in url:
            time.sleep(3)
        if "fail" in url:
            print(json.dumps({"success": False, "error": "synthetic failure"}))
        else:
            print(json.dumps({
                "success": True,
                "count": 1,
                "videos": [{
                    "id": url,
                    "title": "Detected " + url.rsplit("/", 1)[-1],
                    "duration_human": "??:??",
                    "webpage_url": url,
                    "thumbnail": "",
                    "description": "",
                    "uploader": "",
                    "formats": [],
                    "format_count": 0
                }]
            }))
        """
        try fakeScript.write(to: fakeBackend, atomically: true, encoding: .utf8)
        setenv("VIDEO_DOWNLOADER_BACKEND_SCRIPT_OVERRIDE", fakeBackend.path, 1)
        defer {
            unsetenv("VIDEO_DOWNLOADER_BACKEND_SCRIPT_OVERRIDE")
            try? FileManager.default.removeItem(at: fakeBackend)
        }

        let largeOutputBox = ExecResultBox()
        let largeOutputStart = Date()
        Task.detached {
            let result = await DownloadViewModel.exec(
                python: "/usr/bin/python3",
                args: [fakeBackend.path, "large-output"],
                timeout: 5
            )
            largeOutputBox.set(result)
        }
        let largeOutputDeadline = Date().addingTimeInterval(7)
        while largeOutputBox.get() == nil, Date() < largeOutputDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard let largeOutputResult = largeOutputBox.get(),
              largeOutputResult.0,
              (largeOutputResult.1?.count ?? 0) > 4_000_000,
              largeOutputResult.2.contains("TAIL_WITHOUT_NEWLINE"),
              largeOutputResult.2.contains("已丢弃"),
              Date().timeIntervalSince(largeOutputStart) < 6 else {
            throw TestFailure("large concurrent stdout/stderr execution blocked or lost its stderr tail")
        }

        let largeDownloadBox = ExecResultBox()
        let progressBox = ProgressEventBox()
        Task.detached {
            let result = await DownloadViewModel.execDownload(
                python: "/usr/bin/python3",
                args: [fakeBackend.path, "large-download-output"],
                timeout: 5,
                onProgress: { progressBox.append($0) }
            )
            largeDownloadBox.set(result)
        }
        let largeDownloadDeadline = Date().addingTimeInterval(7)
        while largeDownloadBox.get() == nil, Date() < largeDownloadDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard let largeDownloadResult = largeDownloadBox.get(),
              largeDownloadResult.0,
              (largeDownloadResult.1?.count ?? 0) > 4_000_000,
              largeDownloadResult.2.contains("DOWNLOAD_TAIL_WITHOUT_NEWLINE"),
              largeDownloadResult.2.contains("已丢弃"),
              progressBox.stages().contains("finalizing") else {
            throw TestFailure("large download pipes blocked, lost progress, or lost the stderr tail")
        }

        let launchFailureBox = ExecResultBox()
        let launchFailureStart = Date()
        Task.detached {
            let result = await DownloadViewModel.exec(
                python: "/definitely/missing/video-downloader-python",
                args: [],
                timeout: 2
            )
            launchFailureBox.set(result)
        }
        let launchFailureDeadline = Date().addingTimeInterval(3)
        while launchFailureBox.get() == nil, Date() < launchFailureDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard let launchFailureResult = launchFailureBox.get(),
              !launchFailureResult.0,
              Date().timeIntervalSince(launchFailureStart) < 2 else {
            throw TestFailure("process launch failure did not return promptly")
        }

        vm.directMode = false
        vm.url = "https://example.com/one\nhttps://example.com/fail\nhttps://example.com/two"
        vm.detectVideos()
        let deadline = Date().addingTimeInterval(8)
        while vm.batchDetection?.isRunning == true, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard vm.batchDetection?.isRunning == false,
              vm.batchDetection?.added == 2,
              vm.batchDetection?.failed == 1,
              vm.downloadQueue.count == 2 else {
            throw TestFailure("sequential webpage batch detection did not continue after an isolated failure")
        }
        vm.clearQueue()
        vm.clearHistory()
        vm.dismissBatchDetection()

        vm.url = "https://example.com/slow-one\nhttps://example.com/slow-two"
        vm.detectVideos()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard vm.systemActivityActive else {
            throw TestFailure("backend task did not acquire the keep-awake system activity")
        }
        vm.cancel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard !vm.systemActivityActive else {
            throw TestFailure("cancelled backend task did not release the keep-awake system activity")
        }
        guard vm.hasPendingBatchDetection, vm.batchDetection?.wasCancelled == true else {
            throw TestFailure("cancelled webpage batch did not preserve remaining detection URLs")
        }
        let restoredVM = DownloadViewModel()
        guard restoredVM.hasPendingBatchDetection,
              restoredVM.batchDetection?.wasCancelled == true,
              restoredVM.batchDetection?.total == 2 else {
            throw TestFailure("pending webpage batch did not restore in a new ViewModel")
        }
        restoredVM.dismissBatchDetection()

        let failedVideo = VideoInfo(
            id: "fail-download",
            title: "Failed exact format",
            duration: nil,
            durationHuman: "??:??",
            webpageUrl: "https://example.com/fail-download",
            referer: "https://example.com/watch",
            thumbnail: "",
            description: "",
            uploader: "",
            formats: [selected],
            formatCount: 1
        )
        vm.downloadVideo(failedVideo, format: selected)
        let failureDeadline = Date().addingTimeInterval(5)
        while vm.activeDownload != nil, Date() < failureDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard vm.failedDownloads.count == 1,
              vm.failedDownloads.first?.video.webpageUrl == failedVideo.webpageUrl,
              vm.failedDownloads.first?.format == selected,
              vm.terminalRunReady,
              vm.terminalFailedDownload?.video.webpageUrl == failedVideo.webpageUrl else {
            throw TestFailure("failed task did not preserve its exact media candidate and format")
        }
        let failedRestoredVM = DownloadViewModel()
        guard failedRestoredVM.failedDownloads.first?.video.webpageUrl == failedVideo.webpageUrl,
              failedRestoredVM.failedDownloads.first?.format == selected else {
            throw TestFailure("failed task did not persist across ViewModel restore")
        }
        vm.retryTerminalDownload()
        guard !vm.terminalRunReady,
              vm.terminalFailedDownload == nil,
              vm.activeDownload?.video.webpageUrl == failedVideo.webpageUrl,
              vm.activeDownload?.format == selected else {
            throw TestFailure("terminal retry did not immediately restart the exact failed task")
        }
        vm.cancel()
        vm.clearQueue()
        failedRestoredVM.clearFailedDownloads()

        let slowFailedVideo = VideoInfo(
            id: "slow-fail-download",
            title: "Slow failed batch item",
            duration: nil,
            durationHuman: "??:??",
            webpageUrl: "https://example.com/slow-fail-download",
            referer: nil,
            thumbnail: "",
            description: "",
            uploader: "",
            formats: [selected],
            formatCount: 1
        )
        vm.queueAutoContinue = true
        _ = vm.enqueueDownload(failedVideo, format: selected)
        _ = vm.enqueueDownload(slowFailedVideo, format: selected)
        vm.startQueue()
        let secondItemDeadline = Date().addingTimeInterval(5)
        while vm.activeDownload?.video.webpageUrl != slowFailedVideo.webpageUrl, Date() < secondItemDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard vm.runTotalCount == 2,
              vm.runCurrentIndex == 2,
              vm.runFailedCount == 1,
              vm.runOverallPercent >= 50,
              vm.runOverallPercent < 100 else {
            throw TestFailure("batch overall progress did not advance correctly after the first failure")
        }
        let batchFinishDeadline = Date().addingTimeInterval(5)
        while vm.activeDownload != nil, Date() < batchFinishDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard vm.runTotalCount == 2,
              vm.runFinishedCount == 2,
              vm.runFailedCount == 2,
              vm.runOverallPercent == 100,
              vm.terminalRunReady,
              vm.terminalFailedDownload != nil else {
            throw TestFailure("finished batch did not report complete overall progress")
        }
        let supportReport = vm.supportReportText(now: Date(timeIntervalSince1970: 0))
        guard supportReport.contains("Video Downloader Support Report"),
              supportReport.contains("Queue: active 0, waiting 0, failed 2"),
              supportReport.contains("Failed tasks:"),
              supportReport.contains("https://example.com/slow-fail-download"),
              supportReport.contains("Recent history:"),
              supportReport.contains("synthetic download failure") else {
            throw TestFailure("support report did not include queue, failed-task, and recent-history context")
        }
        vm.clearFailedDownloads()

        let slowVideo = VideoInfo(
            id: "slow-download",
            title: "Interrupted resumable task",
            duration: nil,
            durationHuman: "??:??",
            webpageUrl: "https://example.com/slow-download",
            referer: nil,
            thumbnail: "",
            description: "",
            uploader: "",
            formats: [selected],
            formatCount: 1
        )
        _ = vm.enqueueDownload(failedVideo, format: selected)
        vm.downloadVideo(slowVideo, format: selected)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard vm.activeDownload?.video.webpageUrl == slowVideo.webpageUrl,
              vm.systemActivityActive,
              vm.runTotalCount == 2 else {
            throw TestFailure("synthetic download did not become active with keep-awake enabled")
        }
        vm.queueAutoContinue = false
        guard vm.runTotalCount == 1 else {
            throw TestFailure("disabling automatic continuation did not exclude waiting tasks from the active run")
        }
        vm.queueAutoContinue = true
        guard vm.runTotalCount == 2 else {
            throw TestFailure("enabling automatic continuation did not include waiting tasks in the active run")
        }
        vm.removeQueued(vm.downloadQueue[0])
        guard vm.runTotalCount == 1 else {
            throw TestFailure("removing a queued item did not update the active batch total")
        }
        vm.cancel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard vm.activeDownload == nil,
              vm.downloadQueue.first?.video.webpageUrl == slowVideo.webpageUrl,
              !vm.systemActivityActive else {
            throw TestFailure("stopped download was not preserved at the front of the queue")
        }
        vm.clearQueue()
        vm.clearFailedDownloads()

        vm.directMode = true
        vm.url = "https://example.com/not-media"
        vm.detectVideos()
        guard !vm.terminalRunReady, vm.terminalFailedDownload == nil else {
            throw TestFailure("a new detection attempt did not clear stale download-terminal context")
        }

        print("Swift state self-test OK: compact \(data.count)-byte snapshot + nonblocking 6.5 MB pipes + terminal exact retry + batch summary")
    }
}

private final class ExecResultBox: @unchecked Sendable {
    typealias Value = (Bool, Data?, String)
    private let lock = NSLock()
    private var value: Value?

    func set(_ result: Value) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ProgressEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BackendProgressEvent] = []

    func append(_ event: BackendProgressEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func stages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap(\.stage)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
