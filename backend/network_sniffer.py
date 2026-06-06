#!/usr/bin/env python3
"""
Network Sniffer — Playwright-based video URL capture.
Inspired by cat-catch's approach: opens a real Chromium browser, loads the page,
clicks the play button, and intercepts video URLs (m3u8/mp4) from network traffic.

Usage:
  python3 network_sniffer.py <url> [--timeout 30] [--proxy http://...]
"""

import asyncio, json, re, sys, os
from urllib.parse import parse_qs, unquote, urlparse, urljoin

FOUND_MEDIA = []  # collected media URLs
MEDIA_EXTS = (".m3u8", ".mp4", ".mpd", ".webm", ".mkv", ".flv", ".mov", ".avi")
PLACEHOLDER_MEDIA_TOKENS = ("empty", "blank", "placeholder", "transparent", "loading", "preload", "1x1")
PAGE_TITLE_EXPRESSION = r"""
() => {
  const clean = (value) => String(value || '')
    .replace(/\s+/g, ' ')
    .replace(/^[\s\-_|]+|[\s\-_|]+$/g, '')
    .slice(0, 180);
  const picks = [
    ['meta[property="og:title"]', 'content'],
    ['meta[name="twitter:title"]', 'content'],
    ['meta[name="title"]', 'content'],
    ['h1', 'innerText'],
    ['[class*="title" i]', 'innerText'],
    ['[id*="title" i]', 'innerText'],
    ['.video-title', 'innerText'],
    ['.player-title', 'innerText']
  ];
  for (const [selector, prop] of picks) {
    const el = document.querySelector(selector);
    if (!el) continue;
    const value = clean(prop === 'content' ? el.getAttribute('content') : el.innerText || el.textContent);
    if (value && value.length >= 3 && !/cloudflare|just a moment|verify you are human/i.test(value)) {
      return value;
    }
  }
  return clean(document.title || '');
}
"""


def media_ext(url: str) -> str:
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


def looks_like_media_url(url: str) -> bool:
    parsed = urlparse(url)
    text = f"{unquote(parsed.path)}?{unquote(parsed.query)}".lower()
    return any(ext in text for ext in MEDIA_EXTS)


def is_placeholder_media_url(url: str) -> bool:
    parsed = urlparse(url)
    name = unquote(os.path.basename(parsed.path)).lower()
    if not name:
        query = parse_qs(parsed.query)
        for key in ("fname", "filename", "name", "title"):
            value = query.get(key)
            if value and value[0]:
                name = unquote(value[0]).lower()
                break
    if media_ext(url) not in {"mp4", "webm", "mov"}:
        return False
    return any(token in name for token in PLACEHOLDER_MEDIA_TOKENS)


def clean_page_title(title: str) -> str:
    title = re.sub(r"\s+", " ", title or "").strip()
    for sep in [" - 在线观看", "_免费在线观看", "免费在线观看", "在线观看", "高清播放", " - "]:
        if sep in title and len(title.split(sep, 1)[0]) >= 4:
            title = title.split(sep, 1)[0].strip()
            break
    return title[:120]


def title_from_url(url: str, fallback: str = "Captured video") -> str:
    parsed = urlparse(url)
    query = parse_qs(parsed.query)
    for key in ("fname", "filename", "name", "title"):
        value = query.get(key)
        if value and value[0]:
            return clean_page_title(unquote(value[0])) or fallback
    name = clean_page_title(unquote(os.path.basename(parsed.path) or fallback))
    return name or fallback


def is_generic_title(title: str) -> bool:
    lower = (title or "").lower().strip()
    return (
        not lower
        or lower in {"video", "captured video", "mp4", "m3u8", "chunklist.m3u8", "index.m3u8", "hd.mp4"}
        or lower.endswith((".m3u8", ".mpd"))
    )


def media_score(item: dict) -> int:
    url = item.get("url", "")
    ext = media_ext(url)
    path = urlparse(url).path.lower()
    score = {"m3u8": 100, "mpd": 96, "mp4": 75, "webm": 70, "mkv": 70, "flv": 65, "mov": 65, "avi": 60}.get(ext, 40)
    if any(token in path for token in ("master", "playlist", "chunklist", "index")):
        score += 8
    if any(token in path for token in ("/assets/", "/static/", "/javascript/", "/js/")):
        score -= 12
    if is_placeholder_media_url(url):
        score -= 200
    return score


async def sniff(url: str, timeout: int = 45, proxy: str | None = None) -> dict:
    """Open page in headless browser and capture video URLs from network traffic."""
    try:
        from playwright.async_api import async_playwright
    except ImportError:
        return {"success": False, "error": "Playwright not installed. Run: pip install playwright && python -m playwright install chromium"}

    FOUND_MEDIA.clear()

    async with async_playwright() as p:
        launch_args = {
            "headless": True,
            "args": ["--no-sandbox", "--disable-setuid-sandbox",
                     "--disable-blink-features=AutomationControlled"],
        }
        if proxy:
            launch_args["proxy"] = {"server": proxy}

        browser = None
        launch_errors = []
        for channel in ["chrome", None]:
            try:
                args = dict(launch_args)
                if channel:
                    args["channel"] = channel
                browser = await p.chromium.launch(**args)
                break
            except Exception as e:
                launch_errors.append(str(e))
        if browser is None:
            return {"success": False, "error": "Browser launch failed: " + " | ".join(launch_errors[-2:]), "videos": []}
        context = await browser.new_context(
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            viewport={"width": 1440, "height": 900},
            locale="zh-CN",
        )

        page = await context.new_page()
        page_title = ""

        # ── Intercept ALL network responses ──
        async def on_response(response):
            url = response.url
            ct = response.headers.get("content-type", "").lower()

            # Check URL for media patterns
            url_lower = url.lower()
            is_media_url = looks_like_media_url(url)

            # Check content-type for media
            is_media_ct = any(t in ct for t in ["video/", "audio/", "application/vnd.apple.mpegurl",
                                                 "application/x-mpegurl", "application/dash+xml"])

            if (is_media_url or is_media_ct) and not is_placeholder_media_url(url):
                try:
                    body = await response.body()
                    body_preview = body[:200].decode("utf-8", errors="replace")
                except Exception:
                    body_preview = ""

                is_m3u8 = ".m3u8" in url_lower or "#EXTM3U" in body_preview
                is_mp4 = ".mp4" in url_lower or (is_media_ct and "video/mp4" in ct)
                is_mpd = ".mpd" in url_lower or "<MPD" in body_preview

                FOUND_MEDIA.append({
                    "url": url,
                    "type": "m3u8" if is_m3u8 else "mpd" if is_mpd else "mp4",
                    "content_type": ct,
                    "size": len(body) if body_preview else 0,
                    "request_headers": dict(response.request.headers) if response.request else {},
                })

        page.on("response", on_response)

        # ── Also intercept requests (catches URLs before they're fetched) ──
        async def on_request(request):
            if looks_like_media_url(request.url) and not is_placeholder_media_url(request.url):
                if not any(m["url"] == request.url for m in FOUND_MEDIA):
                    FOUND_MEDIA.append({
                        "url": request.url,
                        "type": media_ext(request.url),
                        "content_type": "",
                        "size": 0,
                        "request_headers": dict(request.headers),
                    })

        page.on("request", on_request)

        # ── Load page ──
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=timeout * 1000)
        except Exception as e:
            # Page might still have loaded partially
            pass

        try:
            page_title = clean_page_title(await page.evaluate(PAGE_TITLE_EXPRESSION))
        except Exception:
            page_title = ""

        # ── Try to click play buttons ──
        click_selectors = [
            "[data-vid]",                    # novipnoad-style
            ".multilink-btn",               # novipnoad episode buttons
            ".play-btn", ".play-button",
            "[class*='play']", "[id*='play']",
            "video", "iframe",
            ".video-player", ".player-container",
        ]
        for sel in click_selectors:
            try:
                elements = await page.query_selector_all(sel)
                for el in elements:
                    try:
                        await el.click(timeout=2000)
                        await asyncio.sleep(1.5)  # wait for API calls
                    except Exception:
                        pass
            except Exception:
                pass

        # Wait for media to appear (up to timeout)
        waited = 0
        while not FOUND_MEDIA and waited < timeout:
            await asyncio.sleep(1)
            waited += 1

        # ── Also extract from page DOM ──
        try:
            html = await page.content()

            # Direct video URLs in source
            for m in re.finditer(r'(https?://[^\s"\'<>]+\.(?:m3u8|mp4|mpd)[^\s"\'<>]*)', html, re.I):
                url = m.group(1)
                if not is_placeholder_media_url(url) and not any(x["url"] == url for x in FOUND_MEDIA):
                    FOUND_MEDIA.append({"url": url, "type": media_ext(url),
                                        "content_type": "", "size": 0, "request_headers": {}})

            # JSON-embedded URLs
            for pat in [r'"url"\s*:\s*"(https?://[^"]+)"',
                        r'"src"\s*:\s*"(https?://[^"]+)"',
                        r'"video"\s*:\s*"(https?://[^"]+)"']:
                for m in re.finditer(pat, html, re.I):
                    url = m.group(1)
                    if looks_like_media_url(url):
                        if not any(x["url"] == url for x in FOUND_MEDIA):
                            FOUND_MEDIA.append({"url": url, "type": media_ext(url),
                                                "content_type": "", "size": 0, "request_headers": {}})
        except Exception:
            pass

        await browser.close()

    # Deduplicate and return
    seen = set()
    unique = []
    for m in FOUND_MEDIA:
        if m["url"] not in seen:
            seen.add(m["url"])
            unique.append(m)
    unique = [m for m in unique if not is_placeholder_media_url(m["url"])]
    unique.sort(key=media_score, reverse=True)

    if not unique:
        return {"success": True, "videos": [], "count": 0,
                "message": "No video URLs captured. Try increasing timeout or the site may require login."}

    videos = []
    for m in unique:
        import hashlib
        vid = hashlib.md5(m["url"].encode()).hexdigest()[:12]
        title = title_from_url(m["url"])
        if page_title and is_generic_title(title):
            title = page_title
        videos.append({
            "id": vid,
            "title": title,
            "duration": None,
            "duration_human": "??:??",
            "webpage_url": m["url"],
            "referer": (m.get("request_headers") or {}).get("referer") or (m.get("request_headers") or {}).get("Referer") or "",
            "source_title": page_title,
            "thumbnail": "",
            "description": f"Sniffed {m['type'].upper()} from network traffic",
            "uploader": "",
            "formats": [{
                "format_id": "best",
                "ext": media_ext(m["url"]),
                "height": None,
                "filesize": m.get("size"), "filesize_human": "???",
                "label": f"{media_ext(m['url']).upper()} · network sniff",
                "has_video": True, "has_audio": True,
            }],
            "format_count": 1,
        })

    return {"success": True, "videos": videos, "count": len(videos)}


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--timeout", type=int, default=45)
    ap.add_argument("--proxy", "-p")
    a = ap.parse_args()
    result = asyncio.run(sniff(a.url, a.timeout, a.proxy))
    print(json.dumps(result, ensure_ascii=False, indent=2))
