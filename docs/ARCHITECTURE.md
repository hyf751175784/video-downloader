# Video Downloader Architecture

## Goal

Build a simple macOS app where the user pastes a webpage URL, the app detects downloadable media, and the backend downloads a normal video file, preferably MP4.

The app does not decrypt DRM, bypass paywalls, or guarantee downloads from sites that forbid automated access.

## Runtime Flow

1. SwiftUI collects URL, output folder, output format, proxy settings, optional Chrome cookie reuse, and optional browser capture requests.
2. Swift launches `backend/downloader.py` from the bundled Python venv.
3. Backend detection tries these strategies in order:
   - direct media URL such as `.m3u8`, `.mp4`, `.mpd`;
   - `yt-dlp -J` metadata extraction with optional Chrome cookies;
   - browser impersonation for anti-bot pages;
   - HTML and iframe scan for embedded media URLs;
   - Playwright network sniffing for pages that create video URLs in JavaScript;
   - Chrome/CDP network sniffing if Playwright capture does not find media;
   - visible Chrome/CDP capture when the user clicks Capture for pages that need a real browser challenge/playback step.
4. Backend download uses `yt-dlp` and ffmpeg:
   - HLS/m3u8 fragments are downloaded and merged;
   - DASH audio/video tracks are merged;
   - final output is remuxed to the requested container when possible;
   - ffprobe verifies that the completed file has readable audio/video streams.
5. During downloads, the backend can emit prefixed JSON progress events on stderr. The SwiftUI app reads those events while preserving stdout for the final result JSON.
6. SwiftUI extracts the JSON object defensively, so incidental command output does not immediately become a decode failure.
7. SwiftUI renders a richer progress snapshot from backend progress events, including stage, percent, speed, ETA, downloaded/total labels, and final validation status.
8. SwiftUI records successful and failed attempts in local `UserDefaults` JSON so the user can retry a URL or reveal a completed file.

## Directory Map

```text
VideoDownloader/
  Sources/          SwiftUI app, state model, Python bridge
  Resources/        Info.plist, AppIcon.icns, and generated icon preview
backend/
  downloader.py     Main detect/download CLI used by the app
  network_sniffer.py Browser-based media URL capture fallback
  capture_proxy.py  Experimental local capture proxy
  generate_icon.py  Rebuilds AppIcon.icns and AppIcon.preview.png
  self_test.py      Local HLS smoke test
  live_site_test.py Real-world detection/probe matrix runner
  site_tests.json   Maintainable live website sample catalog
docs/
  ARCHITECTURE.md   This file
  AGILE_LOG.md      Iteration notes and next backlog
Makefile            Build, run, test automation
```

## Test Layers

`make test` is deterministic and local. Its Swift state layer verifies compact queue persistence, multi-link extraction, direct-link batch import, and sequential webpage batch detection where one synthetic failure does not stop later items. Its backend layer generates a tiny HLS fixture, exercises webpage/iframe detection, enforces Referer-protected segment access, downloads and merges segments, and validates playable MP4/MKV output.

`make test-live` is intentionally separate because external sites, DNS, proxies, anti-bot pages, expiring URLs, and platform protection are volatile. It reads `backend/site_tests.json`, runs each configured URL through the real detection stack, classifies the outcome, and can probe only the first 4096 bytes of the first media candidate. The probe uses browser-like headers, Referer/Origin, curl when available, and a clearly marked TLS fallback for unusual CDN certificate chains. `make test-url URL=...` runs the same workflow for one ad-hoc URL. Both Make targets accept `LIVE_ARGS` for filters, proxies, cookies, JSON output, or strict expectation enforcement.

## Proxy Model

Proxy is opt-in from the UI. When enabled, Swift passes `--proxy http://host:port` to the backend. The backend also sets `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, and `https_proxy` for child processes.

## Cookies And Anti-Bot Pages

The Chrome cookies switch is opt-in. When enabled, Swift passes `--cookies-from-browser chrome` to both detection and download. This is useful for pages that play in the user's Chrome session but block unauthenticated automation. The backend also tries yt-dlp browser impersonation for generic pages when the installed `curl_cffi` version supports it.

## Bilibili Handling

The backend normalizes long Bilibili mobile/WeChat share URLs to canonical `https://www.bilibili.com/video/BV...` pages before calling yt-dlp. Detection and download also add Bilibili-specific retry settings and prefer Chrome cookies when no explicit cookie source is provided.

## Browser Capture

The Capture button runs the backend `capture` command. It opens a controlled Chrome window with CDP network capture enabled, navigates to the page, periodically nudges likely play controls, and records media requests while the user can solve challenges or click play. This window uses its own persistent profile under `~/Library/Application Support/VideoDownloader/ChromeCapture`, so challenge/session state can survive across capture attempts without reading the user's daily Chrome profile. Captured candidates are filtered and ranked before returning to SwiftUI: placeholder assets such as `empty.mp4` are dropped, HLS/DASH playlists are preferred, and the original page is stored as Referer for download.

Captured candidates also carry the source page title when the browser can read it. Static HTML detection, Playwright sniffing, and visible Chrome capture all prefer readable page metadata such as `og:title`, `twitter:title`, `name=title`, `h1`, and common player/title nodes before falling back to `document.title`. This keeps hard-site results readable when the actual media URL is a generic CDN path such as `hd.mp4` or `chunklist.m3u8`.

The capture layer and downloader both inspect URL query parameters such as `fname`, `filename`, `name`, and `title` when classifying media. This matters for CDN links where the path is opaque but the real media filename appears as `?fname=hd.mp4`; those links are now detected as MP4 candidates and keep the original page as Referer.

## Input Normalization

SwiftUI routes paste, menu paste, text submit, drag-and-drop, normal detection, and browser capture through the same URL extraction helper. Rich mobile/share text is stripped of surrounding Chinese/English punctuation and duplicate URLs are removed.

For normal detection, several pasted URLs start a sequential batch with a maximum of 50 items. Each page runs through the existing backend detection stack, only its recommended first candidate is added to the download queue, and a failed page is recorded without stopping later items. The UI exposes current URL, completed/total progress, added, failed, and skipped counts. Multiple direct-media URLs use a faster path that validates and queues them immediately while preserving the optional Referer. Visible browser capture remains intentionally single-page because it requires interactive user attention.

The remaining unprocessed webpage URLs are persisted separately from the download queue before batch work starts and after every completed page. Cancelling or quitting leaves the current and later URLs in that snapshot. On relaunch, the result strip offers an explicit Continue Detection action; restored detection work never starts without the user.

## Smart Site Hints

The URL surface includes a small UI-only hint layer. It inspects the current host and mode to identify common workflow choices: Bilibili prefers Chrome cookies, novipnoad/yfsp-style dynamic players prefer browser capture, direct media URLs can switch into direct mode, and direct mode can prompt for a missing Referer. These hints do not change backend behavior by themselves; they expose the next useful user action while keeping detection and download logic centralized in the Python backend.

## Start Surface

The idle state is an action-first start surface rather than a blank placeholder. It keeps the same primary workflow available through the URL bar while also exposing paste-detect, browser capture, diagnostics, and history actions inside the main stage. Capability badges summarize the active tool surface without changing backend behavior.

## Settings Surface

The main window keeps the highest-frequency choices visible: proxy state, output container, output directory, and an advanced-settings entry with a small enabled-option count. The dedicated settings sheet groups output, network/access, and task behavior without crowding the primary detect/download workflow. It is available from the toolbar, main settings strip, and native macOS `⌘,` command.

Network options that affect backend launch arguments are locked while detection or download is active. A UI-test launch argument can open the settings sheet directly for repeatable screenshot inspection without requiring Accessibility permission.

## Progress Model

The backend emits prefixed JSON progress events during downloads. The UI turns these into a `ProgressSnapshot` with a linear progress bar, current stage, speed, ETA, and validation detail. The progress surface also presents a compact activity console: current phase, downloaded amount, speed, ETA, and an icon timeline for parse/download/merge/package/validate. For multi-item runs, a second progress model combines finished tasks with the current task's fractional progress to show current position and batch-wide completion. This avoids the older single-number progress display where the user could not tell whether the app was downloading, merging, remuxing, converting, checking playback compatibility, or how much of the full queue remained.

## Download Task Center

The Swift ViewModel owns one `activeDownload`, a restorable `downloadQueue`, and a persistent `failedDownloads` retry list. A normal candidate download starts immediately, while the queue action collects several selected candidates without hiding the result list. The task center can start the waiting list, promote any pending item to run next, remove or clear pending items, stop the current task while preserving it at the front of the waiting list, retry one or all failed tasks, or automatically continue after each success or failure. Downloads remain sequential so yt-dlp/ffmpeg work does not overwhelm the network or the Mac.

The current task and aggregate waiting count are visible in both the main task strip and the task-center sheet. The main progress console also shows the active video's readable title, which keeps stage, percentage, and file identity connected during long merge or conversion steps.

Run totals are reconciled against the active task and waiting queue. Waiting tasks count toward the active run only while automatic continuation is enabled; toggling that option or adding/removing waiting tasks updates the batch total immediately. Successes and failures both count as processed work, so overall progress remains monotonic and reaches 100% after a mixed-result batch.

When a run stops naturally, the ViewModel exposes an explicit terminal-run context. Completion and failure views use it to show processed/success/failure totals and choose the correct next action. A download failure retains the exact `DownloadQueueItem`, so the primary retry action restarts the same media URL, Referer, and selected format; a detection failure keeps the separate retry-detection/capture workflow. Starting a new detection clears stale terminal download context.

When automatic continuation is active, intermediate successes are recorded in history without repeatedly bringing Finder to the foreground. The final successful item still reveals its output, preserving the convenient single-download behavior without interrupting a batch.

Queue persistence uses compact `PersistedQueueItem` snapshots instead of serializing full extractor metadata and format catalogs. Each snapshot stores only the task ID, readable title, source URL, Referer, selected format, and enqueue time. The current task is included in the snapshot, so an app quit or crash restores it as a waiting task rather than silently losing it. Restored items never auto-start without the user.

The same compact snapshot shape backs the failed-task retry list. A failed task is deduplicated by media URL and format, capped at 50 entries, and removed when it is retried or later succeeds. This preserves exact retry inputs without forcing the user through another detection pass.

On normal app termination, the AppDelegate asks the ViewModel to persist the current snapshot and terminate the active backend process without clearing the active task. This prevents an invisible orphan download while preserving the work for an explicit restart on the next launch.

The ViewModel tracks success and failure totals for the current run. When notifications are enabled and the run stops naturally, macOS receives a single completion notification; intermediate tasks do not produce notification noise. The AppDelegate presents banners even while the app is frontmost, and the task center includes a test-notification action so permission and presentation behavior are easy to verify.

When the persisted keep-awake option is enabled, `setActiveProcess` owns a `ProcessInfo` activity token with idle-system-sleep prevention while a real backend process exists. The token is released on process exit, cancellation, option disable, or app termination. This protects long downloads without keeping the Mac awake merely because the app window is open.

## Completion Summary

After ffprobe validation, the backend returns a compact media summary with duration, video codec, audio codec, and compatibility status. The completion view presents these as small result tags so the user can confirm the file is not only present but also Mac-playable.

## Manual Media Fallback

When automatic detection fails but the user has copied a media URL from browser developer tools, direct mode downloads that `.m3u8`, `.mp4`, `.mpd`, or similar URL. The optional Referer field is persisted and passed to yt-dlp as `--referer`, which helps hosts that reject playlist or segment requests without the original page URL.

For captured/direct media URLs, the backend also derives browser-style request headers from the media URL and Referer: Origin, Range, Accept, language, and Fetch metadata. If yt-dlp still cannot open a direct media URL, the backend retries through ffmpeg with the same header set, then sends the result through the normal remux/transcode and ffprobe validation pipeline. This does not bypass DRM or regional access controls; volatile CDNs may still reject a request based on location, session, or network fingerprint.

## Diagnostics

The backend exposes `diagnose`, a JSON command that checks Python, yt-dlp, browser impersonation, ffmpeg, output directory writeability, proxy reachability, Playwright importability, system Chrome, bundled sniffer scripts, the current Referer value, and cookie-source state. The macOS app presents this as a compact diagnostics sheet from the toolbar.

The diagnostics sheet can also copy a support report. That report is generated on the Swift side and combines current app state, output/proxy/cookie settings, run counters, active/waiting/failed queue summaries, pending detection state, recent history errors, recent app log lines, and the latest diagnostics result. It intentionally stays plain text so it can be pasted into an issue, chat, or bug report without creating files on disk.

## Metadata Robustness

The backend normalizes duration from multiple common fields, including `duration`, `duration_string`, `timelength`, and millisecond-style duration keys. The Swift models also decode numeric metadata defensively because real extractor output may mix integers, floats, strings, and null values.

## Process I/O Reliability

Every Swift-launched backend process drains stdout and stderr while the child is running. Plain detection/capture/diagnostic commands read both pipes concurrently on background queues; download commands continuously read stdout while the stderr collector separates prefixed progress events from normal error output. This prevents the OS pipe buffer from filling and deadlocking large extractor results.

Collected stdout is bounded at 64 MB and oversized results fail with an explicit message. Verbose stderr is bounded at 2 MB while retaining its tail, where extractors usually place the actionable failure. Final stderr bytes without a newline are preserved. Launch failures cancel timers and close pipe writers so reader tasks return promptly.

## History

The app keeps a lightweight local history of recent attempts. Each record stores title, URL, output format, status, optional file path, optional Referer, error text, size, and timestamp. History is capped in the ViewModel to keep `UserDefaults` small.

## Candidate Ranking

Detected candidates are already ranked by the backend. The SwiftUI result view treats the first candidate as the recommended option, exposes a one-click recommended download action, marks the first card, and previews the output filename using the current output format. This makes dynamic-site results easier to act on when several media URLs are captured.

## Format Policy

Default output is MP4. The app can also request MKV/WebM. The backend asks yt-dlp to merge/remux into the requested container, then verifies the newest media file with ffprobe. Container and codec compatibility are checked separately: MP4 output must use common Mac/QuickTime-friendly codecs such as H.264 video and AAC audio. If the result is the wrong container, unreadable, or uses incompatible codecs, the backend tries ffmpeg copy remux first when possible, then a conservative transcode.

For direct or captured media URLs, the backend derives a safe output filename from URL metadata such as `fname`, `filename`, `name`, or `title`. The Mac app also passes the detected candidate title as `--title` during download. This keeps hard-site downloads readable and avoids token-like CDN filenames or generic playlist names when the source page exposes a useful episode/page name.

## Output Resolution

yt-dlp is asked to print the final `after_move:filepath`. The backend also parses common yt-dlp log lines such as destination, merge target, remux target, and already-downloaded messages. Only if those paths are unavailable does it scan the output folder. This prevents false "file not found" errors when yt-dlp reuses an existing file or does not update mtime.

## Quality Selection

Some extractors expose video-only and audio-only formats. When the macOS UI downloads a selected video-only quality, it sends a format expression that combines that video format with `bestaudio`. This avoids the common DASH/Bilibili/YouTube failure mode where a user-selected "1080p" file is missing audio or is awkwardly packaged.
