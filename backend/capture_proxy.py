#!/usr/bin/env python3
"""
Local HTTP/HTTPS capture proxy — intercepts m3u8/mp4 URLs from browser traffic.
Like cat-catch but as a standalone proxy instead of a browser extension.

Usage:
  python3 capture_proxy.py [--port 8888] [--upstream http://127.0.0.1:7890]

Workflow:
  1. Start proxy: python3 capture_proxy.py
  2. Set browser to use proxy 127.0.0.1:8888
  3. Visit video page → solve Cloudflare → play video
  4. All m3u8/mp4 URLs appear in stdout (and can be piped to app)
"""

import asyncio, json, os, re, shutil, socket, subprocess, sys, tempfile, threading
from urllib.parse import parse_qs, unquote, urlparse

CAPTURED = []  # global capture list
MEDIA_EXTS = (".m3u8", ".mp4", ".mpd", ".webm", ".mkv", ".flv", ".mov", ".avi")
PLACEHOLDER_MEDIA_TOKENS = ("empty", "blank", "placeholder", "transparent", "loading", "preload", "1x1")
PAGE_TITLE_EXPRESSION = r"""
(() => {
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
})()
"""


def media_ext(url):
    parsed = urlparse(url)
    path = unquote(parsed.path).lower()
    query_values = []
    try:
        for values in parse_qs(parsed.query).values():
            query_values.extend(unquote(value).lower() for value in values)
    except Exception:
        query_values = []
    haystacks = [path, parsed.query.lower(), *query_values]
    for ext in MEDIA_EXTS:
        if any(item.endswith(ext) or ext in item for item in haystacks):
            return ext.lstrip(".")
    return "mp4"


def looks_like_media_url(url):
    parsed = urlparse(url)
    text = f"{unquote(parsed.path)}?{unquote(parsed.query)}".lower()
    return any(ext in text for ext in MEDIA_EXTS)


def is_placeholder_media_url(url):
    parsed = urlparse(url)
    name = unquote(parsed.path.rsplit("/", 1)[-1]).lower()
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


def media_score(url):
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


def title_from_url(url):
    parsed = urlparse(url)
    query = parse_qs(parsed.query)
    for key in ("fname", "filename", "name", "title"):
        value = query.get(key)
        if value and value[0]:
            return unquote(value[0])[:80]
    name = unquote(parsed.path.rsplit("/", 1)[-1])
    return (name or media_ext(url).upper())[:80]


def is_generic_title(title):
    lower = (title or "").lower().strip()
    return (
        not lower
        or lower in {"video", "captured video", "mp4", "m3u8", "chunklist.m3u8", "index.m3u8", "hd.mp4"}
        or lower.endswith((".m3u8", ".mpd"))
    )


def clean_page_title(title):
    title = re.sub(r"\s+", " ", title or "").strip()
    for sep in [" - 在线观看", "_免费在线观看", "免费在线观看", "在线观看", "高清播放", " - "]:
        if sep in title and len(title.split(sep, 1)[0]) >= 4:
            title = title.split(sep, 1)[0].strip()
            break
    return title[:120]


def cleanup_profile_locks(user_data_dir):
    for name in ("SingletonLock", "SingletonCookie", "SingletonSocket"):
        path = os.path.join(user_data_dir, name)
        try:
            if os.path.lexists(path):
                os.unlink(path)
        except OSError:
            pass


class CaptureProxy:
    def __init__(self, port=8888, upstream=None):
        self.port = port
        self.upstream = upstream
        self.server = None
        self._running = False
        self._lock = threading.Lock()

    async def handle(self, reader, writer):
        try:
            data = await asyncio.wait_for(reader.read(8192), timeout=30)
            if not data: return

            first = data.decode("latin-1", errors="replace").split("\r\n")[0]
            if not first.startswith("CONNECT") and not first.startswith(("GET","POST")):
                return

            if first.startswith("CONNECT"):
                await self._tunnel(reader, writer, data)
            else:
                await self._http(reader, writer, data, first)
        except: pass
        finally:
            try: writer.close(); await writer.wait_closed()
            except: pass

    async def _tunnel(self, reader, writer, data):
        """Handle HTTPS CONNECT tunneling."""
        line = data.decode("latin-1", errors="replace").split("\r\n")[0]
        host_port = line.split()[1]
        host, port = host_port.split(":") if ":" in host_port else (host_port, "443")
        port = int(port)

        try:
            remote_reader, remote_writer = await asyncio.wait_for(
                asyncio.open_connection(host, port), timeout=15
            )
        except:
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n"); await writer.drain(); return

        writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n"); await writer.drain()

        async def pipe(src, dst, direction):
            try:
                while True:
                    d = await asyncio.wait_for(src.read(65536), timeout=60)
                    if not d: break
                    dst.write(d); await dst.drain()
            except: pass

        await asyncio.gather(
            pipe(reader, remote_writer, "up"),
            pipe(remote_reader, writer, "dn"),
        )

    async def _http(self, reader, writer, data, first_line):
        """Handle plain HTTP request, checking URL for video patterns."""
        header_part = data.decode("latin-1", errors="replace")
        headers = header_part.split("\r\n")
        method, path, _ = first_line.split()

        # Build full URL
        host = ""
        for h in headers[1:]:
            if h.lower().startswith("host:"):
                host = h.split(":",1)[1].strip()
                break
        full_url = f"http://{host}{path}"

        # Check if this is a video URL
        url_lower = full_url.lower()
        path_lower = urlparse(url_lower).path
        is_video = any(
            path_lower.endswith(ext) or ext in path_lower
            for ext in [".m3u8", ".mp4", ".ts", ".mpd", ".m4s", ".flv"]
        ) or any(kw in url_lower for kw in ["/hls/","/vod/","/video/","m3u8","mp4:"])

        if is_video and not is_placeholder_media_url(full_url):
            cap = {"url": full_url, "time": __import__('time').time()}
            with self._lock:
                CAPTURED.append(cap)
            print(f"\n🎯 CAPTURED: {full_url}", flush=True)
            sys.stderr.write(json.dumps({"event":"capture","url":full_url})+"\n")
            sys.stderr.flush()

        # Forward request to origin server
        try:
            parsed = urlparse(f"http://{host}")
            rhost = parsed.hostname or host
            rport = parsed.port or 80

            # Rewrite to use upstream if configured
            if self.upstream:
                up = urlparse(self.upstream)
                rhost = up.hostname; rport = up.port or 80

            remote_reader, remote_writer = await asyncio.wait_for(
                asyncio.open_connection(rhost, rport), timeout=15
            )

            # Adjust Host header
            body = ""
            idx = header_part.find("\r\n\r\n")
            if idx >= 0:
                body = header_part[idx+4:]
                header_part = header_part[:idx]
            header_part = header_part.replace(f"Host: {host}", f"Host: {rhost}")

            fwd = (header_part + "\r\n\r\n" + body).encode("latin-1")
            remote_writer.write(fwd); await remote_writer.drain()

            # Read response and forward back
            resp_data = await asyncio.wait_for(remote_reader.read(65536), timeout=30)
            if b"#EXTM3U" in resp_data:
                with self._lock:
                    CAPTURED.append({"url": full_url, "m3u8_body": resp_data[:500].decode("latin-1","replace")})
                print(f"🎯 M3U8 CONTENT: {full_url}", flush=True)

            writer.write(resp_data); await writer.drain()

            try: remote_writer.close(); await remote_writer.wait_closed()
            except: pass
        except: pass

    async def start(self):
        self.server = await asyncio.start_server(self.handle, "127.0.0.1", self.port)
        self._running = True
        print(f"🔌 Capture proxy: 127.0.0.1:{self.port}", flush=True)
        print(f"   Upstream: {self.upstream or 'direct'}", flush=True)
        print(f"   Set browser HTTP proxy to 127.0.0.1:{self.port}", flush=True)
        print(f"   Then visit the video page and play it.", flush=True)
        async with self.server:
            await self.server.serve_forever()

    def stop(self):
        if self.server:
            self.server.close()
            self._running = False


def get_captured():
    with CaptureProxy._lock if hasattr(CaptureProxy, '_lock') else threading.Lock():
        got = list(CAPTURED)
        CAPTURED.clear()
        return got


async def sniff_browser(url, timeout=45, proxy=None, chrome_path=None, headless=True):
    """
    Open URL in headless Chrome and capture video URLs via CDP.
    Falls back to browser proxy capture.
    """
    # Try Chrome CDP approach
    chrome = chrome_path or "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    if not __import__('os').path.exists(chrome):
        return {"success": False, "error": "Chrome not found", "videos": []}

    # Use a random debug port
    import random
    debug_port = random.randint(9223, 9999)

    if headless:
        user_data_dir = tempfile.mkdtemp(prefix="vd-capture-chrome-")
    else:
        user_data_dir = os.path.expanduser("~/Library/Application Support/VideoDownloader/ChromeCapture")
        os.makedirs(user_data_dir, exist_ok=True)
        cleanup_profile_locks(user_data_dir)
    args = [chrome, f"--remote-debugging-port={debug_port}",
            f"--user-data-dir={user_data_dir}",
            "--no-first-run", "--no-default-browser-check",
            "--window-size=1440,900"]
    if headless:
        args += [
            "--headless=new",
            "--disable-gpu",
            "--no-sandbox",
            "--disable-blink-features=AutomationControlled",
            "--autoplay-policy=no-user-gesture-required",
            "--lang=zh-CN",
            "--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
        ]
    else:
        args.append("--new-window")

    if proxy:
        args.insert(1, f"--proxy-server={proxy.replace('http://','')}")

    process = None
    found = []
    found_headers = {}
    page_title = ""
    try:
        process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        await asyncio.sleep(2)

        # Connect via CDP
        try:
            import websockets
            ws_url = f"http://127.0.0.1:{debug_port}/json"
            import urllib.request
            resp = urllib.request.urlopen(ws_url, timeout=5)
            pages = json.loads(resp.read())
            ws = None
            for pg in pages:
                if pg.get("type") == "page":
                    ws_url = pg["webSocketDebuggerUrl"]
                    break

            if ws_url:
                async with websockets.connect(ws_url) as ws:
                    # Enable Network domain
                    await ws.send(json.dumps({"id": 1, "method": "Network.enable"}))
                    # Navigate
                    await ws.send(json.dumps({"id": 2, "method": "Page.enable"}))
                    await ws.send(json.dumps({"id": 3, "method": "Page.navigate", "params": {"url": url}}))

                    loop = asyncio.get_event_loop()
                    deadline = loop.time() + timeout
                    next_click = loop.time() + (4 if headless else 12)
                    found_at = None
                    while asyncio.get_event_loop().time() < deadline:
                        now = loop.time()
                        if found and found_at is None:
                            found_at = now
                        best_seen = max((media_score(item) for item in found), default=0)
                        if found_at is not None and (best_seen >= 96 or now - found_at > 8):
                            break
                        if now >= next_click:
                            next_click = now + 4
                            await ws.send(json.dumps({
                                "id": 9000 + int(now),
                                "method": "Runtime.evaluate",
                                "params": {
                                    "expression": """
(() => {
  if (/cloudflare|checking your browser|just a moment|verify you are human/i.test(document.body && document.body.innerText || '')) {
    return false;
  }
  const selectors = [
    'button', '[role=button]', '[class*=play i]', '[id*=play i]',
    '.dplayer-video-wrap', '.dplayer-play-icon', 'video', 'iframe'
  ];
  for (const selector of selectors) {
    for (const el of document.querySelectorAll(selector)) {
      try { el.click(); } catch (_) {}
      try { if (el.tagName === 'VIDEO') el.play(); } catch (_) {}
    }
  }
  return true;
})()
""",
                                    "awaitPromise": False,
                                },
                            }))
                        try:
                            msg = await asyncio.wait_for(ws.recv(), timeout=2)
                            data = json.loads(msg)
                            # Check for network requests
                            if "params" in data and "request" in data.get("params", {}):
                                request_info = data["params"]["request"]
                                req_url = request_info.get("url", "")
                                if looks_like_media_url(req_url) and not is_placeholder_media_url(req_url):
                                    found_headers[req_url] = request_info.get("headers", {})
                                    if req_url not in found:
                                        found.append(req_url)
                                        print(f"🎯 CDP: {req_url}", flush=True)
                            # Check for responses
                            if "params" in data and "response" in data.get("params", {}):
                                resp_url = data["params"]["response"].get("url", "")
                                mime = data["params"]["response"].get("mimeType", "")
                                if ("mpegurl" in mime or "video" in mime or looks_like_media_url(resp_url)) and not is_placeholder_media_url(resp_url):
                                    if resp_url not in found:
                                        found.append(resp_url)
                        except asyncio.TimeoutError:
                            pass
                        except: break
                    try:
                        await ws.send(json.dumps({
                            "id": 6001,
                            "method": "Runtime.evaluate",
                            "params": {"expression": PAGE_TITLE_EXPRESSION, "returnByValue": True},
                        }))
                        while True:
                            msg = await asyncio.wait_for(ws.recv(), timeout=2)
                            data = json.loads(msg)
                            if data.get("id") == 6001:
                                value = data.get("result", {}).get("result", {}).get("value", "")
                                page_title = clean_page_title(value)
                                break
                    except Exception:
                        pass
        except ImportError:
            # No websockets library — skip CDP
            pass

    except Exception as e:
        pass
    finally:
        if process:
            process.terminate()
            try: process.wait(timeout=5)
            except: process.kill()
        if headless:
            shutil.rmtree(user_data_dir, ignore_errors=True)

    if found:
        found = sorted([u for u in dict.fromkeys(found) if not is_placeholder_media_url(u)], key=media_score, reverse=True)
        videos = []
        for u in found:
            vid = __import__('hashlib').md5(u.encode()).hexdigest()[:12]
            headers = found_headers.get(u, {})
            referer = headers.get("Referer") or headers.get("referer") or ""
            title = title_from_url(u)
            if page_title and is_generic_title(title):
                title = page_title
            videos.append({
                "id": vid, "title": title,
                "duration": None, "duration_human": "??:??",
                "webpage_url": u, "thumbnail": "",
                "referer": referer,
                "source_title": page_title,
                "description": "Captured from browser traffic",
                "uploader": "",
                "formats": [{"format_id": "best", "ext": media_ext(u),
                    "height": None, "filesize": None, "filesize_human": "???",
                    "label": "Captured URL", "has_video": True, "has_audio": True}],
                "format_count": 1
            })
        return {"success": True, "videos": videos, "count": len(videos), "method": "cdp"}

    return {"success": False, "error": "No video URLs captured via CDP", "videos": []}


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8888)
    ap.add_argument("--upstream", default="http://127.0.0.1:7890")
    ap.add_argument("url", nargs="?", default=None)
    ap.add_argument("--timeout", type=int, default=45)
    ap.add_argument("--proxy")
    ap.add_argument("--interactive", action="store_true")
    a = ap.parse_args()

    if a.url:
        r = asyncio.run(sniff_browser(a.url, a.timeout, a.proxy or a.upstream, headless=not a.interactive))
        print(json.dumps(r, ensure_ascii=False, indent=2))
    else:
        proxy = CaptureProxy(a.port, a.upstream)
        try:
            asyncio.run(proxy.start())
        except KeyboardInterrupt:
            print("\nProxy stopped")
