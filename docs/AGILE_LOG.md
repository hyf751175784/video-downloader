# Agile Log

## 2026-06-04 Iteration

### Shipped

- Added a lightweight download task center with one active task, a sequential waiting queue, optional automatic continuation, pending-item removal, current-task stop, and waiting-list clear controls.
- Added queue actions to candidate cards, a toolbar task-count badge, a persistent current-task strip, and the active video's title inside the detailed progress console.
- Made queue controls distinguish stopping the current task from clearing pending tasks, and delayed Finder reveal until the final item so batches do not repeatedly steal focus.
- Added a one-click "run next" action for pending queue items.
- Added compact queue snapshot persistence so waiting and interrupted tasks return after app relaunch without storing oversized extractor metadata.
- Added optional macOS completion notifications and live success/failure totals in the task center.
- Added app-termination handling that stops the active backend process while preserving its task for recovery on the next launch.
- Added foreground notification presentation and a one-click test-notification action in the task center.
- Added multi-link paste/drop detection: webpage URLs are detected sequentially, each recommended candidate is queued, failures are isolated, and batches are capped at 50 links.
- Added immediate multi-direct-link queue import with Referer preservation.
- Added a batch progress/result strip with current URL, completed/total, queued, failed, skipped, open-task-center, start-download, and dismiss actions.
- Locked conflicting input actions while detection is running so return/paste/capture cannot replace an active batch.
- Persisted remaining batch-detection URLs across cancel, quit, and relaunch, with an explicit continue-detection action.
- Replaced the dense main settings strip with a compact proxy shortcut, output format, output directory, and a full settings sheet for advanced network/output/task behavior.
- Added a native `⌘,` settings command, a clear settings-sheet close action, an enabled-option count on the compact settings entry, and task-time locking for backend-affecting network switches.
- Added an opt-out keep-awake guard backed by a `ProcessInfo` activity token that exists only while a backend task is running.
- Made stopping a download recoverable by returning the exact active task to the front of the waiting queue instead of discarding it.
- Added a persistent failed-task retry section that preserves media URL, Referer, and selected quality, with single-task and retry-all actions plus a visible main-window recovery bar.
- Made the compact active-task progress strip show the real backend stage such as merge, conversion, or validation instead of always saying download.
- Added batch-wide progress across the compact task strip, full progress console, metric row, and task center, including current item number, overall percentage, success/failure totals, and waiting count.
- Reconciled active-run totals when automatic continuation is toggled or waiting tasks are added/removed, so only tasks expected to continue are included.
- Compressed the working-state layout so batch-wide progress, current progress, metrics, and the complete stage timeline remain visible together at the default window size.
- Added terminal run summaries to completion and failure views with processed/success/failure totals and direct access to failed-task recovery.
- Separated download-failure recovery from detection-failure recovery: download failures now restart the exact retained media task, while detection failures continue to offer re-detection, direct-link, and browser-capture paths.
- Reworked all Swift backend process execution to continuously drain stdout and stderr, preventing large detection results or verbose extractor logs from filling OS pipes and deadlocking.
- Bounded collected stdout/stderr, retained actionable stderr tails including final bytes without newlines, preserved live download progress parsing, and cleaned up timers/readers after process launch failures.
- Added `backend/site_tests.json`, a maintainable real-world website matrix covering novipnoad, yfsp, Bilibili, YouTube, huavod, xiaoyakankan, iQIYI, nnyy, and an opt-in sensitive-domain sample.
- Added `backend/live_site_test.py` to classify live outcomes as media, guidance-required, protected/unsupported, timeout, or failure without downloading full videos.
- Added optional first-media Range probes with Referer, Origin, browser-like headers, certifi/TLS fallback, and curl-first probing for strict anti-hotlink CDNs.
- Added `make test-live` for the configured matrix and `make test-url URL=...` for fast ad-hoc website testing.
- Added `LIVE_ARGS` support for live-test grouping, proxy/cookie options, JSON reports, and strict expectation enforcement.
- Bundled the live test runner and site catalog inside the macOS app resources.
- Added one-click diagnostic result copying from the macOS diagnostics sheet.
- Added browser-style Origin/Range/Fetch headers for captured/direct media downloads and an automatic ffmpeg direct-media fallback when yt-dlp is rejected.
- Strengthened the deterministic HLS self-test so playlist/segment requests require both the correct Referer and Origin, and added playable-output coverage for the ffmpeg fallback.

### Verification Notes

- Swift queue persistence self-test passed: a candidate carrying 500 formats and large extractor metadata produced a compact 349-byte snapshot and restored its selected format, title, URL, and Referer.
- Swift state tests passed for URL deduplication/punctuation cleanup, valid/invalid direct-link batch isolation, and sequential webpage batch detection with two successes around one synthetic failure.
- Swift state tests verified that cancelling a slow synthetic batch preserves its remaining links and restores them in a new ViewModel.
- Swift state tests verified that a real synthetic backend process acquires the keep-awake activity and cancellation releases it promptly.
- Swift state tests verified that stopping an active download releases keep-awake and returns the exact task to the front of the queue, and that failed tasks persist and requeue with their original Referer/format.
- Visually inspected the failed-task recovery bar and task-center retry section with seeded QA tasks; retry controls, status badges, section layout, and toolbar rendered without overlap.
- Swift state tests verified mixed-result batch-wide progress, 100% completion, and total-count reconciliation when automatic continuation is toggled or waiting tasks are removed.
- Visually inspected seeded active-batch previews in the main progress console and task center; current/overall progress and the complete stage timeline fit at the default window size without overlap.
- Swift state tests verified terminal exact-task retry and confirmed that a new detection clears stale download-failure context.
- Visually inspected seeded mixed-result completion and exact-download-failure views; summaries, recovery actions, media tags, and guidance fit the default window without overlap.
- Swift execution tests simultaneously wrote roughly 4 MB stdout and 2.5 MB stderr through both normal and progress-aware process paths; both completed promptly, retained progress events and the no-newline stderr tail, and reported truncation. Invalid executable launch also returned promptly.
- Final deterministic `make test` passed after the non-blocking process-I/O work, including playable HLS/ffmpeg output verification.
- Final bundled diagnostics reported `ready` with zero failures, and strict platform live smoke tests passed 2/2 Bilibili/YouTube expectations.
- The final new-user-sites live run passed huavod and nnyy media probes; xiaoyakankan detection succeeded but its current CDN media probe returned an anti-hotlink `403`.
- Visually inspected the rebuilt main window and directly opened settings sheet; the compact configuration row, grouped settings, segmented format control, explanatory text, toggles, scrolling, and close/diagnostic actions rendered without overlap.
- Final deterministic `make test` passed after the settings and keep-awake polish.
- Final bundled diagnostics reported `ready` with zero failures, and strict platform live smoke tests passed 2/2 Bilibili/YouTube expectations after the settings polish.
- Final deterministic `make test`, bundled diagnostics (`ready`, zero failures), and strict platform live smoke tests (2/2 Bilibili/YouTube) passed after recoverable stops and failed-task retry were added.
- Final deterministic `make test`, bundled diagnostics (`ready`, zero failures), and strict platform live smoke tests (2/2 Bilibili/YouTube) passed after batch-wide progress and run-total reconciliation were added.
- Final deterministic `make test`, bundled diagnostics (`ready`, zero failures), and strict platform live smoke tests (2/2 Bilibili/YouTube) passed after terminal summaries and exact download-failure retry were added.
- Verified the full app recovery chain by writing a temporary real preference snapshot, quitting and reopening the app, observing the restored waiting-task badge/bar/log, then removing the temporary task.
- Verified normal app quit preserves the restored waiting task snapshot until it is explicitly cleared.
- Final notification-enabled app build passed after adding foreground banner presentation and the test-notification action.
- Final multi-link build passed; deterministic Swift tests covered compact queue recovery, direct batch import, sequential webpage detection with isolated failure, cancellation, and restored pending detection work.
- Final multi-link regression kept bundled diagnostics at `ready`, deterministic HLS/ffmpeg playable-output tests green, and strict Bilibili/YouTube live expectations at 2/2.
- Final bundled diagnostics reported `ready` with zero failures, and strict platform live smoke tests passed 2/2 Bilibili/YouTube expectations.
- Final `make build` passed after the task-center and queue-priority UI changes.
- Deterministic `make test` passed with Referer/Origin-protected HLS download, merge, ffmpeg fallback, and playable MP4/MKV verification.
- Bundled backend diagnostics reported `ready` with zero failures.
- Strict platform live smoke tests passed 2/2 expectations for the configured Bilibili and YouTube samples.
- Python compilation passed for all backend scripts.
- `make test-url URL=https://huavod.com/vodplay/123905-1-1.html` detected media and received a successful 206 MP4 probe.
- The new-user-sites group detected readable titles and media candidates for huavod, xiaoyakankan, and nnyy.
- huavod and nnyy m3u8 probes passed; xiaoyakankan initially exposed a strict 403 anti-hotlink rule, then passed with the curl/browser-header probe path.
- iQIYI returned a sniffed m3u8 in one run and timed out in another, so it remains a protected/volatile-platform expectation rather than a guaranteed media test.
- A full non-sensitive live matrix run passed 7/8 expectations: novipnoad guidance, yfsp, Bilibili, YouTube, huavod, iQIYI, and nnyy passed; xiaoyakankan remained a live failure because its CDN intermittently returned regional/anti-hotlink 403 responses even after successful detection.
- `make build`, deterministic `make test`, and bundled diagnostics passed after adding the live test resources.

## 2026-06-03 Iteration

### Shipped

- Reworked the SwiftUI layout into a wider tool-style interface with a clearer header, full-width URL bar, separate settings strip, and less crowded result area.
- Made Swift JSON decoding resilient to noisy backend output by extracting the first complete JSON object before decoding.
- Made Swift video/format models tolerate mixed int/double/string/null metadata from real extractors.
- Improved backend duration normalization across `duration`, `duration_string`, `timelength`, and millisecond duration fields.
- Replaced generic backend failures with actionable messages for Bilibili login/cookies, 403, Cloudflare, proxy, and direct m3u8 fallback cases.
- Confirmed the rebuilt app bundle can run diagnostics with yt-dlp, ffmpeg, Playwright, Chrome, sniffers, impersonation, and Chrome cookies available.
- Added ffprobe-based playable-file validation after every download.
- Added automatic remux/transcode repair when the requested output container is wrong or ffprobe cannot read media streams.
- Changed selected video-only formats to download as `format+bestaudio/best`, preventing many no-audio or awkward DASH outputs.
- Added ffprobe to backend diagnostics and strengthened the HLS self-test to assert playable MP4/MKV outputs.
- Added Bilibili mobile/WeChat share URL normalization and Bilibili-specific yt-dlp retry/fallback arguments.
- Corrected DNS/proxy failures so they are reported as network access issues instead of misleading cookie/login failures.
- Fixed false "output file not found" failures by reading yt-dlp's final filepath output and parsing existing-file/download/remux log lines before falling back to latest-file scans.
- Added media candidate ranking/filtering so placeholder player assets such as `empty2.mp4` are ignored and real m3u8/MPD playlists are preferred.
- Added a visible Chrome browser capture mode for Cloudflare/script-heavy pages that need the user to load or play the page before media requests appear.
- Made browser capture more human-friendly for Cloudflare pages by using a less automated visible Chrome launch, extending the UI capture timeout, returning soon after a strong media candidate appears, preserving captured Referer headers, and cleaning stale capture-profile locks.
- Added source-page title propagation so hard-site captures can show readable episode/page names instead of generic CDN filenames.
- Reworked the download progress UI into a linear bar with stage markers, percent, speed, ETA, and validation status.
- Refined candidate cards with source/format/capture badges, URL preview, Referer visibility, and a copy-media fallback action.
- Regenerated the app icon with a richer player/capture/fragments/download visual and fixed transparent overlay handling in the icon generator.
- Added paste-and-detect, completed-file playback, output path copy, and stronger error-page capture guidance.
- Added safe direct/captured output naming so URLs with `fname=hd.mp4` save as `hd.mp4` instead of token-like CDN paths.
- Passed detected candidate titles into downloads so captured playlists can save using readable page/episode names.
- Added history-row playback and copy-info actions.
- Added a recommended-candidate result action, first-card recommendation badge, and output filename preview.
- Added finished-file media summary tags for duration, video codec, audio codec, and playback compatibility.
- Unified paste, menu paste, drag-and-drop, submit, detection, and browser capture around one share-text URL extraction path.
- Made browser capture and backend media classification query-aware so CDN links with filenames such as `?fname=hd.mp4` are detected as real MP4 candidates.
- Upgraded the working/progress surface into a compact activity console with stage-specific icons, current phase wording, amount, speed, ETA, and a clearer parse/download/merge/package/validate timeline.
- Expanded hard-site title extraction across static HTML, Playwright sniffing, and visible Chrome capture to prefer `og:title`, `twitter:title`, `name=title`, `h1`, and common player/title nodes before generic media filenames.
- Added a smart URL hint strip that recognizes Bilibili, dynamic-player sites, direct media links, and missing Referer cases, then exposes the most useful next action without changing backend behavior.
- Reworked the idle state into an action-first start surface with paste-detect, browser capture, diagnostics, history, and compact capability badges.
- Upgraded the generated app icon with a smoother macOS squircle background, capture rings, player glass, media-fragment track, download arrow, and playback-check badge; the generator now also writes a 1024px preview PNG.

### Verification Notes

- `python3 -m py_compile` passed for backend scripts.
- `make build` passed and rebuilt `build/VideoDownloader.app`.
- Bundle diagnostics passed.
- Local HLS server self-test passed with playable MP4/MKV verification.
- Verified query-aware media classification with a synthetic `https://cdn.example/get?id=42&fname=hd.mp4` URL in both `downloader.py` and `capture_proxy.py`.
- Live proxy/site tests remain dependent on available non-sandbox network/proxy access.
- The `BV1zzRKBpEmp` link was normalized locally, but live detection through the configured proxy could not be completed because non-sandbox permission review timed out.
- Added a unit-level check for already-downloaded files whose mtime is older than the current run.
- Verified the yfsp sample now returns the real `chunklist.m3u8` as the first and only candidate, then downloads to a playable H.264/AAC MP4.
- Confirmed the novipnoad sample still returns Cloudflare 403 through normal yt-dlp/HTML/sniffer paths, then verified the Capture flow finds `hd.mp4` and downloads it to a playable H.264/AAC MP4.
- Re-verified the novipnoad sample browser capture on 2026-06-03: it returned two Tencent CDN MP4 candidates whose real filename is carried as `?fname=hd.mp4`, with page title and Referer preserved.
- Rebuilt the macOS app after the progress-console UI change and re-ran the local HLS self-test plus bundled diagnostics.
- Verified a synthetic `twitter:title` page title is cleaned to `灵魂摆渡·十年-02-`, and re-ran live yfsp detection to confirm the captured m3u8 still carries that readable title and Referer.
- Rebuilt the macOS app after the smart-hint UI change and re-ran the local HLS self-test plus bundled diagnostics.
- Rebuilt the macOS app after the start-surface UI change and re-ran the local HLS self-test plus bundled diagnostics.
- Regenerated `AppIcon.icns`, visually inspected the 1024px preview and a temporary 16/32/64/128/256px size sheet, verified `CFBundleIconFile=AppIcon`, and confirmed the rebuilt app bundle contains the updated icon.
- Verified the yfsp sample now carries the readable source title `灵魂摆渡·十年-02-`.
- Generated and visually inspected a 1024px icon preview after fixing a transparent-layer bug.
- Verified direct URL output templates produce `hd.mp4` and `chunklist.mp4` instead of duplicate extensions.
- Verified title hints produce readable output paths such as `灵魂摆渡·十年-02-.mp4`.
- Verified media summary extraction on a generated H.264/AAC MP4 returned duration, codecs, and `compatible`.

## 2026-06-02 Iteration

### Shipped

- Added layered detection fallback: direct media URL, yt-dlp, HTML/iframe scan, then browser network sniffing.
- Added m3u8/MPD/direct media handling as first-class detected videos.
- Added referer propagation for captured media URLs to reduce 403 failures.
- Improved proxy handling by preserving the process environment and setting both upper/lower proxy variables.
- Normalized download output toward MP4 with yt-dlp/ffmpeg remux and fallback conversion.
- Added editable proxy controls in the macOS UI.
- Persisted output folder and proxy settings in the ViewModel.
- Added live yt-dlp progress events and wired them into the SwiftUI download state.
- Made the Stop button terminate the active Python/yt-dlp process instead of only cancelling UI state.
- Replaced the external-network `make test` with a local HLS self-test that generates m3u8 segments and verifies MP4 output.
- Connected the Chrome/CDP network sniffer as a second browser fallback after Playwright.
- Expanded the local self-test to cover webpage -> iframe -> embedded m3u8 detection.
- Added a direct media fallback in the UI with a persisted Referer field for copied m3u8/mp4/mpd URLs.
- Strengthened the local HLS self-test so playlist/segment requests require the correct Referer.
- Added backend `diagnose` and a macOS diagnostics sheet for yt-dlp, ffmpeg, output directory, proxy, Playwright/Chrome, sniffers, and Referer.
- Added an app-level output format picker for MP4/MKV/WebM and wired it to the backend.
- Expanded the local HLS self-test to verify MP4 and MKV outputs.
- Added local download history for successful and failed attempts, with retry, Finder reveal, delete, and clear actions.
- Pinned `curl_cffi` to the yt-dlp-compatible impersonation range and added an Impersonation diagnostic check.
- Added an opt-in Chrome cookies switch so Cloudflare/login-gated pages can reuse the user's browser session.
- Bundled `network_sniffer.py` and `capture_proxy.py` into the app package.
- Rebuilt the app icon with a richer player/download visual.
- Added a Mac-compatible MP4 guard: downloaded files are probed for codecs, MP4 output prefers H.264/AAC, and incompatible MP4 files are transcoded instead of only being remuxed.

### Backlog

- Add cookie picker and browser-cookie source selection beyond Bilibili.
- Add a browser capture/helper workflow for pages that block automatic sniffing.
- Add a signed/notarized release target after the app stabilizes.

### Test Targets

- Direct `.m3u8` URL downloads into MP4.
- Regular supported yt-dlp URLs.
- Script-heavy player pages such as novipnoad-style pages.
- Proxy on/off behavior with `127.0.0.1:7890`.
