#!/usr/bin/env python3
"""Local smoke tests for the video downloader backend."""

from __future__ import annotations

import contextlib
import functools
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

import downloader


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"{name} not found")
    return path


@contextlib.contextmanager
def serve(directory: Path, required_referer_suffix: str | None = None, require_origin: bool = False):
    class Handler(SimpleHTTPRequestHandler):
        def do_GET(self) -> None:
            if required_referer_suffix and self.path.split("?", 1)[0].endswith((".m3u8", ".ts")):
                referer = self.headers.get("Referer", "")
                if not referer.endswith(required_referer_suffix):
                    self.send_response(403)
                    self.end_headers()
                    self.wfile.write(b"missing referer")
                    return
                if require_origin:
                    expected_origin = f"http://{self.headers.get('Host', '')}"
                    if self.headers.get("Origin", "") != expected_origin:
                        self.send_response(403)
                        self.end_headers()
                        self.wfile.write(b"missing origin")
                        return
            super().do_GET()

    handler = functools.partial(Handler, directory=str(directory))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        thread.join(timeout=5)


def build_hls_fixture(root: Path) -> Path:
    require_tool("ffmpeg")
    src = root / "sample.mp4"
    http_dir = root / "http"
    http_dir.mkdir()
    run([
        "ffmpeg", "-y",
        "-f", "lavfi", "-i", "testsrc=size=320x180:rate=24",
        "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=44100",
        "-t", "4", "-c:v", "libx264", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-shortest", str(src),
    ])
    run([
        "ffmpeg", "-y", "-i", str(src), "-c", "copy",
        "-hls_time", "1", "-hls_playlist_type", "vod",
        "-hls_segment_filename", str(http_dir / "seg_%03d.ts"),
        str(http_dir / "index.m3u8"),
    ])
    (http_dir / "page.html").write_text(
        '<!doctype html><html><body><iframe src="player.html"></iframe></body></html>',
        encoding="utf-8",
    )
    (http_dir / "player.html").write_text(
        '<!doctype html><html><body><script>var source = "index.m3u8?token=local";</script></body></html>',
        encoding="utf-8",
    )
    return http_dir


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="video-downloader-test-") as tmp:
        root = Path(tmp)
        http_dir = build_hls_fixture(root)
        out_dir = root / "out"
        mkv_dir = root / "out-mkv"
        ffmpeg_dir = root / "out-ffmpeg"
        out_dir.mkdir()
        mkv_dir.mkdir()
        ffmpeg_dir.mkdir()

        with serve(http_dir, required_referer_suffix="/page.html", require_origin=True) as base:
            m3u8 = f"{base}/index.m3u8"
            page = f"{base}/page.html"

            embedded = downloader._html_detect(page)
            assert embedded, "HTML/iframe fallback did not find media URL"
            assert embedded[0]["webpage_url"].startswith(f"{base}/index.m3u8"), json.dumps(embedded, ensure_ascii=False)

            page_detected = downloader.detect(page, sniff=False)
            assert page_detected["success"], json.dumps(page_detected, ensure_ascii=False)

            detected = downloader.detect(m3u8)
            assert detected["success"], json.dumps(detected, ensure_ascii=False)
            assert detected["videos"][0]["formats"][0]["ext"] == "m3u8"

            downloaded = downloader.download(m3u8, str(out_dir), referer=page, progress_json=True)
            assert downloaded["success"], json.dumps(downloaded, ensure_ascii=False)
            assert downloaded["format"] == ".mp4", json.dumps(downloaded, ensure_ascii=False)
            assert os.path.exists(downloaded["file_path"])
            assert os.path.getsize(downloaded["file_path"]) > 0
            playable, _, probe_err = downloader._probe_media(downloaded["file_path"])
            assert playable, probe_err
            os.utime(downloaded["file_path"], (1, 1))
            resolved = downloader._resolve_downloaded_media(
                str(out_dir),
                99_999_999_999,
                f'[download] {downloaded["file_path"]} has already been downloaded\n',
            )
            assert resolved == downloaded["file_path"], resolved

            mkv = downloader.download(m3u8, str(mkv_dir), referer=page, output_format="mkv")
            assert mkv["success"], json.dumps(mkv, ensure_ascii=False)
            assert mkv["format"] == ".mkv", json.dumps(mkv, ensure_ascii=False)
            assert os.path.exists(mkv["file_path"])
            assert os.path.getsize(mkv["file_path"]) > 0
            playable, _, probe_err = downloader._probe_media(mkv["file_path"])
            assert playable, probe_err

            fallback_path, fallback_err, fallback_ok = downloader._download_direct_with_ffmpeg(
                m3u8,
                str(ffmpeg_dir),
                page,
                "mp4",
                "ffmpeg-fallback",
                downloader._proxy_env(None),
            )
            assert fallback_ok and fallback_path, fallback_err
            playable, _, probe_err = downloader._probe_media(fallback_path)
            assert playable, probe_err

    print("Backend self-test OK: webpage fallback + Referer/Origin-protected HLS download/merge + ffmpeg fallback -> playable MP4/MKV")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Backend self-test failed: {exc}", file=sys.stderr)
        raise
