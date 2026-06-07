import Foundation

/// Represents a detected video with its available formats
struct VideoInfo: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let duration: Double?
    let durationHuman: String
    let webpageUrl: String
    let referer: String?
    let thumbnail: String
    let description: String
    let uploader: String
    let formats: [VideoFormat]
    let formatCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, duration
        case durationHuman = "duration_human"
        case webpageUrl = "webpage_url"
        case referer, thumbnail, description, uploader, formats
        case formatCount = "format_count"
    }

    static func == (lhs: VideoInfo, rhs: VideoInfo) -> Bool {
        lhs.id == rhs.id
    }

    init(
        id: String,
        title: String,
        duration: Double?,
        durationHuman: String,
        webpageUrl: String,
        referer: String?,
        thumbnail: String,
        description: String,
        uploader: String,
        formats: [VideoFormat],
        formatCount: Int
    ) {
        self.id = id
        self.title = title
        self.duration = duration
        self.durationHuman = durationHuman
        self.webpageUrl = webpageUrl
        self.referer = referer
        self.thumbnail = thumbnail
        self.description = description
        self.uploader = uploader
        self.formats = formats
        self.formatCount = formatCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeString(forKey: .id, default: UUID().uuidString)
        title = try c.decodeString(forKey: .title, default: "Video")
        duration = try c.decodeFlexibleDoubleIfPresent(forKey: .duration)
        durationHuman = try c.decodeString(forKey: .durationHuman, default: "??:??")
        webpageUrl = try c.decodeString(forKey: .webpageUrl, default: "")
        referer = try c.decodeIfPresent(String.self, forKey: .referer)
        thumbnail = try c.decodeString(forKey: .thumbnail, default: "")
        description = try c.decodeString(forKey: .description, default: "")
        uploader = try c.decodeString(forKey: .uploader, default: "")
        formats = (try? c.decode([VideoFormat].self, forKey: .formats)) ?? []
        formatCount = try c.decodeFlexibleInt(forKey: .formatCount, default: formats.count)
    }
}

/// Represents a single video format/quality option
struct VideoFormat: Identifiable, Codable, Equatable, Hashable {
    var id: String { formatId }
    let formatId: String
    let ext: String
    let height: Int?
    let filesize: Int?
    let filesizeHuman: String
    let label: String
    let hasVideo: Bool
    let hasAudio: Bool

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case ext, height, filesize
        case filesizeHuman = "filesize_human"
        case label
        case hasVideo = "has_video"
        case hasAudio = "has_audio"
    }

    var displayLabel: String {
        let trackHint: String
        if hasVideo && !hasAudio {
            trackHint = " + 音频"
        } else if !hasVideo && hasAudio {
            trackHint = "音频"
        } else {
            trackHint = ""
        }
        if let height = height, height > 0 {
            return "\(height)p\(trackHint) · \(filesizeHuman)"
        }
        let name = trackHint.isEmpty ? ext.uppercased() : trackHint
        return "\(name) · \(filesizeHuman)"
    }

    init(
        formatId: String,
        ext: String,
        height: Int?,
        filesize: Int?,
        filesizeHuman: String,
        label: String,
        hasVideo: Bool,
        hasAudio: Bool
    ) {
        self.formatId = formatId
        self.ext = ext
        self.height = height
        self.filesize = filesize
        self.filesizeHuman = filesizeHuman
        self.label = label
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatId = try c.decodeString(forKey: .formatId, default: "best")
        ext = try c.decodeString(forKey: .ext, default: "mp4")
        height = try c.decodeFlexibleIntIfPresent(forKey: .height)
        filesize = try c.decodeFlexibleIntIfPresent(forKey: .filesize)
        filesizeHuman = try c.decodeString(forKey: .filesizeHuman, default: "???")
        label = try c.decodeString(forKey: .label, default: ext.uppercased())
        hasVideo = (try? c.decode(Bool.self, forKey: .hasVideo)) ?? true
        hasAudio = (try? c.decode(Bool.self, forKey: .hasAudio)) ?? true
    }
}

extension KeyedDecodingContainer {
    func decodeString(forKey key: Key, default fallback: String) throws -> String {
        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Double.self, forKey: key) {
            return String(value)
        }
        return fallback
    }

    func decodeFlexibleInt(forKey key: Key, default fallback: Int) throws -> Int {
        try decodeFlexibleIntIfPresent(forKey: key) ?? fallback
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decode(String.self, forKey: key) {
            guard let parsed = Double(value) else { return nil }
            return Int(parsed)
        }
        return nil
    }

    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decode(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}

/// Response from the Python backend detect command
struct DetectResponse: Codable {
    let success: Bool
    let videos: [VideoInfo]?
    let count: Int?
    let error: String?
    let method: String?
}

/// Response from the Python backend download command
struct DownloadResponse: Codable, Equatable {
    let success: Bool
    let filePath: String?
    let fileName: String?
    let fileSize: Int?
    let fileSizeHuman: String?
    let format: String?
    let error: String?
    let details: String?
    let durationHuman: String?
    let videoCodec: String?
    let audioCodec: String?
    let compatibility: String?
    let compatibilityNote: String?

    enum CodingKeys: String, CodingKey {
        case success, error, details, format
        case filePath = "file_path"
        case fileName = "file_name"
        case fileSize = "file_size"
        case fileSizeHuman = "file_size_human"
        case durationHuman = "duration_human"
        case videoCodec = "video_codec"
        case audioCodec = "audio_codec"
        case compatibility
        case compatibilityNote = "compatibility_note"
    }
}

struct BackendProgressEvent: Codable {
    let type: String
    let stage: String?
    let percent: Double?
    let message: String?
    let speed: String?
    let eta: String?
    let downloaded: String?
    let total: String?
}

struct ProgressSnapshot: Equatable {
    var stage: String = "idle"
    var title: String = ""
    var detail: String = ""
    var percent: Double = 0
    var speed: String = ""
    var eta: String = ""
    var downloaded: String = ""
    var total: String = ""
}

struct BatchDetectionSnapshot: Equatable {
    let total: Int
    var completed: Int = 0
    var added: Int = 0
    var failed: Int = 0
    var skipped: Int = 0
    var currentURL: String = ""
    var isRunning: Bool = true
    var wasCancelled: Bool = false

    var percent: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total) * 100
    }

    var summary: String {
        if wasCancelled { return "已停止 · 剩余 \(max(total - completed, 0)) · \(added) 入队 · \(failed) 失败" }
        if isRunning { return "\(completed)/\(total) · \(added) 入队 · \(failed) 失败" }
        return "完成 · \(added) 入队 · \(failed) 失败 · \(skipped) 跳过"
    }
}

struct DownloadQueueItem: Identifiable, Codable, Equatable {
    let id: UUID
    let video: VideoInfo
    let format: VideoFormat?
    let addedAt: Date
    let lastError: String?

    init(id: UUID = UUID(), video: VideoInfo, format: VideoFormat?, addedAt: Date = Date(), lastError: String? = nil) {
        self.id = id
        self.video = video
        self.format = format
        self.addedAt = addedAt
        self.lastError = lastError
    }

    var title: String {
        video.title.isEmpty ? "未命名视频" : video.title
    }

    var formatLabel: String {
        format?.displayLabel ?? "最佳质量"
    }

    var sourceHost: String {
        URL(string: video.webpageUrl)?.host ?? "未知来源"
    }

    var withoutFailureContext: DownloadQueueItem {
        DownloadQueueItem(id: id, video: video, format: format, addedAt: addedAt)
    }
}

struct DiagnosticCheck: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    let status: String
    let detail: String
}

struct DiagnosticResponse: Codable {
    let success: Bool
    let summary: String
    let warnings: Int
    let failures: Int
    let checks: [DiagnosticCheck]
}

/// Overall download state for a single video
enum VideoDownloadState: Equatable {
    case idle
    case detecting
    case detected([VideoInfo])
    case downloading(String, Double)  // format label, progress 0-100
    case converting(String)           // format label
    case completed(DownloadResponse)
    case failed(String)               // error message

    var isDownloading: Bool {
        if case .downloading = self { return true }
        if case .converting = self { return true }
        return false
    }

    var isDetecting: Bool {
        if case .detecting = self { return true }
        return false
    }
}

/// Download history record
struct DownloadRecord: Identifiable, Codable {
    var id = UUID()
    let title: String
    let url: String
    let filePath: String?
    let fileName: String?
    let fileSize: String
    let outputFormat: String
    let status: String
    let error: String?
    let referer: String?
    let durationHuman: String?
    let videoCodec: String?
    let audioCodec: String?
    let compatibility: String?
    let compatibilityNote: String?
    let date: Date

    enum CodingKeys: String, CodingKey {
        case title, url, filePath, fileName, fileSize, outputFormat, status, error, referer
        case durationHuman, videoCodec, audioCodec, compatibility, compatibilityNote, date
    }

    var isSuccess: Bool { status == "success" }
    var isPlayable: Bool { compatibility == "compatible" }
    var hasFilePath: Bool { !(filePath ?? "").isEmpty }
    var fileExists: Bool {
        guard let filePath, !filePath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: filePath)
    }

    init(
        title: String,
        url: String,
        filePath: String?,
        fileName: String?,
        fileSize: String,
        outputFormat: String,
        status: String,
        error: String?,
        referer: String?,
        durationHuman: String? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        compatibility: String? = nil,
        compatibilityNote: String? = nil,
        date: Date
    ) {
        self.title = title
        self.url = url
        self.filePath = filePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.outputFormat = outputFormat
        self.status = status
        self.error = error
        self.referer = referer
        self.durationHuman = durationHuman
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.compatibility = compatibility
        self.compatibilityNote = compatibilityNote
        self.date = date
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        fileSize = try c.decodeIfPresent(String.self, forKey: .fileSize) ?? ""
        outputFormat = try c.decodeIfPresent(String.self, forKey: .outputFormat) ?? "mp4"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "success"
        error = try c.decodeIfPresent(String.self, forKey: .error)
        referer = try c.decodeIfPresent(String.self, forKey: .referer)
        durationHuman = try c.decodeIfPresent(String.self, forKey: .durationHuman)
        videoCodec = try c.decodeIfPresent(String.self, forKey: .videoCodec)
        audioCodec = try c.decodeIfPresent(String.self, forKey: .audioCodec)
        compatibility = try c.decodeIfPresent(String.self, forKey: .compatibility)
        compatibilityNote = try c.decodeIfPresent(String.self, forKey: .compatibilityNote)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
    }
}
