# Video Downloader

[![CI](https://github.com/hyf751175784/video-downloader/actions/workflows/ci.yml/badge.svg)](https://github.com/hyf751175784/video-downloader/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&logoColor=white)](#requirements)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-native-0A84FF?logo=swift&logoColor=white)](#tech-stack)
[![Python](https://img.shields.io/badge/Python-backend-3776AB?logo=python&logoColor=white)](#tech-stack)
[![yt-dlp](https://img.shields.io/badge/yt--dlp-engine-6B7280)](https://github.com/yt-dlp/yt-dlp)
[![ffmpeg](https://img.shields.io/badge/ffmpeg-merge%20%2B%20convert-007808)](https://ffmpeg.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**A native macOS video downloader that detects playable media from a webpage, queues the work, and saves common video files such as MP4, MKV, and WebM.**

[中文文档](README.zh-CN.md) · [Architecture](docs/ARCHITECTURE.md) · [Agile Log](docs/AGILE_LOG.md)

![Video Downloader app icon and preview](VideoDownloader/Resources/AppIcon.preview.png)

## Why It Exists

Many video pages do not expose a simple `.mp4` URL. They may load an HLS `.m3u8` playlist through JavaScript, split media into many fragments, require a Referer header, or only reveal the stream after a real browser starts playback.

Video Downloader wraps the messy parts into a simple desktop workflow:

```text
Paste page URL -> Detect media -> Pick quality -> Download -> Validate playable file
```

It is designed for personal archiving of media you own or have permission to download. It does not decrypt DRM, bypass paywalls, or promise access to protected platforms.

## Highlights

- **Native macOS app**: SwiftUI interface with dark mode, keyboard shortcuts, history, settings, and Finder actions.
- **Layered detection engine**: direct media parsing, yt-dlp extraction, HTML/iframe scanning, Playwright sniffing, Chrome/CDP capture, and visible browser capture for hard dynamic players.
- **HLS and DASH aware**: downloads segmented `.m3u8` streams, merges fragments, combines audio/video tracks, and validates the output.
- **Common output formats**: MP4 by default, with MKV and WebM available from the app.
- **Playable-file guard**: ffprobe checks the result; incompatible MP4 output can be remuxed or transcoded toward QuickTime-friendly H.264/AAC.
- **Task center**: queue several candidates, run sequential downloads, stop and recover the current task, retry failed tasks, and preserve compact queue snapshots across relaunches.
- **Batch progress**: see current item, total progress, stage, speed, ETA, success count, failure count, and waiting count.
- **Proxy and cookies**: optional proxy routing and Chrome-cookie reuse for pages that work in your browser but block anonymous automation.
- **Browser capture mode**: open a controlled Chrome session, play the video, and capture the media request for download.
- **Support report copy**: the diagnostics and failure screens can copy app state, queue counts, failed tasks, recent history, logs, and diagnostics into a plain-text report.
- **Output-folder fallback**: completion and settings surfaces can open the output directory even when an exact file path is missing or the file was moved.
- **Real-world test matrix**: maintain live samples for platforms and dynamic video sites without downloading full videos during smoke tests.

## Screens And Product Surface

The app is built around a practical workflow rather than a landing page:

- Paste one URL or a batch of URLs.
- Review ranked media candidates.
- Choose output format and quality.
- Queue or download immediately.
- Watch the detailed progress console during detect, download, merge, convert, and validation.
- Recover failed or interrupted work from the task center.

## Requirements

- macOS 14.0 or newer
- Xcode command line tools or Xcode
- [Homebrew](https://brew.sh)
- `ffmpeg`
- Python 3, managed by the project virtual environment

## Quick Start

```bash
git clone https://github.com/hyf751175784/video-downloader.git
cd video-downloader

brew install ffmpeg
make install-deps
make run
```

The built app is created at:

```text
build/VideoDownloader.app
```

To create a distributable archive:

```bash
make package
```

The package is written to `dist/VideoDownloader-<version>-macos-arm64.zip` with a matching `.sha256` checksum file.

## Usage

### Mac App

1. Launch `VideoDownloader.app`.
2. Paste a webpage URL or several URLs.
3. Click **Detect** or press `Command + Return`.
4. Pick a candidate and quality.
5. Download immediately or add multiple items to the queue.
6. Open the task center to monitor progress, retry failures, or continue the next task.
7. Use Settings (`Command + ,`) for proxy, cookies, notifications, output format, and keep-awake behavior.
8. Copy a support report from Diagnostics or the failure screen when a site or download needs troubleshooting.

### Command Line

```bash
source venv/bin/activate

# Detect videos on a page
python3 backend/downloader.py detect "https://www.youtube.com/watch?v=..."

# Download best quality
python3 backend/downloader.py download "https://www.youtube.com/watch?v=..."

# Download a copied m3u8 while preserving the original page as Referer
python3 backend/downloader.py download \
  "https://cdn.example/video/index.m3u8" \
  best \
  --referer "https://site.example/watch/page"

# Choose a container
python3 backend/downloader.py download "https://example.com/watch" best --output-format mkv

# Reuse Chrome cookies
python3 backend/downloader.py detect "https://example.com/watch" --cookies-from-browser chrome

# Diagnose the local backend environment
python3 backend/downloader.py diagnose --output-dir ~/Downloads/VideoDownloader
```

## Test

```bash
# Deterministic local tests
make test

# Swift state and queue-recovery tests only
make test-swift

# Real-world smoke matrix; depends on current network and site behavior
make test-live

# Probe one newly discovered site without downloading the full video
make test-url URL="https://example.com/watch/page"

# Filter live tests, use a proxy, and fail on expectation regressions
make test-live LIVE_ARGS='--group new-user-sites --proxy http://127.0.0.1:7890 --strict'
```

The local suite covers compact queue recovery, multi-link extraction, direct-link batch import, isolated detection failures, batch-wide progress accounting, exact retry behavior, recoverable stops, HLS playlist detection, Referer/Origin-protected segments, ffmpeg fallback, and playable MP4/MKV verification.

Live tests are intentionally separate. Websites change, block, rate-limit, expire media URLs, or require regional/session access. The matrix classifies outcomes as media, guidance-required, protected/unsupported, timeout, or failure.

## Continuous Integration

GitHub Actions runs the deterministic quality gate on pushes and pull requests: install dependencies, compile Python backend files, run `make test`, and build the macOS app bundle. Live website tests remain manual because external sites are volatile.

The CI also runs `make package` and uploads the generated zip plus checksum as a short-lived Actions artifact for testing.

## How It Works

```text
SwiftUI app
  -> Python backend
    -> yt-dlp metadata extraction
    -> HTML / iframe scan
    -> Playwright or Chrome network sniffing
    -> yt-dlp + ffmpeg download, merge, remux, convert
  -> ffprobe validation
  -> playable file in ~/Downloads/VideoDownloader
```

For implementation details, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Project Structure

```text
video-downloader/
├── VideoDownloader/              SwiftUI macOS app
│   ├── Sources/
│   │   ├── App.swift             app entry point
│   │   ├── ContentView.swift     main interface
│   │   ├── ViewModel.swift       state, queue, Python bridge
│   │   └── Models.swift          Codable data models
│   └── Resources/                Info.plist and app icon assets
├── backend/
│   ├── downloader.py             detect, capture, diagnose, download
│   ├── network_sniffer.py        browser media sniffing
│   ├── capture_proxy.py          local capture helper
│   ├── live_site_test.py         real-world smoke matrix
│   ├── self_test.py              deterministic local HLS test
│   └── site_tests.json           maintained website samples
├── docs/
│   ├── ARCHITECTURE.md
│   └── AGILE_LOG.md
├── tests/
│   └── QueuePersistenceSelfTest.swift
├── Makefile
└── README.md
```

## Tech Stack

| Layer | Technology |
| --- | --- |
| App UI | SwiftUI, AppKit integration |
| State and task orchestration | Swift, Combine, UserDefaults snapshots |
| Detection and download backend | Python 3 |
| Extractor | yt-dlp |
| Merge, remux, transcode | ffmpeg |
| Playback validation | ffprobe |
| Browser sniffing | Playwright, Chrome/CDP |
| Automation | Makefile |

## Responsible Use

Use this app only for media you own, created, are licensed to save, or otherwise have permission to download. Respect copyright, platform terms, account rules, and local law. Video Downloader does not decrypt DRM or bypass access controls.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Commit messages in this repository should be bilingual:

```text
Improve task center recovery / 改进任务中心恢复能力
```

For site failures, please open a "Site download failure / 网站下载失败" issue and paste the app's copied support report. Structured reports make real-site fixes much faster.

## License

[MIT](LICENSE)
