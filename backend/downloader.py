#!/usr/bin/env python3
"""Video Downloader backend.

Pipeline:
1. Direct media URL detection (m3u8/mp4/mpd/etc.).
2. yt-dlp metadata extraction.
3. HTML/iframe media URL scan.
4. Optional browser network sniffing for script-heavy pages.

Downloads are handled by yt-dlp + ffmpeg. HLS/DASH fragments are merged and the
final file is normalized to MP4 when ffmpeg can do it.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import hashlib
import html
import importlib.util
import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urljoin, urlparse
from urllib.request import ProxyHandler, Request, build_opener

OUT = os.path.expanduser("~/Downloads/VideoDownloader")
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36"
)
MEDIA_EXTS = (".m3u8", ".mp4", ".mpd", ".webm", ".mkv", ".flv", ".mov", ".avi")
DOWNLOAD_EXTS = (".mp4", ".mkv", ".webm", ".flv", ".mov", ".avi", ".m4v")
PLACEHOLDER_MEDIA_TOKENS = ("empty", "blank", "placeholder", "transparent", "loading", "preload", "1x1")
EVENT_PREFIX = "__vd_event__"
os.makedirs(OUT, exist_ok=True)
BILIBILI_VIDEO_RE = re.compile(r"https?://(?:www\.)?bilibili\.com/video/(?P<id>(?:BV[0-9A-Za-z]+|av\d+))", re.I)


def _ssl() -> None:
    if os.environ.get("SSL_CERT_FILE"):
        return
    try:
        version = f"python{sys.version_info.major}.{sys.version_info.minor}"
        candidates = [
            os.path.join(sys.prefix, "lib", version, "site-packages", "certifi", "cacert.pem"),
            "/etc/ssl/cert.pem",
        ]
        for path in candidates:
            if os.path.exists(path):
                os.environ["SSL_CERT_FILE"] = path
                os.environ["REQUESTS_CA_BUNDLE"] = path
                return
    except Exception:
        return


_ssl()


def _ytdlp() -> list[str]:
    return [sys.executable, "-m", "yt_dlp"]


def _ffmpeg() -> str:
    for path in [shutil.which("ffmpeg") or "", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]:
        if path and os.path.exists(path):
            return path
    return "ffmpeg"


def _ffprobe() -> str:
    for path in [shutil.which("ffprobe") or "", "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]:
        if path and os.path.exists(path):
            return path
    return "ffprobe"


def _proxy_env(proxy: str | None = None) -> dict[str, str]:
    env = os.environ.copy()
    if proxy:
        env.update({
            "HTTP_PROXY": proxy,
            "HTTPS_PROXY": proxy,
            "http_proxy": proxy,
            "https_proxy": proxy,
        })
    return env


def _media_headers(media_url: str, referer: str | None) -> dict[str, str]:
    if not _looks_like_media_url(media_url):
        return {}
    source = referer or media_url
    source_parsed = urlparse(source)
    media_parsed = urlparse(media_url)
    origin = f"{source_parsed.scheme}://{source_parsed.netloc}" if source_parsed.scheme and source_parsed.netloc else ""
    fetch_site = "same-origin" if source_parsed.netloc == media_parsed.netloc else "cross-site"
    headers = {
        "Accept": "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Range": "bytes=0-",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": fetch_site,
    }
    if origin:
        headers["Origin"] = origin
    return headers


def _media_header_args(media_url: str, referer: str | None) -> list[str]:
    args: list[str] = []
    for key, value in _media_headers(media_url, referer).items():
        args += ["--add-headers", f"{key}:{value}"]
    return args


def _is_bilibili_url(url: str) -> bool:
    host = urlparse(url).netloc.lower()
    return host == "bilibili.com" or host.endswith(".bilibili.com")


def _normalize_page_url(url: str) -> str:
    parsed = urlparse(url.strip())
    if _is_bilibili_url(url):
        match = BILIBILI_VIDEO_RE.search(url)
        if match:
            video_id = match.group("id")
            query = parse_qs(parsed.query)
            page = query.get("p") or query.get("page")
            suffix = f"?p={page[0]}" if page and page[0].isdigit() else ""
            return f"https://www.bilibili.com/video/{video_id}{suffix}"
    return url.strip()


def _bilibili_args() -> list[str]:
    return [
        "--extractor-retries", "5",
        "--retry-sleep", "extractor:linear=1::2",
        "--sleep-requests", "0.2",
    ]


def fd(value: Any) -> str:
    if value is None:
        return "??:??"
    if isinstance(value, str):
        if value.startswith("PT"):
            m = re.match(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?", value)
            if m:
                h = int(m.group(1) or 0)
                mm = int(m.group(2) or 0)
                ss = float(m.group(3) or 0)
                return f"{h}:{mm:02d}:{int(ss):02d}" if h else f"{mm}:{int(ss):02d}"
        parts = value.strip().split(":")
        if len(parts) >= 2:
            try:
                nums = [int(x) for x in parts]
                return f"{nums[0]}:{nums[1]:02d}:{nums[2]:02d}" if len(nums) == 3 else f"{nums[0]}:{nums[1]:02d}"
            except Exception:
                return value
        return value
    try:
        secs = float(value)
        h, rest = divmod(int(secs), 3600)
        m, s = divmod(rest, 60)
        return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"
    except Exception:
        return "??:??"


def _duration_seconds(info: dict[str, Any]) -> int | None:
    for key in ("duration", "duration_sec", "duration_seconds"):
        value = info.get(key)
        if isinstance(value, (int, float)) and value > 0:
            return int(value)
        if isinstance(value, str):
            try:
                parsed = float(value)
                if parsed > 0:
                    return int(parsed)
            except Exception:
                pass
    for key in ("timelength", "duration_ms", "approxDurationMs"):
        value = info.get(key)
        try:
            parsed = float(value)
            if parsed > 0:
                return int(parsed / 1000)
        except Exception:
            pass
    return None


def _duration_human(info: dict[str, Any]) -> str:
    for key in ("duration_string", "duration_human", "duration_str"):
        value = info.get(key)
        if isinstance(value, str) and value.strip():
            return fd(value)
    return fd(_duration_seconds(info))


def fs(value: int | float | None) -> str:
    if value is None:
        return "???"
    size = float(value)
    for unit in ["B", "KB", "MB", "GB"]:
        if size < 1024:
            return f"{size:.1f}{unit}"
        size /= 1024
    return f"{size:.1f}TB"


def _run(args: list[str], timeout: int = 15, env: dict[str, str] | None = None) -> tuple[str, str, bool]:
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env or os.environ.copy(),
        )
        return result.stdout.strip(), result.stderr.strip(), result.returncode == 0
    except subprocess.TimeoutExpired:
        return "", "timeout", False
    except Exception as exc:
        return "", str(exc), False


def _emit_event(kind: str, **payload: Any) -> None:
    event = {"type": kind, **payload}
    print(EVENT_PREFIX + json.dumps(event, ensure_ascii=False), file=sys.stderr, flush=True)


def _progress_from_line(line: str) -> dict[str, Any] | None:
    cleaned = re.sub(r"\x1b\[[0-9;]*m", "", line).strip()
    if not cleaned:
        return None

    percent = re.search(r"\[download\]\s+([0-9]+(?:\.[0-9]+)?)%", cleaned)
    if percent:
        payload: dict[str, Any] = {
            "stage": "downloading",
            "percent": min(99.0, float(percent.group(1))),
            "message": cleaned[:220],
        }
        size_match = re.search(r"of\s+~?\s*([0-9.]+\s*[KMGT]i?B)", cleaned, re.I)
        downloaded_match = re.search(r"%\s+of\s+~?\s*([0-9.]+\s*[KMGT]i?B)", cleaned, re.I)
        if size_match:
            payload["total"] = size_match.group(1).replace(" ", "")
        downloaded = re.search(r"\[download\]\s+[0-9.]+%\s+of\s+~?\s*[0-9.]+\s*[KMGT]i?B\s+at", cleaned, re.I)
        if downloaded_match and downloaded:
            try:
                pct = float(percent.group(1)) / 100.0
                total_label = downloaded_match.group(1).replace(" ", "")
                payload["downloaded"] = f"{pct:.0%} of {total_label}"
            except Exception:
                pass
        eta = re.search(r"\bETA\s+([0-9:]+)", cleaned)
        speed = re.search(r"\bat\s+([^\s]+/s)", cleaned)
        if eta:
            payload["eta"] = eta.group(1)
        if speed:
            payload["speed"] = speed.group(1)
        return payload

    stage_map = [
        ("[download] Destination:", "starting", 1.0),
        ("[download] Downloading playlist:", "starting", 1.0),
        ("[Merger]", "merging", 92.0),
        ("[Fixup", "fixing", 94.0),
        ("[VideoRemuxer]", "remuxing", 96.0),
        ("[ExtractAudio]", "converting", 96.0),
        ("Deleting original file", "cleaning", 98.0),
    ]
    for token, stage, percent_value in stage_map:
        if token in cleaned:
            return {"stage": stage, "percent": percent_value, "message": cleaned[:220]}
    return None


def _run_with_progress(args: list[str], timeout: int, env: dict[str, str]) -> tuple[str, str, bool]:
    try:
        process = subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
    except Exception as exc:
        return "", str(exc), False

    stdout_lines: list[str] = []
    stderr_lines: list[str] = []

    def read_stdout() -> None:
        assert process.stdout is not None
        for line in process.stdout:
            stdout_lines.append(line)
            event = _progress_from_line(line)
            if event:
                _emit_event("progress", **event)

    def read_stderr() -> None:
        assert process.stderr is not None
        for line in process.stderr:
            stderr_lines.append(line)
            event = _progress_from_line(line)
            if event:
                _emit_event("progress", **event)

    threads = [
        threading.Thread(target=read_stdout, daemon=True),
        threading.Thread(target=read_stderr, daemon=True),
    ]
    for thread in threads:
        thread.start()

    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
        return "".join(stdout_lines), "".join(stderr_lines) + "\ntimeout", False

    for thread in threads:
        thread.join(timeout=2)
    return "".join(stdout_lines), "".join(stderr_lines), process.returncode == 0


def _looks_like_media_url(url: str) -> bool:
    lower = url.lower().split("#", 1)[0]
    return any(ext in lower for ext in MEDIA_EXTS)


def _media_ext(url: str) -> str:
    parsed = urlparse(url)
    haystacks = [unquote(parsed.path).lower(), unquote(parsed.query).lower()]
    try:
        for values in parse_qs(parsed.query).values():
            haystacks.extend(unquote(value).lower() for value in values)
    except Exception:
        pass
    for ext in MEDIA_EXTS:
        if any(item.endswith(ext) or ext in item for item in haystacks):
            return ext.lstrip(".")
    return "mp4"


def _is_placeholder_media_url(url: str) -> bool:
    parsed = urlparse(url)
    name = unquote(Path(parsed.path).name).lower()
    if not name:
        query = parse_qs(parsed.query)
        for key in ("fname", "filename", "name", "title"):
            value = query.get(key)
            if value and value[0]:
                name = unquote(value[0]).lower()
                break
    if not name:
        return False
    if _media_ext(url) not in {"mp4", "webm", "mov"}:
        return False
    return any(token in name for token in PLACEHOLDER_MEDIA_TOKENS)


def _media_url_score(url: str) -> int:
    ext = _media_ext(url)
    path = urlparse(url).path.lower()
    score = {
        "m3u8": 100,
        "mpd": 96,
        "mp4": 75,
        "webm": 70,
        "mkv": 70,
        "flv": 65,
        "mov": 65,
        "avi": 60,
    }.get(ext, 40)
    if any(token in path for token in ("master", "playlist", "chunklist", "index")):
        score += 8
    if any(token in path for token in ("/assets/", "/static/", "/javascript/", "/js/")):
        score -= 12
    if _is_placeholder_media_url(url):
        score -= 200
    return score


def _rank_media_videos(videos: list[dict[str, Any]]) -> list[dict[str, Any]]:
    usable = [video for video in videos if not _is_placeholder_media_url(str(video.get("webpage_url") or ""))]
    usable.sort(key=lambda video: _media_url_score(str(video.get("webpage_url") or "")), reverse=True)
    return usable


def _clean_title(value: str | None) -> str:
    if not value:
        return ""
    value = html.unescape(value)
    value = re.sub(r"\s+", " ", value).strip()
    for sep in [" - 在线观看", "_免费在线观看", "免费在线观看", "在线观看", "高清播放", " - "]:
        if sep in value and len(value.split(sep, 1)[0]) >= 4:
            value = value.split(sep, 1)[0].strip()
            break
    return value[:120]


def _title_from_url(url: str, fallback: str = "Captured video") -> str:
    parsed = urlparse(url)
    query = parse_qs(parsed.query)
    for key in ("fname", "filename", "name", "title"):
        value = query.get(key)
        if value and value[0]:
            return _clean_title(unquote(value[0])) or fallback
    name = _clean_title(unquote(Path(parsed.path).name or fallback))
    return name or fallback


def _safe_filename(value: str, fallback: str = "video") -> str:
    value = _clean_title(value)
    value = re.sub(r'[\\/:*?"<>|]+', "_", value).strip(" .")
    return (value or fallback)[:160]


def _output_template(output_dir: str, url: str, output_format: str, title_hint: str | None = None) -> str:
    if _looks_like_media_url(url):
        title = _safe_filename(title_hint or _title_from_url(url, "video"), "video")
        stem, ext = os.path.splitext(title)
        known_exts = {item.lstrip(".") for item in (*DOWNLOAD_EXTS, *MEDIA_EXTS)}
        if ext.lower().lstrip(".") in known_exts:
            title = stem or "video"
        return os.path.join(output_dir, f"{title}.{output_format}")
    return os.path.join(output_dir, "%(title).180B.%(ext)s")


def _title_is_generic(value: str | None) -> bool:
    if not value:
        return True
    lower = value.lower().strip()
    return (
        lower in {"video", "captured video", "mp4", "m3u8", "chunklist.m3u8", "index.m3u8", "hd.mp4"}
        or lower.endswith((".m3u8", ".mpd"))
        or bool(re.fullmatch(r"[a-f0-9]{16,}\.mp4", lower))
    )


def _extract_page_title(text: str) -> str:
    decoded = html.unescape(text)
    patterns = [
        r"(?is)<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)[\"']",
        r"(?is)<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:title[\"']",
        r"(?is)<meta[^>]+name=[\"']twitter:title[\"'][^>]+content=[\"']([^\"']+)[\"']",
        r"(?is)<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+name=[\"']twitter:title[\"']",
        r"(?is)<meta[^>]+name=[\"']title[\"'][^>]+content=[\"']([^\"']+)[\"']",
        r"(?is)<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+name=[\"']title[\"']",
        r"(?is)<title[^>]*>(.*?)</title>",
        r"(?is)<h1[^>]*>(.*?)</h1>",
        r"(?is)<[^>]+class=[\"'][^\"']*(?:video-title|player-title|title)[^\"']*[\"'][^>]*>(.*?)</[^>]+>",
    ]
    for pattern in patterns:
        match = re.search(pattern, decoded)
        if match:
            title = _clean_title(re.sub(r"<[^>]+>", "", match.group(1)))
            if title:
                return title
    return ""


def _format_item(format_id: str, ext: str, height: int | None = None, size: int | None = None, label: str | None = None) -> dict[str, Any]:
    return {
        "format_id": format_id,
        "ext": ext or "mp4",
        "height": height or 0,
        "filesize": size,
        "filesize_human": fs(size),
        "label": label or (f"{height}p" if height else ext.upper()),
        "has_video": True,
        "has_audio": True,
    }


def _video_from_media_url(media_url: str, title: str | None = None, referer: str | None = None, method: str = "direct") -> dict[str, Any]:
    ext = _media_ext(media_url)
    video_id = hashlib.md5(media_url.encode()).hexdigest()[:12]
    return {
        "id": video_id,
        "title": title or _title_from_url(media_url),
        "duration": None,
        "duration_human": "??:??",
        "webpage_url": media_url,
        "referer": referer or "",
        "thumbnail": "",
        "description": f"{method} {ext.upper()} URL",
        "uploader": urlparse(media_url).netloc,
        "formats": [_format_item("best", ext, label=f"{ext.upper()} -> MP4")],
        "format_count": 1,
    }


def _videos_from_info(info: dict[str, Any], original_url: str) -> list[dict[str, Any]]:
    entries = info.get("entries")
    if isinstance(entries, list):
        videos: list[dict[str, Any]] = []
        for entry in entries:
            if isinstance(entry, dict):
                videos.extend(_videos_from_info(entry, original_url))
        return videos

    formats = []
    for item in info.get("formats") or []:
        fmt_url = item.get("url") or ""
        ext = item.get("ext") or _media_ext(fmt_url) if fmt_url else item.get("ext", "mp4")
        formats.append({
            "format_id": item.get("format_id", ""),
            "ext": ext or "mp4",
            "height": item.get("height") or 0,
            "filesize": item.get("filesize") or item.get("filesize_approx"),
            "filesize_human": fs(item.get("filesize") or item.get("filesize_approx")),
            "label": f"{item.get('height')}p" if item.get("height") else (ext or "mp4").upper(),
            "has_video": item.get("vcodec", "none") != "none",
            "has_audio": item.get("acodec", "none") != "none",
        })
    formats.sort(key=lambda x: (x["height"], x["has_video"], x["has_audio"]), reverse=True)
    if not formats:
        formats = [_format_item("best", info.get("ext") or "mp4", label="Best -> MP4")]

    return [{
        "id": str(info.get("id") or hashlib.md5(original_url.encode()).hexdigest()[:12]),
        "title": info.get("title") or _title_from_url(original_url, "Video"),
        "duration": _duration_seconds(info),
        "duration_human": _duration_human(info),
        "webpage_url": info.get("webpage_url") or original_url,
        "referer": original_url,
        "thumbnail": info.get("thumbnail") or "",
        "description": info.get("description") or "",
        "uploader": info.get("uploader") or info.get("channel") or "",
        "formats": formats,
        "format_count": len(formats),
    }]


def _parse_json_objects(text: str) -> list[dict[str, Any]]:
    objects = []
    stripped = text.strip()
    if not stripped:
        return objects
    try:
        parsed = json.loads(stripped)
        if isinstance(parsed, dict):
            return [parsed]
    except Exception:
        pass
    for line in stripped.splitlines():
        try:
            parsed = json.loads(line)
            if isinstance(parsed, dict):
                objects.append(parsed)
        except Exception:
            continue
    return objects


def _friendly_error(raw: str, url: str) -> str:
    lower = raw.lower()
    if "failed to resolve" in lower or "could not resolve host" in lower or "nodename nor servname" in lower:
        return "网络/DNS 无法访问该站点：请确认代理可用，或切换直连/代理后重试"
    if "connection refused" in lower or "proxy" in lower and ("refused" in lower or "failed" in lower):
        return "代理连接失败：请确认代理开关、地址和端口是否正确"
    if "bilibili" in url.lower():
        if "412" in raw:
            return "B站 412 风控：请开启代理，并打开 Chrome Cookies 后重试"
        if "login" in lower or "cookie" in lower or "sessdata" in lower:
            return "B站需要登录态：请先在 Chrome 登录 B站，再打开钥匙按钮使用 Chrome Cookies"
        if "403" in raw:
            return "B站 403：请开启 Chrome Cookies，必要时同时使用代理"
        return "B站检测失败：请确认 Chrome 已登录，打开钥匙按钮后重试"
    if "cloudflare" in lower or "challenge" in lower:
        return "网站有 Cloudflare/反爬挑战：请先在 Chrome 播放成功，再打开 Chrome Cookies 或使用捕获模式"
    if "403" in raw:
        return "网站返回 403：请开启代理/Chrome Cookies，或在浏览器播放后抓取 m3u8"
    if "drm" in lower:
        return "检测到 DRM 保护内容，无法下载"
    if "unsupported url" in lower:
        return "当前站点不在 yt-dlp 支持列表：请尝试捕获模式或直链 m3u8"
    return "未找到视频：请尝试开启代理、Chrome Cookies，或使用直链/捕获模式"


def _fetch_text(url: str, proxy: str | None = None, referer: str | None = None, timeout: int = 20) -> str:
    handlers = []
    if proxy:
        handlers.append(ProxyHandler({"http": proxy, "https": proxy}))
    opener = build_opener(*handlers)
    req = Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Referer": referer or url,
    })
    with opener.open(req, timeout=timeout) as response:
        raw = response.read(2_000_000)
        charset = response.headers.get_content_charset() or "utf-8"
        return raw.decode(charset, errors="replace")


def _extract_media_urls(text: str, base_url: str) -> list[str]:
    decoded = html.unescape(text).replace("\\/", "/")
    found: list[str] = []

    for match in re.finditer(r"https?://[^\s\"'<>]+", decoded, re.I):
        candidate = match.group(0).rstrip("),;]")
        if _looks_like_media_url(candidate):
            found.append(candidate)

    rel_patterns = [
        r"(?i)(?:src|url|file|video|play_url|hls|m3u8)\s*[:=]\s*[\"']([^\"']+)[\"']",
        r"(?i)[\"']([^\"']+\.(?:m3u8|mp4|mpd|webm|mkv|flv|mov|avi)(?:\?[^\"']*)?)[\"']",
    ]
    for pattern in rel_patterns:
        for match in re.finditer(pattern, decoded):
            candidate = match.group(1).strip()
            if _looks_like_media_url(candidate):
                found.append(urljoin(base_url, candidate))

    unique = []
    seen = set()
    for item in found:
        item = item.replace("&amp;", "&")
        if item not in seen:
            seen.add(item)
            unique.append(item)
    return unique


def _extract_iframe_urls(text: str, base_url: str) -> list[str]:
    decoded = html.unescape(text).replace("\\/", "/")
    found = []
    for match in re.finditer(r"(?i)<iframe[^>]+src=[\"']([^\"']+)[\"']", decoded):
        found.append(urljoin(base_url, match.group(1)))
    for match in re.finditer(r"(?i)(?:player|iframe|embed)[^\"']*[\"'](https?://[^\"']+)[\"']", decoded):
        found.append(match.group(1))
    unique = []
    seen = set()
    for item in found:
        if item not in seen:
            seen.add(item)
            unique.append(item)
    return unique[:8]


def _html_detect(url: str, proxy: str | None = None) -> list[dict[str, Any]]:
    videos: list[dict[str, Any]] = []
    queue = [(url, None)]
    seen_pages = set()

    while queue and len(seen_pages) < 6:
        page_url, referer = queue.pop(0)
        if page_url in seen_pages:
            continue
        seen_pages.add(page_url)
        try:
            text = _fetch_text(page_url, proxy=proxy, referer=referer or url)
        except Exception:
            continue

        page_title = _extract_page_title(text)
        for media_url in _extract_media_urls(text, page_url):
            videos.append(_video_from_media_url(media_url, title=page_title or None, referer=page_url, method="html"))

        for iframe_url in _extract_iframe_urls(text, page_url):
            if iframe_url not in seen_pages:
                queue.append((iframe_url, page_url))

        if videos:
            break

    unique = []
    seen = set()
    for video in videos:
        if video["webpage_url"] not in seen:
            seen.add(video["webpage_url"])
            unique.append(video)
    return _rank_media_videos(unique)


def _sniff_detect(url: str, proxy: str | None = None, timeout: int = 35) -> list[dict[str, Any]]:
    def load_module(name: str, path: Path):
        if not path.exists():
            return None
        spec = importlib.util.spec_from_file_location(name, path)
        if spec is None or spec.loader is None:
            return None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def collect(result: Any, method: str) -> list[dict[str, Any]]:
        videos = result.get("videos") if isinstance(result, dict) else None
        if not isinstance(videos, list):
            return []
        out = []
        for video in videos:
            if not isinstance(video, dict):
                continue
            media_url = video.get("webpage_url", "")
            if not _looks_like_media_url(media_url):
                continue
            if _is_placeholder_media_url(media_url):
                continue
            video["referer"] = video.get("referer") or url
            video["description"] = video.get("description") or f"{method} capture"
            for fmt in video.get("formats") or []:
                if isinstance(fmt, dict):
                    ext = _media_ext(media_url)
                    fmt["ext"] = ext
                    fmt["label"] = fmt.get("label") or f"{ext.upper()} · network sniff"
            out.append(video)
        return _rank_media_videos(out)

    attempts = [
        ("network_sniffer", Path(__file__).with_name("network_sniffer.py"), "sniff"),
        ("capture_proxy", Path(__file__).with_name("capture_proxy.py"), "sniff_browser"),
    ]
    for name, path, func_name in attempts:
        try:
            module = load_module(name, path)
            if module is None or not hasattr(module, func_name):
                continue
            with contextlib.redirect_stdout(io.StringIO()):
                result = asyncio.run(getattr(module, func_name)(url, timeout=timeout, proxy=proxy))
            found = collect(result, name)
            if found:
                return found
        except BaseException:
            continue
    return []


def browser_capture(url: str, proxy: str | None = None, timeout: int = 120) -> dict[str, Any]:
    url = _normalize_page_url(url.strip())
    try:
        module_path = Path(__file__).with_name("capture_proxy.py")
        spec = importlib.util.spec_from_file_location("capture_proxy", module_path)
        if spec is None or spec.loader is None:
            return {"success": False, "error": "捕获器不可用", "videos": []}
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with contextlib.redirect_stdout(io.StringIO()):
            result = asyncio.run(module.sniff_browser(url, timeout=timeout, proxy=proxy, headless=False))
    except BaseException as exc:
        return {"success": False, "error": f"浏览器捕获失败：{exc}", "videos": []}

    videos = result.get("videos") if isinstance(result, dict) else None
    if not isinstance(videos, list):
        return {"success": False, "error": "浏览器捕获没有返回视频", "videos": []}

    out = []
    for video in videos:
        if not isinstance(video, dict):
            continue
        media_url = video.get("webpage_url", "")
        if not _looks_like_media_url(media_url) or _is_placeholder_media_url(media_url):
            continue
        page_title = _clean_title(video.get("source_title") or video.get("page_title") or "")
        if page_title and _title_is_generic(video.get("title")):
            video["title"] = page_title
        video["referer"] = video.get("referer") or url
        video["description"] = video.get("description") or "interactive browser capture"
        for fmt in video.get("formats") or []:
            if isinstance(fmt, dict):
                ext = _media_ext(media_url)
                fmt["ext"] = ext
                fmt["label"] = fmt.get("label") or f"{ext.upper()} · browser capture"
        out.append(video)

    out = _rank_media_videos(out)
    if out:
        return {"success": True, "videos": out, "count": len(out), "method": "browser-capture"}
    return {"success": False, "error": "没有捕获到媒体地址：请在打开的 Chrome 窗口里通过验证并点击播放后重试", "videos": []}


def detect(url: str, proxy: str | None = None, cookies: str | None = None, cb: str | None = None, sniff: bool = True) -> dict[str, Any]:
    original_url = url.strip()
    url = _normalize_page_url(original_url)
    if _looks_like_media_url(url):
        return {"success": True, "videos": [_video_from_media_url(url)], "count": 1, "method": "direct"}

    env = _proxy_env(proxy)
    cmd = _ytdlp() + [
        "-J", "--no-download", "--no-warnings", "--no-color",
        "--socket-timeout", "20", "--user-agent", USER_AGENT,
        "--referer", url,
    ]
    if proxy:
        cmd += ["--proxy", proxy]
    if cookies:
        cmd += ["--cookies", cookies]
    if cb:
        cmd += ["--cookies-from-browser", cb]
    if _is_bilibili_url(url):
        cmd += _bilibili_args()
    if _is_bilibili_url(url) and not cookies and not cb:
        cmd += ["--cookies-from-browser", "chrome"]

    last_err = ""
    errors: list[str] = []
    attempts = [[]]
    if _is_bilibili_url(url):
        attempts += [
            ["--extractor-args", "bilibili:prefer_multi_flv"],
            ["--extractor-args", "bilibili:prefer_multi_flv=32"],
        ]
    attempts += [
        ["--impersonate", "chrome"],
        ["--extractor-args", "generic:impersonate"],
    ]
    for extra in attempts:
        out, err, ok = _run(cmd + extra + [url], timeout=30, env=env)
        last_err = err or last_err
        if err:
            errors.append(err)
        if ok and out:
            videos = []
            for info in _parse_json_objects(out):
                videos.extend(_videos_from_info(info, url))
            if videos:
                return {"success": True, "videos": videos, "count": len(videos), "method": "yt-dlp"}

    html_videos = _html_detect(url, proxy=proxy)
    if html_videos:
        return {"success": True, "videos": html_videos, "count": len(html_videos), "method": "html"}

    if sniff:
        sniffed = _sniff_detect(url, proxy=proxy)
        if sniffed:
            return {"success": True, "videos": sniffed, "count": len(sniffed), "method": "sniff"}

    joined_err = "\n".join(errors) or last_err
    msg = _friendly_error(joined_err, url)
    return {"success": False, "error": msg, "details": joined_err[-1000:], "videos": []}


def _find_latest_media(output_dir: str, since: float) -> str | None:
    best = None
    best_time = since
    for root, _, files in os.walk(output_dir):
        for name in files:
            if name.startswith(".") or name.endswith((".part", ".ytdl", ".temp")):
                continue
            if not name.lower().endswith(DOWNLOAD_EXTS):
                continue
            path = os.path.join(root, name)
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                continue
            if mtime >= best_time:
                best_time = mtime
                best = path
    return best


def _clean_output_path(value: str) -> str:
    value = value.strip().strip("\"'")
    value = value.replace("\\ ", " ")
    return value


def _extract_output_paths(text: str, output_dir: str) -> list[str]:
    patterns = [
        r"(?m)^\[download\]\s+Destination:\s+(.+)$",
        r"(?m)^\[Merger\]\s+Merging formats into\s+\"(.+)\"",
        r"(?m)^\[VideoRemuxer\].*?\"(.+?)\"",
        r"(?m)^(.+?)\s+has already been downloaded$",
        r"(?m)^\[download\]\s+(.+?)\s+has already been downloaded$",
    ]
    found: list[str] = []

    def add_candidate(value: str) -> None:
        path = _clean_output_path(value)
        if path.startswith("file://"):
            path = unquote(urlparse(path).path)
        if not path:
            return
        if not os.path.isabs(path):
            path = os.path.join(output_dir, path)
        lower = path.lower()
        if lower.endswith((".part", ".ytdl", ".temp")):
            return
        if not lower.endswith(DOWNLOAD_EXTS):
            return
        if os.path.exists(path) and os.path.isfile(path):
            found.append(path)

    for pattern in patterns:
        for match in re.finditer(pattern, text):
            add_candidate(match.group(1))

    output_root = os.path.realpath(output_dir)
    for raw_line in text.splitlines():
        line = _clean_output_path(raw_line)
        if not line or line.startswith("[") or len(line) > 4096:
            continue
        if line.startswith("file://"):
            parsed_path = unquote(urlparse(line).path)
            if parsed_path:
                line = parsed_path
        if not os.path.isabs(line):
            continue
        real = os.path.realpath(line)
        if real == output_root or not real.startswith(output_root + os.sep):
            continue
        add_candidate(line)

    unique: list[str] = []
    seen = set()
    for path in found:
        real = os.path.realpath(path)
        if real not in seen:
            seen.add(real)
            unique.append(path)
    return unique


def _resolve_downloaded_media(output_dir: str, started: float, output_text: str) -> str | None:
    for path in _extract_output_paths(output_text, output_dir):
        if path.lower().endswith(DOWNLOAD_EXTS) and os.path.getsize(path) > 0:
            return path

    recent = _find_latest_media(output_dir, started)
    if recent:
        return recent

    return _find_latest_media(output_dir, 0)


def _with_extension(path: str, ext: str, suffix: str = "") -> str:
    base, _ = os.path.splitext(path)
    candidate = f"{base}{suffix}.{ext}"
    if not os.path.exists(candidate):
        return candidate
    return f"{base}{suffix}-{int(time.time())}.{ext}"


def _probe_media(path: str) -> tuple[bool, dict[str, Any], str]:
    if not os.path.exists(path) or os.path.getsize(path) <= 0:
        return False, {}, "missing or empty file"
    out, err, ok = _run([
        _ffprobe(), "-v", "error",
        "-show_entries", "format=duration:stream=codec_type,codec_name",
        "-of", "json", path,
    ], timeout=60)
    if not ok or not out:
        return False, {}, err or "ffprobe failed"
    try:
        info = json.loads(out)
    except Exception as exc:
        return False, {}, f"ffprobe JSON failed: {exc}"
    streams = info.get("streams") or []
    has_media = any(item.get("codec_type") in ("video", "audio") for item in streams if isinstance(item, dict))
    if not has_media:
        return False, info, "no audio/video stream"
    return True, info, ""


def _stream_codecs(probe: dict[str, Any]) -> tuple[list[str], list[str]]:
    video: list[str] = []
    audio: list[str] = []
    for stream in probe.get("streams") or []:
        if not isinstance(stream, dict):
            continue
        codec_type = stream.get("codec_type")
        codec = str(stream.get("codec_name") or "").lower()
        if codec_type == "video" and codec:
            video.append(codec)
        elif codec_type == "audio" and codec:
            audio.append(codec)
    return video, audio


def _probe_summary(probe: dict[str, Any], output_format: str) -> dict[str, str]:
    video, audio = _stream_codecs(probe)
    duration = ""
    try:
        duration = fd(float((probe.get("format") or {}).get("duration") or 0))
    except Exception:
        duration = "??:??"
    compatible, compat_note = _compatible_with_container(probe, output_format)
    return {
        "duration_human": duration,
        "video_codec": ", ".join(video).upper() if video else "",
        "audio_codec": ", ".join(audio).upper() if audio else "",
        "compatibility": "compatible" if compatible else "warning",
        "compatibility_note": compat_note,
    }


def _compatible_with_container(probe: dict[str, Any], ext: str) -> tuple[bool, str]:
    video, audio = _stream_codecs(probe)
    if not video and not audio:
        return False, "no audio/video codec"

    ext = ext.lower().lstrip(".")
    if ext == "mp4":
        video_ok = not video or all(codec in {"h264", "avc1"} for codec in video)
        audio_ok = not audio or all(codec in {"aac", "mp3", "alac"} for codec in audio)
        if video_ok and audio_ok:
            return True, "mp4-compatible"
        return False, f"mp4 incompatible codecs: video={video or ['none']} audio={audio or ['none']}"

    if ext == "webm":
        video_ok = not video or all(codec in {"vp8", "vp9", "av1"} for codec in video)
        audio_ok = not audio or all(codec in {"vorbis", "opus"} for codec in audio)
        if video_ok and audio_ok:
            return True, "webm-compatible"
        return False, f"webm incompatible codecs: video={video or ['none']} audio={audio or ['none']}"

    return True, f"{ext}-container"


def _remux(path: str, ext: str, suffix: str = "-remux") -> tuple[str, str, bool]:
    ffmpeg = _ffmpeg()
    out = _with_extension(path, ext, suffix=suffix)
    cmd = [ffmpeg, "-y", "-i", path, "-c", "copy"]
    if ext == "mp4":
        cmd += ["-movflags", "+faststart"]
    cmd.append(out)
    _, err, ok = _run(cmd, timeout=1800)
    return out, err[-500:], ok and os.path.exists(out) and os.path.getsize(out) > 0


def _transcode(path: str, ext: str, suffix: str = "-fixed") -> tuple[str, str, bool]:
    ffmpeg = _ffmpeg()
    out = _with_extension(path, ext, suffix=suffix)
    if ext == "webm":
        codec_args = ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]
    else:
        codec_args = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-c:a", "aac", "-b:a", "160k"]
    cmd = [ffmpeg, "-y", "-i", path, *codec_args]
    if ext == "mp4":
        cmd += ["-movflags", "+faststart"]
    cmd.append(out)
    _, err, ok = _run(cmd, timeout=7200)
    return out, err[-500:], ok and os.path.exists(out) and os.path.getsize(out) > 0


def _ensure_playable(path: str, output_format: str) -> tuple[str, str, dict[str, Any]]:
    notes: list[str] = []
    target = output_format.lower()
    current_ext = os.path.splitext(path)[1].lower().lstrip(".")

    if current_ext != target:
        remuxed, remux_err, remux_ok = _remux(path, target, suffix="")
        if remux_ok:
            path = remuxed
            notes.append("remux")
        else:
            notes.append(f"remux failed: {remux_err}")

    playable, probe, probe_err = _probe_media(path)
    if playable:
        compatible, compat_note = _compatible_with_container(probe, target)
        if compatible:
            if compat_note:
                notes.append(compat_note)
            return path, ", ".join(notes), probe
        notes.append(compat_note)
        transcoded, trans_err, trans_ok = _transcode(path, target)
        if trans_ok:
            playable, probe, probe_err = _probe_media(transcoded)
            if playable:
                compatible, compat_note = _compatible_with_container(probe, target)
                if compatible:
                    notes.append("compat-transcode")
                    notes.append(compat_note)
                    return transcoded, ", ".join(notes), probe
                notes.append(f"transcoded incompatible: {compat_note}")
            else:
                notes.append(f"transcode probe failed: {probe_err}")
        else:
            notes.append(f"compat transcode failed: {trans_err}")
        return path, ", ".join(notes), {}

    notes.append(f"probe failed: {probe_err}")
    remuxed, remux_err, remux_ok = _remux(path, target, suffix="-repair")
    if remux_ok:
        playable, probe, probe_err = _probe_media(remuxed)
        if playable:
            compatible, compat_note = _compatible_with_container(probe, target)
            if compatible:
                notes.append("repair-remux")
                notes.append(compat_note)
                return remuxed, ", ".join(notes), probe
            notes.append(f"repair remux incompatible: {compat_note}")
        notes.append(f"repair probe failed: {probe_err}")
    else:
        notes.append(f"repair remux failed: {remux_err}")

    transcoded, trans_err, trans_ok = _transcode(path, target)
    if trans_ok:
        playable, probe, probe_err = _probe_media(transcoded)
        if playable:
            compatible, compat_note = _compatible_with_container(probe, target)
            if compatible:
                notes.append("transcode")
                notes.append(compat_note)
                return transcoded, ", ".join(notes), probe
            notes.append(f"transcode incompatible: {compat_note}")
        notes.append(f"transcode probe failed: {probe_err}")
    else:
        notes.append(f"transcode failed: {trans_err}")

    return path, ", ".join(notes), probe


def _ensure_mp4(path: str) -> tuple[str, str]:
    fixed, note, _ = _ensure_playable(path, "mp4")
    return fixed, note


def _download_direct_with_ffmpeg(
    url: str,
    output_dir: str,
    referer: str | None,
    output_format: str,
    title: str | None,
    env: dict[str, str],
) -> tuple[str | None, str, bool]:
    target = _output_template(output_dir, url, output_format, title)
    if os.path.exists(target):
        target = _with_extension(target, output_format, "-ffmpeg")
    headers = _media_headers(url, referer or url)
    headers["Referer"] = referer or url
    headers["User-Agent"] = USER_AGENT
    header_text = "".join(f"{key}: {value}\r\n" for key, value in headers.items())
    cmd = [
        _ffmpeg(), "-y", "-loglevel", "warning",
        "-rw_timeout", "30000000",
        "-headers", header_text,
        "-i", url,
        "-map", "0:v?", "-map", "0:a?",
        "-c", "copy",
    ]
    if output_format == "mp4":
        cmd += ["-movflags", "+faststart"]
    cmd.append(target)
    out, err, ok = _run(cmd, timeout=7200, env=env)
    if ok and os.path.exists(target) and os.path.getsize(target) > 0:
        return target, err or out, True
    return None, err or out, False


def download(
    url: str,
    output_dir: str | None = None,
    format_id: str = "best",
    proxy: str | None = None,
    cookies: str | None = None,
    cb: str | None = None,
    referer: str | None = None,
    output_format: str = "mp4",
    progress_json: bool = False,
    title: str | None = None,
) -> dict[str, Any]:
    original_url = url.strip()
    url = _normalize_page_url(original_url)
    output_dir = output_dir or OUT
    os.makedirs(output_dir, exist_ok=True)
    env = _proxy_env(proxy)
    started = time.time() - 2

    selected_format = "bestvideo*+bestaudio/best" if format_id in ("", "best") and not _looks_like_media_url(url) else format_id
    cmd = _ytdlp() + [
        "-f", selected_format,
        "-o", _output_template(output_dir, url, output_format, title),
        "--merge-output-format", output_format,
        "--remux-video", output_format,
        "--ffmpeg-location", _ffmpeg(),
        "--concurrent-fragments", "8",
        "--retries", "10",
        "--fragment-retries", "10",
        "--print", "after_move:filepath",
        "--newline", "--no-playlist", "--no-warnings", "--no-color",
        "--user-agent", USER_AGENT,
        "--referer", referer or url,
    ]
    cmd += _media_header_args(url, referer or url)
    if output_format == "mp4":
        cmd += ["-S", "vcodec:h264,acodec:aac,res,fps,hdr:12"]
    if proxy:
        cmd += ["--proxy", proxy]
    if cookies:
        cmd += ["--cookies", cookies]
    if cb:
        cmd += ["--cookies-from-browser", cb]
    if _is_bilibili_url(url):
        cmd += _bilibili_args()
    if _is_bilibili_url(url) and not cookies and not cb:
        cmd += ["--cookies-from-browser", "chrome"]
    cmd.append(url)

    if progress_json:
        _emit_event("progress", stage="starting", percent=1.0, message="准备解析媒体地址")
        out, err, ok = _run_with_progress(cmd, timeout=7200, env=env)
    else:
        out, err, ok = _run(cmd, timeout=7200, env=env)
    best: str | None = None
    if not ok:
        details = err or out
        if _looks_like_media_url(url):
            if progress_json:
                _emit_event("progress", stage="downloading", percent=3.0, message="yt-dlp 请求受限，切换 ffmpeg 直链下载")
            best, fallback_details, fallback_ok = _download_direct_with_ffmpeg(
                url, output_dir, referer or url, output_format, title, env
            )
            if not fallback_ok:
                combined = f"{details}\nffmpeg fallback:\n{fallback_details}"
                return {"success": False, "error": _friendly_error(combined, url), "details": combined[-1000:]}
        else:
            return {"success": False, "error": _friendly_error(details, url), "details": details[-1000:]}

    best = best or _resolve_downloaded_media(output_dir, started, f"{out}\n{err}")
    if not best:
        return {
            "success": False,
            "error": "找不到输出文件",
            "details": f"yt-dlp finished but no media file was found in {output_dir}. {(err or out)[-700:]}",
        }

    if progress_json:
        _emit_event("progress", stage="finalizing", percent=98.0, message="校验编码与容器兼容性")
    best, converted_note, probe_info = _ensure_playable(best, output_format)
    playable, final_probe, probe_err = _probe_media(best)
    if not playable:
        return {
            "success": False,
            "error": "输出文件不可播放，已尝试 remux/转码修复但仍失败",
            "details": f"{converted_note}; {probe_err}"[-1000:],
        }
    compatible, compat_note = _compatible_with_container(final_probe, output_format)
    if not compatible:
        return {
            "success": False,
            "error": "输出文件编码不兼容，已尝试转码但仍失败",
            "details": f"{converted_note}; {compat_note}"[-1000:],
        }
    probe_info = final_probe

    size = os.path.getsize(best)
    summary = _probe_summary(probe_info, output_format)
    if progress_json:
        _emit_event("progress", stage="done", percent=100.0, message="下载完成")
    return {
        "success": True,
        "file_path": best,
        "file_name": os.path.basename(best),
        "file_size": size,
        "file_size_human": fs(size),
        "format": os.path.splitext(best)[1].lower(),
        "details": converted_note,
        **summary,
        "probe": probe_info,
    }


def _check(name: str, status: str, detail: str) -> dict[str, str]:
    return {"name": name, "status": status, "detail": detail}


def diagnose(
    output_dir: str | None = None,
    proxy: str | None = None,
    referer: str | None = None,
    output_format: str = "mp4",
    cookies_from_browser: str | None = None,
) -> dict[str, Any]:
    checks: list[dict[str, str]] = []

    checks.append(_check("Python", "ok", sys.executable))

    out, err, ok = _run(_ytdlp() + ["--version"], timeout=10)
    checks.append(_check("yt-dlp", "ok" if ok and out else "fail", out or err or "not available"))

    imp_out, imp_err, imp_ok = _run(_ytdlp() + ["--list-impersonate-targets"], timeout=10)
    if imp_ok and imp_out:
        lines = [
            line.strip()
            for line in imp_out.splitlines()
            if line.strip()
            and not line.startswith("[info]")
            and not line.startswith("-")
            and not line.startswith("Client")
        ]
        available = [line for line in lines if "(unavailable)" not in line]
        chrome_available = any(line.lower().startswith("chrome") and "(unavailable)" not in line for line in lines)
        try:
            import curl_cffi  # type: ignore
            curl_detail = f"curl_cffi {getattr(curl_cffi, '__version__', 'unknown')}"
        except Exception:
            curl_detail = "curl_cffi missing"
        detail = "; ".join(available[:3]) if available else f"all targets unavailable; {curl_detail}"
        checks.append(_check("Impersonation", "ok" if chrome_available else "warn", detail))
    else:
        checks.append(_check("Impersonation", "warn", imp_err or "target list unavailable"))

    ffmpeg = _ffmpeg()
    out, err, ok = _run([ffmpeg, "-version"], timeout=10)
    first_line = (out or err).splitlines()[0] if (out or err) else ffmpeg
    checks.append(_check("ffmpeg", "ok" if ok else "fail", first_line))

    ffprobe = _ffprobe()
    out, err, ok = _run([ffprobe, "-version"], timeout=10)
    first_line = (out or err).splitlines()[0] if (out or err) else ffprobe
    checks.append(_check("ffprobe", "ok" if ok else "fail", first_line))

    target_dir = output_dir or OUT
    try:
        os.makedirs(target_dir, exist_ok=True)
        probe = Path(target_dir) / ".video-downloader-write-test"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink(missing_ok=True)
        checks.append(_check("Output", "ok", target_dir))
    except Exception as exc:
        checks.append(_check("Output", "fail", f"{target_dir}: {exc}"))

    if proxy:
        parsed = urlparse(proxy if "://" in proxy else "http://" + proxy)
        host = parsed.hostname or ""
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        try:
            with socket.create_connection((host, port), timeout=3):
                checks.append(_check("Proxy", "ok", f"{host}:{port} reachable"))
        except Exception as exc:
            detail = f"{host}:{port} not reachable: {exc}"
            if "Operation not permitted" in str(exc):
                detail += " (local sandbox may block the check)"
            checks.append(_check("Proxy", "warn", detail))
    else:
        checks.append(_check("Proxy", "ok", "direct connection mode"))

    try:
        import playwright  # type: ignore
        checks.append(_check("Playwright", "ok", getattr(playwright, "__file__", "installed")))
    except Exception as exc:
        checks.append(_check("Playwright", "warn", f"not importable: {exc}"))

    chrome_path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    if os.path.exists(chrome_path):
        checks.append(_check("Chrome", "ok", chrome_path))
    else:
        checks.append(_check("Chrome", "warn", "system Chrome not found; Playwright fallback may still work"))

    sniffers = []
    for script in ["network_sniffer.py", "capture_proxy.py"]:
        path = Path(__file__).with_name(script)
        if path.exists():
            sniffers.append(script)
    checks.append(_check("Sniffers", "ok" if len(sniffers) == 2 else "warn", ", ".join(sniffers) or "missing"))
    checks.append(_check("Output format", "ok", output_format))

    if referer:
        checks.append(_check("Referer", "ok", referer))
    else:
        checks.append(_check("Referer", "warn", "empty; direct m3u8 hosts may reject segment requests"))

    if cookies_from_browser:
        checks.append(_check("Cookies", "ok", f"browser source: {cookies_from_browser}"))
    else:
        checks.append(_check("Cookies", "warn", "disabled; Cloudflare/login pages may need Chrome cookies"))

    failures = sum(1 for item in checks if item["status"] == "fail")
    warnings = sum(1 for item in checks if item["status"] == "warn")
    summary = "ready" if failures == 0 else "attention needed"
    return {"success": failures == 0, "summary": summary, "warnings": warnings, "failures": failures, "checks": checks}


def _cli() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd")
    detect_parser = sub.add_parser("detect")
    detect_parser.add_argument("url")
    detect_parser.add_argument("--no-sniff", action="store_true")

    capture_parser = sub.add_parser("capture")
    capture_parser.add_argument("url")
    capture_parser.add_argument("--timeout", type=int, default=120)

    download_parser = sub.add_parser("download")
    download_parser.add_argument("url")
    download_parser.add_argument("fmt", nargs="?", default="best")
    download_parser.add_argument("--output-dir", "-o")
    download_parser.add_argument("--referer")
    download_parser.add_argument("--title")
    download_parser.add_argument("--output-format", default="mp4", choices=["mp4", "mkv", "webm"])
    download_parser.add_argument("--progress-json", action="store_true")

    diag_parser = sub.add_parser("diagnose")
    diag_parser.add_argument("--output-dir", "-o")
    diag_parser.add_argument("--referer")
    diag_parser.add_argument("--output-format", default="mp4", choices=["mp4", "mkv", "webm"])
    diag_parser.add_argument("--cookies-from-browser")

    for item in [detect_parser, capture_parser, download_parser, diag_parser]:
        item.add_argument("--proxy", "-p")
    for item in [detect_parser, download_parser]:
        item.add_argument("--cookies")
        item.add_argument("--cookies-from-browser")

    args = parser.parse_args()
    try:
        if args.cmd == "detect":
            result = detect(
                args.url,
                getattr(args, "proxy", None),
                getattr(args, "cookies", None),
                getattr(args, "cookies_from_browser", None),
                sniff=not args.no_sniff,
            )
        elif args.cmd == "capture":
            result = browser_capture(
                args.url,
                getattr(args, "proxy", None),
                args.timeout,
            )
        elif args.cmd == "download":
            result = download(
                args.url,
                args.output_dir,
                args.fmt,
                getattr(args, "proxy", None),
                getattr(args, "cookies", None),
                getattr(args, "cookies_from_browser", None),
                args.referer,
                args.output_format,
                args.progress_json,
                args.title,
            )
        elif args.cmd == "diagnose":
            result = diagnose(
                args.output_dir,
                getattr(args, "proxy", None),
                args.referer,
                args.output_format,
                getattr(args, "cookies_from_browser", None),
            )
        else:
            parser.print_help()
            return
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except Exception as exc:
        print(json.dumps({"success": False, "error": str(exc), "videos": []}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    _cli()
