import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct D {
    static let accent = Color(red: 0.00, green: 0.46, blue: 0.52)
    static let blue = Color(red: 0.13, green: 0.37, blue: 0.82)
    static let warm = Color(red: 0.92, green: 0.43, blue: 0.16)
    static let mint = Color(red: 0.12, green: 0.66, blue: 0.47)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let bg = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let panel = Color.primary.opacity(0.05)
    static let grad = LinearGradient(colors: [blue, accent, warm], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let softGrad = LinearGradient(colors: [blue.opacity(0.16), accent.opacity(0.10), warm.opacity(0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct A: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(D.grad.opacity(configuration.isPressed ? 0.72 : 1))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct B: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.secondary)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0)))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum SiteHintKind {
    case capture
    case cookies
    case direct
    case referer
    case none
}

private struct SiteHint {
    let kind: SiteHintKind
    let icon: String
    let title: String
    let detail: String
    let tint: Color
}

struct ContentView: View {
    @EnvironmentObject var vm: DownloadViewModel
    @FocusState private var focusURL: Bool
    @State private var showDiagnostics = false
    @State private var showHistory = false
    @State private var showQueue = ProcessInfo.processInfo.arguments.contains("--ui-test-task-center")
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("--ui-test-settings")

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    urlBar
                    smartHintBar
                    settingsStrip
                    directRefererBar
                    taskQueueBar
                    mainStage
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
            statusStrip
        }
        .background(D.bg.ignoresSafeArea())
        .onDrop(of: [.url, .plainText], isTargeted: nil, perform: handleDrop)
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
        .sheet(isPresented: $showHistory) { historySheet }
        .sheet(isPresented: $showQueue) { queueSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .onReceive(NotificationCenter.default.publisher(for: .showVideoDownloaderSettings)) { _ in
            showSettings = true
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(D.grad).frame(width: 38, height: 38)
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(.white)
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(.white)
                    .offset(x: 10, y: 9)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Video Downloader")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("侦测 · 捕获 · 合并 · 转码 · 可播放校验")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Spacer()
            statusPill(icon: "network", text: vm.proxyEnabled ? "代理" : "直连", active: vm.proxyEnabled)
            statusPill(icon: "key", text: vm.browserCookiesEnabled ? "Cookies" : "无 Cookies", active: vm.browserCookiesEnabled)
            if vm.systemActivityActive {
                statusPill(icon: "moon.zzz.fill", text: "保持唤醒", active: true)
            }
            Button {
                showQueue = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 13))
                        .frame(width: 30, height: 28)
                    if queueTaskCount > 0 {
                        Text("\(queueTaskCount)")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Circle().fill(D.warm))
                            .offset(x: 4, y: -3)
                    }
                }
            }
            .buttonStyle(B())
            .help("下载任务")
            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 13)).frame(width: 30, height: 28)
            }
            .buttonStyle(B())
            .help("下载历史")
            Button {
                showDiagnostics = true
                vm.runDiagnostics()
            } label: {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 12)).frame(width: 30, height: 28)
            }
            .buttonStyle(B())
            .help("诊断环境")
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12)).frame(width: 30, height: 28)
            }
            .buttonStyle(B())
            .help("设置")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(D.softGrad.opacity(0.55))
    }

    private func statusPill(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(active ? D.accent : .secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(active ? D.accent.opacity(0.10) : Color.primary.opacity(0.045)))
    }

    private var queueTaskCount: Int {
        vm.downloadQueue.count + vm.failedDownloads.count + (vm.activeDownload == nil ? 0 : 1)
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(D.accent)
                TextField("粘贴一个或多个网页、m3u8/mp4 链接", text: $vm.url)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focusURL)
                    .disabled(vm.state.isDownloading || vm.state.isDetecting)
                    .onSubmit { vm.detectVideos() }
                if inputURLCount > 1 {
                    Text(inputURLCount > 50 ? "50+ 链接" : "\(inputURLCount) 链接")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(D.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(D.blue.opacity(0.10)))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(D.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(D.accent.opacity(focusURL ? 0.45 : 0.16), lineWidth: 1))

            Button {
                withAnimation(.easeOut(duration: 0.15)) { vm.directMode.toggle() }
            } label: {
                Image(systemName: vm.directMode ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .foregroundColor(vm.directMode ? D.accent : .secondary)
            }
            .buttonStyle(B())
            .disabled(vm.state.isDownloading || vm.state.isDetecting)
            .help("直链模式")

            Button {
                vm.pasteAndDetect()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 38, height: 40)
            }
            .buttonStyle(B())
            .disabled(vm.state.isDownloading || vm.state.isDetecting)
            .help("粘贴并检测")

            Button {
                vm.captureInBrowser()
            } label: {
                Label("捕获", systemImage: "scope")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 76, height: 40)
            }
            .buttonStyle(B())
            .disabled(vm.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.state.isDownloading || vm.state.isDetecting)
            .help("打开 Chrome 捕获播放地址")

            if vm.state.isDetecting || vm.state.isDownloading {
                Button {
                    vm.cancel()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 88, height: 40)
                }
                .buttonStyle(A())
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button {
                    vm.detectVideos()
                } label: {
                    Label(detectButtonTitle, systemImage: detectButtonIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 88, height: 40)
                }
                .buttonStyle(A())
                .disabled(vm.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private var inputURLCount: Int {
        DownloadViewModel.extractURLs(from: vm.url).count
    }

    private var detectButtonTitle: String {
        guard inputURLCount > 1 else { return vm.directMode ? "下载" : "检测" }
        return vm.directMode ? "批量入队" : "批量侦测"
    }

    private var detectButtonIcon: String {
        guard inputURLCount > 1 else { return vm.directMode ? "arrow.down.circle" : "magnifyingglass" }
        return vm.directMode ? "tray.and.arrow.down" : "square.stack.3d.up"
    }

    private var settingsStrip: some View {
        HStack(spacing: 10) {
            settingPanel(width: 150) {
                Button {
                    vm.proxyEnabled.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: vm.proxyEnabled ? "network.badge.shield.half.filled" : "network")
                        Text(vm.proxyEnabled ? "代理 \(vm.proxyPort)" : "直连")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(vm.proxyEnabled ? D.accent : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.plain)
                .disabled(vm.state.isDownloading || vm.state.isDetecting)
                .help(vm.proxyEnabled ? "\(vm.proxyHost):\(vm.proxyPort)" : "当前使用直连，点击启用代理")
            }

            settingPanel(width: 120) {
                Picker("", selection: $vm.outputFormat) {
                    Text("MP4").tag("mp4")
                    Text("MKV").tag("mkv")
                    Text("WebM").tag("webm")
                }
                .pickerStyle(.menu)
                .frame(width: 104)
                .font(.system(size: 11, weight: .medium))
                .disabled(vm.state.isDownloading)
            }

            settingPanel {
                Button {
                    vm.selectOutputDir()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(vm.shortOutputPath).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                    .help(vm.outputDir)
            }

            settingPanel(width: 140) {
                Button {
                    showSettings = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text("更多设置")
                        if settingsEnabledCount > 0 {
                            Text("\(settingsEnabledCount)")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundColor(D.accent)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Circle().fill(D.accent.opacity(0.12)))
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.plain)
                .help("更多下载与网络设置")
            }
        }
    }

    private var settingsEnabledCount: Int {
        [vm.browserCookiesEnabled, vm.keepAwakeEnabled, vm.queueAutoContinue, vm.notificationEnabled]
            .filter { $0 }
            .count
    }

    @ViewBuilder
    private var smartHintBar: some View {
        if let hint = siteHint {
            HStack(spacing: 10) {
                Image(systemName: hint.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(hint.tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(hint.tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(hint.title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(hint.detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                hintActions(hint)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hint.tint.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(hint.tint.opacity(0.18), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func hintActions(_ hint: SiteHint) -> some View {
        switch hint.kind {
        case .capture:
            Button {
                vm.captureInBrowser()
            } label: {
                Label("捕获", systemImage: "scope")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(B())
            .disabled(vm.state.isDownloading)
        case .cookies:
            if !vm.browserCookiesEnabled {
                Button {
                    vm.browserCookiesEnabled = true
                } label: {
                    Label("Chrome", systemImage: "key")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(B())
                .disabled(vm.state.isDownloading)
            }
        case .direct:
            if !vm.directMode {
                Button {
                    vm.directMode = true
                } label: {
                    Label("直链", systemImage: "bolt.horizontal.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(B())
                .disabled(vm.state.isDownloading)
            }
        case .referer:
            Button {
                if let string = NSPasteboard.general.string(forType: .string) {
                    let urls = DownloadViewModel.extractURLs(from: string)
                    vm.directReferer = urls.first ?? string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Label("Referer", systemImage: "arrowshape.turn.up.left")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(B())
            .disabled(vm.state.isDownloading)
        case .none:
            EmptyView()
        }
    }

    private var siteHint: SiteHint? {
        let raw = vm.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let extracted = DownloadViewModel.extractURLs(from: raw).first ?? raw
        let lower = extracted.lowercased()
        let host = URL(string: extracted)?.host?.lowercased() ?? ""
        let isMedia = ["m3u8", "mp4", "mpd", "webm", "mkv", "flv", "mov", "avi"].contains { ext in
            lower.contains(".\(ext)") || (ext == "m3u8" && lower.contains(ext))
        }
        if vm.directMode && isMedia && vm.directReferer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SiteHint(kind: .referer, icon: "arrowshape.turn.up.left", title: "直链媒体", detail: "这个地址可能需要原网页 Referer", tint: D.warm)
        }
        if host.contains("bilibili.com") {
            return SiteHint(kind: .cookies, icon: "play.tv", title: "Bilibili", detail: vm.browserCookiesEnabled ? "Chrome Cookies 已启用" : "建议启用 Chrome Cookies", tint: D.blue)
        }
        if host.contains("novipnoad") || host.contains("yfsp") || host.contains("hsex") {
            return SiteHint(kind: .capture, icon: "scope", title: "动态播放器", detail: "建议直接用浏览器捕获", tint: D.warm)
        }
        if isMedia && !vm.directMode {
            return SiteHint(kind: .direct, icon: "bolt.horizontal.circle", title: "媒体直链", detail: "可切换直链模式并保留 Referer", tint: D.accent)
        }
        if host.contains("youtube.com") || host.contains("youtu.be") {
            return SiteHint(kind: .none, icon: "play.rectangle", title: "YouTube", detail: "将优先使用解析器和合并流程", tint: D.mint)
        }
        return nil
    }

    private func settingPanel<Content: View>(width: CGFloat? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 7) { content() }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(D.panel))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    @ViewBuilder
    private var directRefererBar: some View {
        if vm.directMode {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                TextField("Referer（原网页，可选）", text: $vm.directReferer)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(vm.state.isDownloading)
                Button {
                    if let s = NSPasteboard.general.string(forType: .string), s.contains("http") {
                        vm.directReferer = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 12)).frame(width: 28, height: 26)
                }
                .buttonStyle(B())
                .help("从剪贴板填入 Referer")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(D.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var taskQueueBar: some View {
        if let active = vm.activeDownload {
            HStack(spacing: 11) {
                Image(systemName: stageIcon(vm.progress.stage, indeterminate: false))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(D.accent)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(stageDisplayName(vm.progress.stage))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(D.accent)
                        Text(active.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.12))
                            Capsule().fill(D.grad)
                                .frame(width: proxy.size.width * max(0, min(vm.progress.percent, 100)) / 100)
                        }
                    }
                    .frame(height: 4)
                }
                Text("\(Int(vm.progress.percent))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(D.accent)
                    .frame(width: 38, alignment: .trailing)
                if vm.runTotalCount > 1 {
                    Label(vm.runPositionLabel, systemImage: "square.stack.3d.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(D.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(D.blue.opacity(0.10)))
                        .help("总体进度 \(Int(vm.runOverallPercent))%")
                }
                queueWaitingBadge
                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet").font(.system(size: 12)).frame(width: 28, height: 26)
                }
                .buttonStyle(B())
                .help("管理任务")
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(D.accent.opacity(0.075)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(D.accent.opacity(0.18), lineWidth: 0.5))
        } else if let batch = vm.batchDetection {
            HStack(spacing: 11) {
                Image(systemName: batch.isRunning ? "square.stack.3d.up.fill" : "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(batch.isRunning ? D.blue : D.mint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(batch.isRunning ? "批量侦测" : "批量侦测完成")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(batch.isRunning ? D.blue : D.mint)
                        Text(batch.summary)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.12))
                            Capsule().fill(D.grad)
                                .frame(width: proxy.size.width * max(0, min(batch.percent, 100)) / 100)
                        }
                    }
                    .frame(height: 4)
                }
                if batch.isRunning {
                    Text("\(batch.completed)/\(batch.total)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(D.blue)
                        .frame(width: 44, alignment: .trailing)
                } else {
                    if vm.hasPendingBatchDetection {
                        Button {
                            vm.resumeBatchDetection()
                        } label: {
                            Label("继续侦测", systemImage: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(A())
                    }
                    if !vm.downloadQueue.isEmpty {
                        Button {
                            vm.startQueue()
                        } label: {
                            Label("开始下载", systemImage: "play.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(B())
                    }
                    if !vm.downloadQueue.isEmpty {
                        Button {
                            showQueue = true
                        } label: {
                            Image(systemName: "tray.full").font(.system(size: 11)).frame(width: 28, height: 26)
                        }
                        .buttonStyle(B())
                        .help("查看入队任务")
                    }
                    Button {
                        vm.dismissBatchDetection()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 28, height: 26)
                    }
                    .buttonStyle(B())
                    .help("收起批量结果")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill((batch.isRunning ? D.blue : D.mint).opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke((batch.isRunning ? D.blue : D.mint).opacity(0.18), lineWidth: 0.5))
        } else if let next = vm.downloadQueue.first {
            HStack(spacing: 11) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(D.warm)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(vm.downloadQueue.count) 个任务等待开始")
                        .font(.system(size: 11, weight: .bold))
                    Text(next.title)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    vm.clearQueue()
                } label: {
                    Image(systemName: "trash").font(.system(size: 11)).frame(width: 28, height: 26)
                }
                .buttonStyle(B())
                .help("清空等待任务")
                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet").font(.system(size: 11)).frame(width: 28, height: 26)
                }
                .buttonStyle(B())
                .help("管理任务")
                Button {
                    vm.startQueue()
                } label: {
                    Label("开始", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                }
                .buttonStyle(A())
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(D.warm.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(D.warm.opacity(0.18), lineWidth: 0.5))
        } else if let failed = vm.failedDownloads.first {
            HStack(spacing: 11) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(vm.failedDownloads.count) 个失败任务待重试")
                        .font(.system(size: 11, weight: .bold))
                    Text(failed.title)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    vm.clearFailedDownloads()
                } label: {
                    Image(systemName: "trash").font(.system(size: 11)).frame(width: 28, height: 26)
                }
                .buttonStyle(B())
                .help("清空失败任务")
                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet").font(.system(size: 11)).frame(width: 28, height: 26)
                }
                .buttonStyle(B())
                .help("管理失败任务")
                Button {
                    vm.retryAllFailed()
                    vm.startQueue()
                } label: {
                    Label("全部重试", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                }
                .buttonStyle(A())
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.orange.opacity(0.18), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var queueWaitingBadge: some View {
        if !vm.downloadQueue.isEmpty {
            Label("\(vm.downloadQueue.count) 等待", systemImage: "tray.full")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(D.warm)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(D.warm.opacity(0.10)))
        }
    }

    private var mainStage: some View {
        Group {
            switch vm.state {
            case .idle: idleView
            case .detecting:
                workingView(snapshot: vm.progress, indeterminate: vm.batchDetection == nil)
            case .detected(let videos): videoList(videos)
            case .downloading: workingView(snapshot: vm.progress, indeterminate: false)
            case .converting: workingView(snapshot: ProgressSnapshot(stage: "converting", title: "转换中", detail: "正在封装为目标格式", percent: 95), indeterminate: false)
            case .completed(let response): doneView(response)
            case .failed(let error): errorView(error)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(D.panel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    private var idleView: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(D.softGrad)
                    .frame(width: 108, height: 76)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(D.accent.opacity(0.16), lineWidth: 0.5))
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundColor(D.accent)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(D.warm)
                    .offset(x: 29, y: 24)
            }
            VStack(spacing: 4) {
                Text("准备侦测")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("网页、m3u8、DASH、Bilibili、动态播放器")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 9) {
                quickAction("粘贴检测", icon: "doc.on.clipboard", primary: true) {
                    vm.pasteAndDetect()
                }
                quickAction("浏览器捕获", icon: "scope") {
                    vm.captureInBrowser()
                }
                .disabled(vm.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                quickAction("诊断", icon: "wrench.and.screwdriver") {
                    showDiagnostics = true
                    vm.runDiagnostics()
                }
                quickAction("历史", icon: "clock.arrow.circlepath") {
                    showHistory = true
                }
            }
            .frame(maxWidth: 620)
            HStack(spacing: 8) {
                capabilityBadge("HLS", icon: "film.stack", tint: D.blue)
                capabilityBadge("MP4", icon: "checkmark.seal", tint: D.mint)
                capabilityBadge("Cookies", icon: "key", tint: D.accent)
                capabilityBadge("Referer", icon: "arrowshape.turn.up.left", tint: D.warm)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private func quickAction(_ text: String, icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        if primary {
            Button(action: action) {
                Label(text, systemImage: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(A())
        } else {
            Button(action: action) {
                Label(text, systemImage: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(B())
        }
    }

    private func capabilityBadge(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.10)))
    }

    private func workingView(snapshot: ProgressSnapshot, indeterminate: Bool) -> some View {
        VStack(spacing: 10) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(D.softGrad)
                    .frame(width: 78, height: 52)
                Image(systemName: stageIcon(snapshot.stage, indeterminate: indeterminate))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(D.accent)
            }
            Text(snapshot.title.isEmpty ? (indeterminate ? "检测中" : "下载中") : snapshot.title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            if let active = vm.activeDownload {
                Label(active.title, systemImage: "film")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(D.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 560)
            } else if let batch = vm.batchDetection, batch.isRunning {
                Label(batch.currentURL, systemImage: "link")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(D.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 560)
            }
            Text(snapshot.detail.isEmpty ? "正在准备任务" : snapshot.detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            if vm.activeDownload != nil, vm.runTotalCount > 1 {
                runOverview
            }
            progressRail(snapshot, indeterminate: indeterminate)
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private func progressRail(_ snapshot: ProgressSnapshot, indeterminate: Bool) -> some View {
        VStack(spacing: 8) {
            VStack(spacing: 6) {
                if indeterminate {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(D.accent)
                } else {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(D.grad)
                                .frame(width: proxy.size.width * max(0, min(snapshot.percent, 100)) / 100)
                        }
                    }
                    .frame(height: 10)
                }
                HStack {
                    Text(indeterminate ? stageDisplayName(snapshot.stage) : "\(Int(snapshot.percent))%")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(D.accent)
                    Text(stageHint(snapshot.stage, indeterminate: indeterminate))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if !snapshot.speed.isEmpty { Text(snapshot.speed) }
                    if !snapshot.eta.isEmpty { Text("ETA \(snapshot.eta)") }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
            }
            metricRow(snapshot)
            stageRail(active: snapshot.stage, indeterminate: indeterminate)
        }
        .padding(12)
        .frame(maxWidth: 680)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(D.surface.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    private func metricRow(_ snapshot: ProgressSnapshot) -> some View {
        HStack(spacing: 8) {
            metricTile(
                vm.runTotalCount > 1 ? "批次" : "当前",
                value: vm.runTotalCount > 1 ? "\(vm.runPositionLabel) · \(Int(vm.runOverallPercent))%" : stageDisplayName(snapshot.stage),
                icon: vm.runTotalCount > 1 ? "square.stack.3d.up" : "dot.radiowaves.left.and.right",
                tint: D.accent
            )
            metricTile("体积", value: progressAmount(snapshot), icon: "internaldrive", tint: D.blue)
            metricTile("速度", value: snapshot.speed.isEmpty ? "等待数据" : snapshot.speed, icon: "speedometer", tint: D.mint)
            metricTile("剩余", value: snapshot.eta.isEmpty ? "估算中" : snapshot.eta, icon: "timer", tint: D.warm)
        }
    }

    private var runOverview: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label("批次 \(vm.runPositionLabel)", systemImage: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(D.blue)
                Text("总体 \(Int(vm.runOverallPercent))%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                Spacer()
                Text("\(vm.runCompletedCount) 成功 · \(vm.runFailedCount) 失败 · \(vm.downloadQueue.count) 等待")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(D.blue.opacity(0.75))
                        .frame(width: proxy.size.width * max(0, min(vm.runOverallPercent, 100)) / 100)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 680)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(D.blue.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(D.blue.opacity(0.15), lineWidth: 0.5))
    }

    private func metricTile(_ label: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func progressAmount(_ snapshot: ProgressSnapshot) -> String {
        if !snapshot.downloaded.isEmpty { return snapshot.downloaded }
        if !snapshot.total.isEmpty { return snapshot.total }
        return "等待数据"
    }

    private func stageRail(active: String, indeterminate: Bool) -> some View {
        let stages = [
            ("starting", "解析", "magnifyingglass"),
            ("downloading", "下载", "arrow.down"),
            ("merging", "合并", "square.stack.3d.down.right"),
            ("remuxing", "封装", "shippingbox"),
            ("finalizing", "校验", "checkmark.seal")
        ]
        let activeIndex = stageIndex(active)
        return HStack(spacing: 8) {
            ForEach(Array(stages.enumerated()), id: \.offset) { idx, item in
                HStack(spacing: 5) {
                    Image(systemName: item.2)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(idx <= activeIndex ? .white : .secondary.opacity(0.75))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(idx <= activeIndex ? D.accent : Color.secondary.opacity(0.14)))
                    Text(item.1 + (idx == activeIndex && indeterminate ? "中" : ""))
                        .font(.system(size: 10, weight: idx == activeIndex ? .bold : .medium))
                        .foregroundColor(idx <= activeIndex ? D.accent : .secondary)
                }
                if idx < stages.count - 1 {
                    Rectangle()
                        .fill(idx < activeIndex ? D.accent.opacity(0.55) : Color.secondary.opacity(0.16))
                        .frame(height: 1)
                }
            }
        }
    }

    private func stageIndex(_ stage: String) -> Int {
        switch stage {
        case "detecting", "capture", "starting": return 0
        case "downloading": return 1
        case "merging": return 2
        case "remuxing", "fixing", "converting": return 3
        case "finalizing", "done": return 4
        default: return 0
        }
    }

    private func stageDisplayName(_ stage: String) -> String {
        switch stage {
        case "capture": return "浏览器捕获"
        case "detecting", "starting": return "解析媒体"
        case "downloading": return "下载分段"
        case "merging": return "合并音视频"
        case "remuxing": return "重新封装"
        case "fixing": return "修复容器"
        case "converting": return "转码兼容"
        case "finalizing": return "可播放校验"
        case "done": return "完成"
        default: return "准备中"
        }
    }

    private func stageHint(_ stage: String, indeterminate: Bool) -> String {
        if indeterminate {
            if stage == "capture" { return "Chrome 正在打开页面并监听媒体请求" }
            return "正在检查网页、播放器和可用解析器"
        }
        switch stage {
        case "downloading": return "正在拉取媒体数据"
        case "merging": return "正在拼接分段或音视频轨道"
        case "remuxing", "fixing", "converting": return "正在生成更常见、更兼容的文件"
        case "finalizing": return "正在确认文件能被播放器读取"
        case "done": return "任务已经完成"
        default: return "正在准备下载任务"
        }
    }

    private func stageIcon(_ stage: String, indeterminate: Bool) -> String {
        if stage == "capture" { return "scope" }
        if indeterminate { return "wave.3.right.circle" }
        switch stage {
        case "merging": return "square.stack.3d.down.right"
        case "remuxing", "fixing": return "shippingbox"
        case "converting": return "wand.and.stars"
        case "finalizing": return "checkmark.seal"
        default: return "arrow.down.to.line.compact"
        }
    }

    private func videoList(_ videos: [VideoInfo]) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(videos.count) 个候选视频")
                        .font(.system(size: 13, weight: .semibold))
                    if let first = videos.first {
                        Text(first.title)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if let first = videos.first {
                    Button {
                        vm.downloadVideo(first)
                    } label: {
                        Label("下载推荐", systemImage: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(A())
                }
                Button("清除") { vm.resetState() }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                        Card(
                            video: video,
                            outputFormat: vm.outputFormat,
                            isRecommended: index == 0,
                            isQueued: vm.isQueued(video),
                            onDownload: { vm.downloadVideo(video, format: $0) },
                            onQueue: { vm.enqueueDownload(video, format: $0) },
                            onCopy: { vm.copyMediaInfo(video) }
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private func doneView(_ response: DownloadResponse) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle().fill(Color.green.opacity(0.12)).frame(width: 58, height: 58)
                Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundColor(.green)
            }
            Text(vm.terminalRunReady && vm.runTotalCount > 1 ? "批次处理完成" : "下载完成")
                .font(.system(size: 16, weight: .semibold))
            if vm.terminalRunReady && vm.runTotalCount > 1 {
                terminalRunSummary
            }
            Text(response.fileName ?? "")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(response.fileSizeHuman ?? "").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary.opacity(0.7))
            mediaSummary(response)
            HStack(spacing: 8) {
                if vm.terminalRunReady && !vm.failedDownloads.isEmpty {
                    Button {
                        vm.retryAllFailedNow()
                    } label: {
                        Label("重试失败项", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(A())
                }
                Button {
                    if let path = response.filePath { vm.playFile(path) }
                } label: {
                    Label(vm.runTotalCount > 1 ? "播放最后文件" : "播放", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                }
                .buttonStyle(A())
                Button {
                    if let path = response.filePath { vm.openInFinder(path) }
                } label: {
                    Label("打开", systemImage: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                }
                .buttonStyle(B())
                if vm.terminalRunReady && !vm.failedDownloads.isEmpty {
                    Button {
                        showQueue = true
                    } label: {
                        Image(systemName: "tray.full")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 30, height: 28)
                    }
                    .buttonStyle(B())
                    .help("查看失败任务")
                }
                Button {
                    vm.copyFilePath(response)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(B())
                .help("复制文件路径")
                Button {
                    vm.resetState()
                } label: {
                    Label("继续", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                }
                .buttonStyle(B())
            }
            Spacer()
        }
    }

    private func mediaSummary(_ response: DownloadResponse) -> some View {
        HStack(spacing: 7) {
            if let duration = response.durationHuman, !duration.isEmpty, duration != "??:??" {
                resultTag(duration, icon: "timer", tint: D.blue)
            }
            if let video = response.videoCodec, !video.isEmpty {
                resultTag(video, icon: "film", tint: D.accent)
            }
            if let audio = response.audioCodec, !audio.isEmpty {
                resultTag(audio, icon: "waveform", tint: D.mint)
            }
            if response.compatibility == "compatible" {
                resultTag("可播放", icon: "checkmark.seal.fill", tint: D.mint)
            } else if let note = response.compatibilityNote, !note.isEmpty {
                resultTag("需注意", icon: "exclamationmark.triangle.fill", tint: D.warm)
                    .help(note)
            }
        }
        .frame(maxWidth: 620)
    }

    private func resultTag(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.10)))
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle().fill(Color.orange.opacity(0.12)).frame(width: 54, height: 54)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.orange)
            }
            Text(vm.terminalRunReady ? (vm.runTotalCount > 1 ? "批次处理完成" : "下载失败") : "未能完成")
                .font(.system(size: 15, weight: .semibold))
            if vm.terminalRunReady {
                terminalRunSummary
            }
            Text(error)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .lineLimit(7)
            HStack(spacing: 8) {
                if vm.terminalRunReady, vm.terminalFailedDownload != nil {
                    Button {
                        if vm.runTotalCount > 1 {
                            vm.retryAllFailedNow()
                        } else {
                            vm.retryTerminalDownload()
                        }
                    } label: {
                        Label(vm.runTotalCount > 1 ? "重试失败项" : "重新下载", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(A())
                    Button {
                        showQueue = true
                    } label: {
                        Label("任务中心", systemImage: "tray.full")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(B())
                    Button {
                        vm.resetState()
                    } label: {
                        Label("继续", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(B())
                } else {
                    Button {
                        vm.detectVideos()
                    } label: {
                        Label("重试侦测", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(A())
                    Button {
                        vm.directMode = true
                        vm.resetState()
                    } label: {
                        Label("直链", systemImage: "bolt.horizontal.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(B())
                    Button {
                        vm.captureInBrowser()
                    } label: {
                        Label("捕获", systemImage: "scope")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(B())
                    .disabled(vm.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if vm.terminalRunReady && vm.terminalFailedDownload != nil {
                Text("失败任务已保留原始媒体地址、Referer 和所选清晰度，可以直接重新下载。")
                    .font(.system(size: 10))
                    .foregroundColor(D.accent)
                    .multilineTextAlignment(.center)
            }
            if error.localizedCaseInsensitiveContains("cloudflare") ||
                error.contains("403") ||
                error.contains("捕获") {
                Text(vm.terminalRunReady
                    ? "如果原任务仍被站点拒绝，可以先调整代理或 Cookies；也可以点“继续”返回后使用浏览器捕获。"
                    : "这个页面更适合用浏览器捕获：点“捕获”，在弹出的 Chrome 里通过验证并播放，候选地址会自动回填。")
                    .font(.system(size: 11))
                    .foregroundColor(D.accent)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .padding(.top, 2)
            }
            Spacer()
        }
    }

    private var terminalRunSummary: some View {
        VStack(spacing: 7) {
            HStack(spacing: 14) {
                resultTag("\(vm.runCompletedCount) 成功", icon: "checkmark.circle.fill", tint: D.mint)
                resultTag("\(vm.runFailedCount) 失败", icon: "exclamationmark.circle.fill", tint: vm.runFailedCount > 0 ? .orange : D.mint)
                resultTag("\(vm.runFinishedCount)/\(vm.runTotalCount) 已处理", icon: "square.stack.3d.up", tint: D.blue)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(D.blue.opacity(0.72))
                        .frame(width: proxy.size.width * max(0, min(vm.runOverallPercent, 100)) / 100)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(D.blue.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(D.blue.opacity(0.14), lineWidth: 0.5))
    }

    private var statusStrip: some View {
        Group {
            if !vm.statusLog.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(vm.statusLog.suffix(12), id: \.self) { message in
                            Text(message)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.55))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
                .frame(height: 22)
                .background(D.surface)
            }
        }
    }

    private var settingsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("设置").font(.system(size: 15, weight: .semibold))
                    Text("常用操作留在主界面，高级选项集中在这里")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    showSettings = false
                    showDiagnostics = true
                    vm.runDiagnostics()
                } label: {
                    Label("诊断", systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                }
                .buttonStyle(B())
                Button {
                    showSettings = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(B())
                .help("关闭设置")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    settingsSection("输出", icon: "arrow.down.doc") {
                        settingsRow("文件格式", detail: "MP4 兼容性最好，MKV 更适合保留原始轨道", icon: "film") {
                            Picker("", selection: $vm.outputFormat) {
                                Text("MP4").tag("mp4")
                                Text("MKV").tag("mkv")
                                Text("WebM").tag("webm")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 210)
                            .disabled(vm.state.isDownloading)
                        }
                        Divider()
                        settingsRow("保存目录", detail: vm.shortOutputPath, icon: "folder") {
                            Button {
                                vm.selectOutputDir()
                            } label: {
                                Label("选择", systemImage: "folder.badge.plus")
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(B())
                            .disabled(vm.state.isDownloading)
                        }
                    }

                    settingsSection("网络与访问", icon: "network") {
                        settingsRow("代理", detail: vm.proxyEnabled ? "所有侦测和下载走指定 HTTP 代理" : "当前使用直接连接", icon: "network.badge.shield.half.filled") {
                            Toggle("", isOn: $vm.proxyEnabled).labelsHidden().toggleStyle(.switch)
                                .disabled(vm.state.isDownloading || vm.state.isDetecting)
                        }
                        if vm.proxyEnabled {
                            Divider()
                            HStack(spacing: 10) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(D.accent)
                                    .frame(width: 22)
                                TextField("127.0.0.1", text: $vm.proxyHost)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                Text(":").foregroundColor(.secondary)
                                TextField("7890", text: $vm.proxyPort)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 84)
                            }
                            .disabled(vm.state.isDownloading || vm.state.isDetecting)
                            .padding(.vertical, 3)
                        }
                        Divider()
                        settingsRow("Chrome Cookies", detail: "复用 Chrome 登录状态处理 Bilibili、Cloudflare 等页面", icon: "key") {
                            Toggle("", isOn: $vm.browserCookiesEnabled).labelsHidden().toggleStyle(.switch)
                                .disabled(vm.state.isDownloading || vm.state.isDetecting)
                        }
                    }

                    settingsSection("任务行为", icon: "gearshape.2") {
                        settingsRow("自动继续队列", detail: "当前任务结束后自动开始下一个等待任务", icon: "forward.end") {
                            Toggle("", isOn: $vm.queueAutoContinue).labelsHidden().toggleStyle(.switch)
                        }
                        Divider()
                        settingsRow("下载期间保持唤醒", detail: "仅在后端侦测、捕获或下载运行时阻止空闲休眠", icon: "moon.zzz") {
                            Toggle("", isOn: $vm.keepAwakeEnabled).labelsHidden().toggleStyle(.switch)
                        }
                        Divider()
                        settingsRow("完成通知", detail: "任务或批次自然结束时发送一次 macOS 通知", icon: "bell") {
                            HStack(spacing: 8) {
                                if vm.notificationEnabled {
                                    Button {
                                        vm.sendTestNotification()
                                    } label: {
                                        Image(systemName: "bell.badge")
                                            .font(.system(size: 11))
                                            .frame(width: 26, height: 24)
                                    }
                                    .buttonStyle(B())
                                    .help("发送测试通知")
                                }
                                Toggle("", isOn: $vm.notificationEnabled).labelsHidden().toggleStyle(.switch)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .frame(width: 640, height: 500)
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            VStack(spacing: 8) { content() }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(D.panel))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }

    private func settingsRow<Accessory: View>(
        _ title: String,
        detail: String,
        icon: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(D.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            accessory()
        }
        .frame(minHeight: 36)
    }

    private var diagnosticsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("诊断").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    vm.copySupportReport()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 12)).frame(width: 28, height: 26)
                }
                .buttonStyle(B())
                .help("复制支持报告")
                Button {
                    vm.copyDiagnostics()
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 12)).frame(width: 28, height: 26)
                }
                .buttonStyle(B())
                .disabled(vm.diagnostics == nil && vm.diagnosticsError == nil)
                .help("复制诊断结果")
                Button {
                    vm.runDiagnostics()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 28, height: 26)
                }
                .buttonStyle(B())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if vm.diagnosticsRunning {
                ProgressView().tint(D.accent).frame(width: 500, height: 280)
            } else if let error = vm.diagnosticsError {
                Text(error).font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center).frame(width: 500, height: 280)
            } else if let diagnostics = vm.diagnostics {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(diagnostics.summary == "ready" ? "可用" : "需要处理")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(diagnostics.warnings) 警告 · \(diagnostics.failures) 错误")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(diagnostics.checks) { diagnosticRow($0) }
                        }
                    }
                }
                .padding(16)
                .frame(width: 540, height: 340)
            } else {
                Text("暂无结果").foregroundColor(.secondary).frame(width: 500, height: 280)
            }
        }
    }

    private func diagnosticRow(_ item: DiagnosticCheck) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(item.status == "ok" ? Color.green : item.status == "warn" ? Color.orange : Color.red)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 11, weight: .semibold))
                Text(item.detail).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(4)
            }
            Spacer()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private var historySheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("历史").font(.system(size: 15, weight: .semibold))
                Spacer()
                if !vm.history.isEmpty {
                    Button {
                        vm.clearHistory()
                    } label: {
                        Image(systemName: "trash").font(.system(size: 12)).frame(width: 28, height: 26)
                    }
                    .buttonStyle(B())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if vm.history.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock").font(.system(size: 24)).foregroundColor(.secondary.opacity(0.5))
                    Text("暂无记录").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                }
                .frame(width: 560, height: 320)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(vm.history) { record in
                            HistoryRow(
                                record: record,
                                onRetry: {
                                    showHistory = false
                                    vm.retry(record)
                                },
                                onPlay: { vm.playRecord(record) },
                                onOpen: { vm.openRecord(record) },
                                onCopy: { vm.copyRecordInfo(record) },
                                onDelete: { vm.removeHistory(record) }
                            )
                        }
                    }
                    .padding(12)
                }
                .frame(width: 620, height: 390)
            }
        }
    }

    private var queueSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("下载任务").font(.system(size: 15, weight: .semibold))
                    Text(queueSummary)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("自动继续", isOn: $vm.queueAutoContinue)
                    .toggleStyle(.switch)
                    .font(.system(size: 10, weight: .medium))
                    .scaleEffect(0.82)
                Toggle("通知", isOn: $vm.notificationEnabled)
                    .toggleStyle(.switch)
                    .font(.system(size: 10, weight: .medium))
                    .scaleEffect(0.82)
                if vm.notificationEnabled {
                    Button {
                        vm.sendTestNotification()
                    } label: {
                        Image(systemName: "bell.badge").font(.system(size: 11)).frame(width: 28, height: 26)
                    }
                    .buttonStyle(B())
                    .help("发送测试通知")
                }
                if vm.activeDownload == nil && !vm.downloadQueue.isEmpty {
                    Button {
                        vm.startQueue()
                    } label: {
                        Label("开始", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(A())
                }
                if vm.activeDownload != nil {
                    Button {
                        vm.cancel()
                    } label: {
                        Image(systemName: "stop.circle").font(.system(size: 12)).frame(width: 28, height: 26)
                    }
                    .buttonStyle(B())
                    .help("停止当前任务并放回队首")
                }
                if !vm.downloadQueue.isEmpty {
                    Button {
                        vm.clearQueue()
                    } label: {
                        Image(systemName: "trash").font(.system(size: 12)).frame(width: 28, height: 26)
                    }
                    .buttonStyle(B())
                    .help("清空等待队列")
                }
                if !vm.failedDownloads.isEmpty {
                    Button {
                        vm.retryAllFailed()
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 28, height: 26)
                    }
                    .buttonStyle(B())
                    .help("重新入队全部失败任务")
                }
                Button {
                    showQueue = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(B())
                .help("关闭任务中心")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if vm.activeDownload == nil && vm.downloadQueue.isEmpty && vm.failedDownloads.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 26)).foregroundColor(.secondary.opacity(0.5))
                    Text("暂无下载任务").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    Text("从候选视频卡片加入队列，即可顺序下载")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(width: 620, height: 340)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if let active = vm.activeDownload {
                            queueSectionTitle(
                                vm.runTotalCount > 1
                                    ? "当前任务 · 第 \(vm.runPositionLabel) 个 · 总体 \(Int(vm.runOverallPercent))%"
                                    : "当前任务",
                                icon: "arrow.down.circle"
                            )
                            QueueRow(item: active, isActive: true, isFailed: false, progress: vm.progress.percent, onPrioritize: nil, onRetry: nil, onDelete: nil)
                        }
                        if !vm.downloadQueue.isEmpty {
                            queueSectionTitle("等待下载 · \(vm.downloadQueue.count)", icon: "tray.full")
                            ForEach(vm.downloadQueue) { item in
                                QueueRow(
                                    item: item,
                                    isActive: false,
                                    isFailed: false,
                                    progress: 0,
                                    onPrioritize: { vm.prioritizeQueued(item) },
                                    onRetry: nil,
                                    onDelete: { vm.removeQueued(item) }
                                )
                            }
                        }
                        if !vm.failedDownloads.isEmpty {
                            queueSectionTitle("失败待重试 · \(vm.failedDownloads.count)", icon: "exclamationmark.arrow.circlepath")
                            ForEach(vm.failedDownloads) { item in
                                QueueRow(
                                    item: item,
                                    isActive: false,
                                    isFailed: true,
                                    progress: 0,
                                    onPrioritize: nil,
                                    onRetry: { vm.retryFailed(item) },
                                    onDelete: { vm.removeFailed(item) }
                                )
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(width: 660, height: 390)
            }
        }
    }

    private var queueSummary: String {
        let active = vm.activeDownload == nil ? "" : "正在处理 1 个 · "
        let waiting = "\(vm.downloadQueue.count) 个等待"
        let failed = vm.failedDownloads.isEmpty ? "" : " · \(vm.failedDownloads.count) 个待重试"
        let overall = vm.activeDownload != nil && vm.runTotalCount > 1
            ? " · 第 \(vm.runPositionLabel) 个 · 总体 \(Int(vm.runOverallPercent))%"
            : ""
        guard vm.runCompletedCount > 0 || vm.runFailedCount > 0 else {
            return active + waiting + failed + overall
        }
        return "\(active)\(waiting)\(failed)\(overall) · \(vm.runCompletedCount) 成功 · \(vm.runFailedCount) 失败"
    }

    private func queueSectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                    if let data = item as? Data,
                       let string = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self.vm.setInputAndDetect(string)
                        }
                    } else if let url = item as? URL {
                        DispatchQueue.main.async {
                            self.vm.setInputAndDetect(url.absoluteString)
                        }
                    } else if let string = item as? String {
                        DispatchQueue.main.async {
                            self.vm.setInputAndDetect(string)
                        }
                    }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    if let string = item as? String {
                        DispatchQueue.main.async {
                            self.vm.setInputAndDetect(string)
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}

struct Card: View {
    let video: VideoInfo
    let outputFormat: String
    let isRecommended: Bool
    let isQueued: Bool
    let onDownload: (VideoFormat?) -> Void
    let onQueue: (VideoFormat?) -> Void
    let onCopy: () -> Void
    @State private var hover = false
    @State private var selectedFormat: VideoFormat? = nil
    private var sourceHost: String {
        URL(string: video.webpageUrl)?.host ?? video.uploader
    }
    private var primaryExt: String {
        (video.formats.first?.ext ?? URL(string: video.webpageUrl)?.pathExtension ?? "mp4").uppercased()
    }
    private var captureKind: String {
        if video.description.localizedCaseInsensitiveContains("capture") { return "捕获" }
        if video.description.localizedCaseInsensitiveContains("html") { return "网页" }
        if video.description.localizedCaseInsensitiveContains("direct") { return "直链" }
        return "解析"
    }
    private var filenamePreview: String {
        let raw = video.title.isEmpty ? "video" : video.title
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let stem = cleaned.isEmpty ? "video" : cleaned
        let lower = stem.lowercased()
        if lower.hasSuffix(".mp4") || lower.hasSuffix(".mkv") || lower.hasSuffix(".webm") || lower.hasSuffix(".m3u8") || lower.hasSuffix(".mpd") {
            let base = (stem as NSString).deletingPathExtension
            return "\(base.isEmpty ? "video" : base).\(outputFormat)"
        }
        return "\(stem).\(outputFormat)"
    }

    var body: some View {
        HStack(spacing: 13) {
            thumbnail
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(video.title.isEmpty ? "Captured video" : video.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    if isRecommended {
                        tag("推荐", tint: D.mint)
                    }
                    tag(primaryExt, tint: D.blue)
                    tag(captureKind, tint: D.warm)
                }
                HStack(spacing: 8) {
                    Label(sourceHost.isEmpty ? "未知来源" : sourceHost, systemImage: "globe")
                    if video.durationHuman != "??:??" {
                        Label(video.durationHuman, systemImage: "timer")
                    }
                    Label("\(video.formatCount) 格式", systemImage: "slider.horizontal.3")
                    if let referer = video.referer, !referer.isEmpty {
                        Label("Referer", systemImage: "arrowshape.turn.up.left")
                            .foregroundColor(D.mint)
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                Text(video.webpageUrl)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label(filenamePreview, systemImage: "doc")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(D.accent.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if video.formats.count > 1 {
                Picker("", selection: $selectedFormat) {
                    Text("最佳").tag(nil as VideoFormat?)
                    ForEach(video.formats.prefix(8)) { format in
                        Text(format.displayLabel).tag(format as VideoFormat?)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 118)
                .font(.system(size: 10))
            }
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(B())
            .help("复制媒体地址和 Referer")
            Button {
                onQueue(selectedFormat)
            } label: {
                Image(systemName: isQueued ? "checkmark.circle.fill" : "text.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isQueued ? D.mint : .secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(B())
            .help(isQueued ? "已在下载任务中" : "加入下载队列")
            Button {
                onDownload(selectedFormat)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(A())
            .help("下载")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.075 : 0.042)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(hover ? D.accent.opacity(0.32) : Color.primary.opacity(0.08), lineWidth: 0.8))
        .onHover { value in withAnimation(.easeOut(duration: 0.12)) { hover = value } }
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.opacity(0.11)))
    }

    private var thumbnail: some View {
        Group {
            if let url = URL(string: video.thumbnail), video.thumbnail.contains("http") {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 118, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.secondary.opacity(0.08))
            VStack(spacing: 5) {
                Image(systemName: primaryExt == "M3U8" ? "rectangle.stack.badge.play" : "play.rectangle")
                    .font(.system(size: 19, weight: .light))
                Text(primaryExt)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
            .foregroundColor(.secondary.opacity(0.48))
        }
    }
}

struct QueueRow: View {
    let item: DownloadQueueItem
    let isActive: Bool
    let isFailed: Bool
    let progress: Double
    let onPrioritize: (() -> Void)?
    let onRetry: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isFailed ? Color.orange.opacity(0.12) : (isActive ? D.accent.opacity(0.12) : Color.primary.opacity(0.05)))
                    .frame(width: 34, height: 34)
                Image(systemName: isFailed ? "exclamationmark.arrow.circlepath" : (isActive ? "arrow.down" : "hourglass"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isFailed ? .orange : (isActive ? D.accent : .secondary))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isActive {
                        Text("\(Int(progress))%")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(D.accent)
                    }
                }
                HStack(spacing: 8) {
                    Label(item.sourceHost, systemImage: "globe")
                    Label(item.formatLabel, systemImage: "slider.horizontal.3")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            }
            Spacer()
            Text(isFailed ? "失败" : (isActive ? "进行中" : "等待"))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isFailed ? .orange : (isActive ? D.accent : .secondary))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill((isFailed ? Color.orange : (isActive ? D.accent : Color.secondary)).opacity(0.10)))
            if let onRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).frame(width: 28, height: 26)
                }
                .buttonStyle(B())
                .help("重新入队")
            }
            if let onPrioritize {
                Button(action: onPrioritize) {
                    Image(systemName: "arrow.up.to.line").font(.system(size: 10, weight: .semibold)).frame(width: 28, height: 26)
                }
                .buttonStyle(B())
                .help("设为下一个任务")
            }
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 28, height: 26)
                }
                .buttonStyle(B())
                .help("移出队列")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isFailed ? Color.orange.opacity(0.24) : (isActive ? D.accent.opacity(0.24) : Color.primary.opacity(0.07)), lineWidth: 0.5))
    }
}

struct HistoryRow: View {
    let record: DownloadRecord
    let onRetry: () -> Void
    let onPlay: () -> Void
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(record.isSuccess ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: record.isSuccess ? "checkmark" : "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(record.isSuccess ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(record.fileName ?? record.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 7) {
                    Text(Self.formatter.string(from: record.date))
                    Text(record.outputFormat.uppercased())
                    if !record.fileSize.isEmpty { Text(record.fileSize) }
                    if let error = record.error, !record.isSuccess {
                        Text(String(error.prefix(90))).foregroundColor(.orange)
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                Text(record.url)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 25, height: 24)
            }
            .buttonStyle(B())
            .help("重试")
            Button(action: onPlay) {
                Image(systemName: "play.fill").font(.system(size: 10)).frame(width: 25, height: 24)
            }
            .buttonStyle(B())
            .disabled(record.filePath == nil)
            .help("播放")
            Button(action: onOpen) {
                Image(systemName: "folder").font(.system(size: 11)).frame(width: 25, height: 24)
            }
            .buttonStyle(B())
            .disabled(record.filePath == nil)
            .help("打开文件")
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc").font(.system(size: 10, weight: .semibold)).frame(width: 25, height: 24)
            }
            .buttonStyle(B())
            .help("复制信息")
            Button(action: onDelete) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24)
            }
            .buttonStyle(B())
            .help("删除")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .onHover { value in withAnimation(.easeOut(duration: 0.12)) { hover = value } }
    }
}
