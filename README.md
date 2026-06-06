# 🎬 Video Downloader

Simple macOS app to detect and download videos from any URL.

**Paste URL -> Detect -> Download MP4/MKV/WebM**

## Features

- **Auto-detect** videos from webpages and direct media URLs.
- **Layered fallback**: yt-dlp first, then HTML/iframe scan, then Playwright/Chrome network sniffing for script-heavy players.
- **M3U8/HLS support**: downloads segments and merges them through yt-dlp/ffmpeg.
- **Common output**: MP4 by default, with MKV/WebM output available from the Mac app.
- **Playable-file guard**: completed downloads are checked with ffprobe and repaired with remux/transcode when needed.
- **Completion summary**: finished downloads show duration, video codec, audio codec, and playback compatibility.
- **Mac-compatible MP4**: MP4 output is forced toward H.264/AAC when the downloaded codecs are not player-friendly.
- **Audio-safe quality selection**: selecting a video-only quality automatically adds the best audio track.
- **Proxy switch**: configure `host:port` in the Mac app and download with or without proxy.
- **Chrome cookies switch**: reuse your local Chrome session for Cloudflare or login-gated pages.
- **Browser capture mode**: open a controlled Chrome window and capture media requests while the page plays.
- **Candidate ranking**: placeholder assets such as empty player MP4 files are filtered out; m3u8/MPD playlists are preferred.
- **Multi-link paste**: paste or drop several webpage URLs at once; the app detects them sequentially, queues each recommended candidate, and isolates failures instead of stopping the batch.
- **Restorable detection batches**: cancelling, quitting, or reopening preserves the remaining unprocessed webpage links and offers a one-click continue action.
- **Share-text URL extraction**: rich share text is deduplicated and stripped of surrounding Chinese/English punctuation before detection.
- **Smart site hints**: the URL area recognizes common cases such as Bilibili, dynamic players, media direct links, and missing Referer, then surfaces the next useful action.
- **Action-first start screen**: the empty state exposes paste-detect, browser capture, diagnostics, history, and key capability badges.
- **Recommended candidate action**: the first ranked candidate is surfaced as the recommended download with a filename preview.
- **Readable titles**: captured media can inherit titles from `og:title`, `twitter:title`, `h1`, player title nodes, or the browser page title instead of showing generic names like `hd.mp4`.
- **Readable output names**: the Mac app passes detected titles to the backend, so captured playlists can save as episode/page names instead of `chunklist.mp4`.
- **Richer progress console**: detection, capture, download, merge, remux/convert, and validation stages are shown with current activity, amount, speed, and ETA metrics.
- **Batch-wide progress**: long queues show the current item number, overall completion percentage, success/failure totals, and waiting count alongside the current video's progress.
- **Actionable run summaries**: completed and failed runs show processed/success/failure totals; download failures retry the exact retained media task instead of repeating webpage detection.
- **Download task center**: collect candidates into a restorable queue, review the current and waiting tasks, promote the next item, remove pending items, and download sequentially with optional automatic continuation; Finder waits until the batch finishes instead of interrupting after every file.
- **Crash-safe queue recovery**: waiting and interrupted download tasks are stored as compact snapshots and restored after the app reopens.
- **Recoverable stops and failures**: stopping a download puts the exact task back at the front of the queue, while failed tasks keep their media URL, Referer, and selected quality in a persistent retry section.
- **Completion notifications**: optional macOS notifications summarize single downloads and batch success/failure totals.
- **Keep-awake guard**: optionally prevents idle system sleep only while a real detect/capture/download backend task is running.
- **Focused settings surface**: the main window keeps only proxy, format, and output-folder shortcuts; advanced network and task behavior lives in a dedicated settings sheet available from the toolbar or `⌘,`.
- **Copy fallback**: detected media URLs and Referer headers can be copied from the candidate list.
- **Clean captured filenames**: direct/captured URLs with names such as `fname=hd.mp4` save as `hd.mp4`, not long CDN token paths.
- **Query-aware capture**: media URLs whose real filename only appears in query params, such as `?fname=hd.mp4`, are detected and labeled correctly.
- **Faster Mac actions**: paste-and-detect, play completed/history files, reveal in Finder, and copy URLs/paths.
- **Bilibili share cleanup**: long mobile/WeChat share URLs are normalized to the canonical Bilibili video page.
- **Manual media fallback**: direct m3u8/mp4/mpd download can include the original page Referer.
- **Strict-CDN media headers**: captured/direct media downloads add Referer, Origin, Range, and browser-style fetch headers when appropriate.
- **ffmpeg direct fallback**: if yt-dlp cannot open a captured m3u8/mp4 URL, the backend retries through ffmpeg before reporting failure.
- **Diagnostics panel**: checks yt-dlp, ffmpeg, output folder, proxy, Playwright/Chrome sniffing, and Referer, with one-click result copy.
- **Live site test matrix**: maintain real-world website samples and classify each result as media, capture/cookie guidance, protected/unsupported, timeout, or failure.
- **Ad-hoc site testing**: run `make test-url URL=...` to detect and lightly probe a new site without downloading the full video.
- **Download history**: successful and failed attempts are saved locally, with retry and Finder actions.
- **Robust JSON handling**: the Mac app tolerates noisy backend output and mixed numeric/string metadata.
- **Non-blocking backend pipes**: detection, capture, diagnostics, and downloads continuously drain stdout/stderr so large format catalogs or verbose extractor logs cannot deadlock the app.
- **Native macOS UI**: SwiftUI app with dark mode support.
- **Polished generated icon**: the icon is generated from code as a macOS squircle with player glass, capture rings, media fragments, download arrow, and playback-check badge.
- **Organized output**: saves to `~/Downloads/VideoDownloader/` by default.

## Installation

### Prerequisites

- **macOS 14.0+**
- **[Homebrew](https://brew.sh)** (for ffmpeg)
- **Xcode** (for building the app)

### Quick Start

```bash
# Clone or enter the project directory
cd video-downloader

# Install dependencies
make install-deps

# Build and run
make run
```

### Manual Setup

```bash
# 1. Install system dependencies
brew install ffmpeg

# 2. Create Python virtual environment
python3 -m venv venv
source venv/bin/activate
pip install -r backend/requirements.txt certifi

# 3. Build the Mac app
make build

# 4. Launch
open build/VideoDownloader.app
```

## Test

```bash
make test

# Run only the compact queue snapshot/state test
make test-swift

# Real-world detection matrix; can be slow and depends on current network/site behavior
make test-live

# Test a newly discovered website without downloading the full video
make test-url URL="https://example.com/watch/page"

# Run only one live-test group, through a proxy, and fail on expectation regressions
make test-live LIVE_ARGS='--group new-user-sites --proxy http://127.0.0.1:7890 --strict'
```

The default test suite is local: the Swift state test verifies compact queue recovery, multi-link extraction, direct-link batch import, sequential webpage batch detection with isolated failures, batch-wide progress accounting, terminal exact-task retry, resumable stops, and persisted recovery. The backend test then generates a tiny HLS/m3u8 fixture, verifies webpage/iframe m3u8 detection, downloads Referer-protected segments, and verifies merged MP4/MKV output.

`make test-live` reads `backend/site_tests.json`. It runs detection and optionally fetches only the first 4096 bytes of the first media candidate. The matrix includes dynamic sites, Bilibili/YouTube samples, protected-platform behavior, and user-requested samples such as huavod, xiaoyakankan, iQIYI, and nnyy. Sensitive-domain cases are skipped unless explicitly requested.

## Usage

### GUI (Mac App)

1. Launch `VideoDownloader.app`
2. Paste one video URL, or several URLs to detect and queue them as a batch
3. Click **Detect** (or press ⌘↵)
4. Select quality from the dropdown
5. Click ⬇️ to download
6. Or click the queue icon on several candidate cards, then start them together from the task center
7. File opens in Finder when done
8. Use the history button to retry failed attempts or reopen completed files
9. Open **Settings** from the gear button or press **⌘,** to configure cookies, notifications, queue behavior, and keep-awake mode

### CLI (Command Line)

```bash
source venv/bin/activate

# Detect videos
python3 backend/downloader.py detect "https://www.youtube.com/watch?v=..."

# Download best quality
python3 backend/downloader.py download "https://www.youtube.com/watch?v=..."

# Download specific format
python3 backend/downloader.py download "https://..." 137 --output-dir ~/Videos

# Download a copied m3u8 while preserving the original page as Referer
python3 backend/downloader.py download "https://cdn.example/video/index.m3u8" best --referer "https://site.example/watch/page"

# Choose a common output container
python3 backend/downloader.py download "https://..." best --output-format mkv

# Reuse Chrome cookies for pages that play in your browser but block bots
python3 backend/downloader.py detect "https://..." --cookies-from-browser chrome

# Diagnose the local backend environment
python3 backend/downloader.py diagnose --output-dir ~/Downloads/VideoDownloader --referer "https://site.example/watch/page"
```

## How It Works

```
User URL → yt-dlp (extract) → Python backend (JSON) → SwiftUI (display)
                ↓
        yt-dlp + ffmpeg (download + merge + remux/convert to MP4)
                ↓
        ~/Downloads/VideoDownloader/video.mp4
```

### Detection Strategy

1. If the input is already a media URL (`.m3u8`, `.mp4`, `.mpd`, etc.), use it directly.
2. Try `yt-dlp` metadata extraction with Chrome cookies when enabled.
3. Retry anti-bot pages with browser impersonation when available.
4. If that fails, fetch HTML and embedded iframes to find media URLs.
5. If still empty, use Playwright/Chrome to load the page and sniff network requests.
6. For Cloudflare pages that block automation, use the app's Capture button, let the visible Chrome window load/play the video, then download the captured playlist.

This helps with novipnoad/yfsp-style pages where the m3u8 is created by JavaScript after the player loads. Captured candidates are ranked so real HLS/DASH playlists beat placeholder assets such as `empty.mp4`.

### M3U8 / HLS Handling

1. yt-dlp parses `.m3u8` playlist → finds all `.ts` segments
2. Downloads each segment
3. ffmpeg concatenates all segments into one MP4
4. Result: single, playable MP4 file

### Format Conversion

The Mac app defaults to MP4 and can also request MKV/WebM. The backend asks yt-dlp to merge/remux, then verifies the final file with ffprobe. MP4 output is checked for common QuickTime-compatible codecs; incompatible codecs are transcoded to H.264/AAC.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI (macOS native) |
| Video Engine | [yt-dlp](https://github.com/yt-dlp/yt-dlp) |
| Format Conversion | [ffmpeg](https://ffmpeg.org) |
| Backend Script | Python 3 |
| Build | swiftc + make |

## Project Structure

```
video-downloader/
├── VideoDownloader/           # SwiftUI Mac App
│   ├── Sources/
│   │   ├── App.swift          # App entry point
│   │   ├── ContentView.swift  # Main UI
│   │   ├── ViewModel.swift    # State + Python bridge
│   │   └── Models.swift       # Data models
│   └── Resources/
│       └── Info.plist
├── backend/
│   ├── downloader.py          # Core: detect + download
│   ├── network_sniffer.py     # Browser network fallback
│   ├── capture_proxy.py       # Experimental local capture proxy
│   ├── generate_icon.py       # App icon generator
│   ├── self_test.py           # Local HLS smoke test
│   ├── requirements.txt
│   └── install.sh
├── docs/
│   ├── ARCHITECTURE.md
│   └── AGILE_LOG.md
├── tests/
│   └── QueuePersistenceSelfTest.swift
├── Makefile                   # Build automation
└── README.md
```

## Notes

Use this for videos you own or have permission to download. The app does not decrypt DRM or bypass access controls.

## FAQ

### "yt-dlp not found" error?
Run `make install-deps` first. This creates a Python venv with yt-dlp installed.

### Download is slow?
Large videos (4K, long duration) take time. yt-dlp downloads at the server's max speed.

### Some sites don't work?
yt-dlp supports 1000+ sites but some may require cookies or have DRM. For sites requiring login, use CLI with `--cookies-from-browser`.

### How to update yt-dlp?
```bash
source venv/bin/activate
pip install --upgrade yt-dlp
```

## License

MIT — Use freely, at your own risk. Respect copyright and terms of service of video platforms.
