#!/usr/bin/env python3
"""Live website smoke-test runner.

These tests intentionally avoid downloading full videos. They run detection,
classify the outcome, and optionally probe the first media URL with a tiny
Range request to catch dead captured links.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import ssl
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent
DEFAULT_CONFIG = ROOT / "site_tests.json"
DOWNLOADER = ROOT / "downloader.py"
MEDIA_EXTS = (".m3u8", ".mp4", ".mpd", ".webm", ".mkv", ".flv", ".mov", ".avi")


def load_cases(path: Path) -> list[dict]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    cases = payload.get("sites", [])
    if not isinstance(cases, list):
        raise ValueError(f"{path} has no sites array")
    return [item for item in cases if isinstance(item, dict)]


def looks_like_media(url: str) -> bool:
    lower = url.lower()
    return any(ext in lower for ext in MEDIA_EXTS)


def classify(result: dict | None, timed_out: bool, stderr: str) -> str:
    if timed_out:
        return "timeout"
    if not isinstance(result, dict):
        return "bad-json"
    videos = result.get("videos") if isinstance(result.get("videos"), list) else []
    if result.get("success") and videos:
        if any(looks_like_media(str(video.get("webpage_url") or "")) for video in videos if isinstance(video, dict)):
            return "media"
        if any(
            (isinstance(video.get("formats"), list) and len(video["formats"]) > 0)
            or int(video.get("format_count") or 0) > 0
            for video in videos
            if isinstance(video, dict)
        ):
            return "extractable"
        return "metadata"
    text = "\n".join([
        str(result.get("error") or ""),
        str(result.get("details") or ""),
        stderr or "",
    ]).lower()
    if any(token in text for token in ["cloudflare", "403", "forbidden", "捕获", "browser capture"]):
        return "requires_capture"
    if any(token in text for token in ["cookie", "login", "signin", "登录", "cookies"]):
        return "requires_cookies"
    if any(token in text for token in ["drm", "copyright", "unsupported", "iqiyi", "爱奇艺", "not supported"]):
        return "protected_or_unsupported"
    if result.get("success") and not videos:
        return "no-media"
    return "failed"


def expectation_passed(expect: str, outcome: str) -> bool:
    if expect == "media":
        return outcome in {"media", "extractable"}
    if expect == "media_or_guidance":
        return outcome in {"media", "extractable", "requires_capture", "requires_cookies", "protected_or_unsupported"}
    if expect == "protected_or_guidance":
        return outcome in {"media", "extractable", "requires_capture", "requires_cookies", "protected_or_unsupported", "no-media", "timeout"}
    return outcome not in {"bad-json"}


def parse_json(stdout: str) -> dict | None:
    start = stdout.find("{")
    if start < 0:
        return None
    for end in range(len(stdout), start, -1):
        try:
            return json.loads(stdout[start:end])
        except json.JSONDecodeError:
            continue
    return None


def run_detect(case: dict, args: argparse.Namespace) -> dict:
    cmd = [sys.executable, str(DOWNLOADER), "detect", case["url"]]
    if args.no_sniff or case.get("no_sniff"):
        cmd.append("--no-sniff")
    if args.proxy:
        cmd += ["--proxy", args.proxy]
    if args.cookies_from_browser:
        cmd += ["--cookies-from-browser", args.cookies_from_browser]
    started = time.monotonic()
    timed_out = False
    try:
        proc = subprocess.run(
            cmd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=args.timeout,
        )
    except subprocess.TimeoutExpired as exc:
        proc = None
        timed_out = True
        stdout = exc.stdout if isinstance(exc.stdout, str) else ""
        stderr = exc.stderr if isinstance(exc.stderr, str) else ""
    else:
        stdout = proc.stdout
        stderr = proc.stderr

    result = parse_json(stdout)
    outcome = classify(result, timed_out, stderr)
    videos = result.get("videos") if isinstance(result, dict) and isinstance(result.get("videos"), list) else []
    first = videos[0] if videos and isinstance(videos[0], dict) else {}
    probe = None
    if args.probe_media and outcome == "media" and first.get("webpage_url") and looks_like_media(str(first["webpage_url"])):
        probe = probe_media(str(first["webpage_url"]), str(first.get("referer") or case["url"]), args.probe_timeout)
        if not probe.get("ok"):
            outcome = "media-probe-failed"

    expect = str(case.get("expect") or "media_or_guidance")
    passed = expectation_passed(expect, outcome)
    return {
        "name": case.get("name") or urlparse(case["url"]).netloc,
        "group": case.get("group") or "",
        "url": case["url"],
        "expect": expect,
        "outcome": outcome,
        "passed": passed,
        "seconds": round(time.monotonic() - started, 2),
        "title": first.get("title") or "",
        "media_url": first.get("webpage_url") or "",
        "referer": first.get("referer") or "",
        "method": result.get("method") if isinstance(result, dict) else "",
        "error": (result.get("error") if isinstance(result, dict) else stderr or "timeout") or "",
        "probe": probe,
        "notes": case.get("notes") or "",
    }


def probe_media(url: str, referer: str, timeout: int) -> dict:
    origin = ""
    if referer:
        parsed = urlparse(referer)
        if parsed.scheme and parsed.netloc:
            origin = f"{parsed.scheme}://{parsed.netloc}"
    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
        "Accept": "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Range": "bytes=0-4095",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "cross-site",
    }
    if referer:
        headers["Referer"] = referer
    if origin:
        headers["Origin"] = origin
    curl_result = probe_media_with_curl(url, headers, timeout)
    if curl_result is not None and curl_result.get("ok"):
        return curl_result

    contexts: list[tuple[str, ssl.SSLContext | None]] = [("system", None)]
    try:
        import certifi  # type: ignore
        contexts.insert(0, ("certifi", ssl.create_default_context(cafile=certifi.where())))
    except Exception:
        pass
    contexts.append(("unverified", ssl._create_unverified_context()))

    last_error = ""
    for label, context in contexts:
        try:
            req = Request(url, headers=headers)
            with urlopen(req, timeout=timeout, context=context) as resp:
                chunk = resp.read(4096)
                return {
                    "ok": 200 <= resp.status < 300,
                    "status": resp.status,
                    "content_type": resp.headers.get("content-type", ""),
                    "bytes": len(chunk),
                    "tls": label,
                    "tls_unverified": label == "unverified",
                }
        except Exception as exc:
            last_error = str(exc)
            if "CERTIFICATE_VERIFY_FAILED" not in last_error and label != "unverified":
                break
    if curl_result is not None and curl_result.get("error"):
        last_error = f"{last_error}; curl: {curl_result['error']}" if last_error else curl_result["error"]
    return {"ok": False, "error": last_error}


def probe_media_with_curl(url: str, headers: dict[str, str], timeout: int) -> dict | None:
    curl = shutil.which("curl")
    if not curl:
        return None
    cmd = [
        curl,
        "-L",
        "-sS",
        "--range", "0-4095",
        "--max-time", str(timeout),
        "-o", os.devnull,
        "-w", "status=%{http_code}\\ncontent_type=%{content_type}\\nbytes=%{size_download}\\n",
    ]
    for key, value in headers.items():
        lower = key.lower()
        if lower == "user-agent":
            cmd += ["-A", value]
        elif lower == "referer":
            cmd += ["-e", value]
        elif lower == "range":
            continue
        else:
            cmd += ["-H", f"{key}: {value}"]
    cmd.append(url)
    try:
        proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout + 5)
    except Exception as exc:
        return {"ok": False, "error": str(exc)}
    fields: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key] = value
    try:
        status = int(fields.get("status") or 0)
    except ValueError:
        status = 0
    try:
        size = int(float(fields.get("bytes") or 0))
    except ValueError:
        size = 0
    ok = proc.returncode == 0 and 200 <= status < 300 and size > 0
    return {
        "ok": ok,
        "status": status,
        "content_type": fields.get("content_type", ""),
        "bytes": size,
        "tool": "curl",
        "error": proc.stderr.strip() if not ok else "",
    }


def filter_cases(cases: list[dict], args: argparse.Namespace) -> list[dict]:
    if args.url:
        return [{
            "name": args.name or urlparse(args.url).netloc or "ad hoc URL",
            "url": args.url,
            "group": "ad-hoc",
            "expect": args.expect,
            "notes": "Ad hoc URL supplied from CLI.",
        }]
    out = []
    wanted = set(args.group or [])
    wanted_names = {name.lower() for name in (args.name_filter or [])}
    for case in cases:
        if case.get("sensitive") and not args.include_sensitive:
            continue
        if wanted and case.get("group") not in wanted:
            continue
        if wanted_names and str(case.get("name", "")).lower() not in wanted_names:
            continue
        out.append(case)
    if args.max_sites:
        out = out[:args.max_sites]
    return out


def print_table(results: list[dict]) -> None:
    for item in results:
        marker = "PASS" if item["passed"] else "FAIL"
        title = f" · {item['title']}" if item.get("title") else ""
        print(f"{marker:4} {item['outcome']:24} {item['seconds']:>6.2f}s  {item['name']}{title}")
        if item.get("probe"):
            probe = item["probe"]
            if probe.get("ok"):
                print(f"     probe {probe.get('status')} {probe.get('content_type')} {probe.get('bytes')} bytes")
            else:
                print(f"     probe failed: {probe.get('error')}")
        if not item["passed"] and item.get("error"):
            print(f"     {str(item['error'])[:220]}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--group", action="append")
    parser.add_argument("--name-filter", action="append")
    parser.add_argument("--include-sensitive", action="store_true")
    parser.add_argument("--timeout", type=int, default=150)
    parser.add_argument("--probe-timeout", type=int, default=18)
    parser.add_argument("--probe-media", action="store_true")
    parser.add_argument("--proxy")
    parser.add_argument("--cookies-from-browser")
    parser.add_argument("--no-sniff", action="store_true")
    parser.add_argument("--max-sites", type=int)
    parser.add_argument("--jobs", type=int, default=2, help="Number of live sites to test concurrently.")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--strict", action="store_true", help="Return non-zero when any expectation fails.")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--url", help="Run one ad hoc URL instead of the configured matrix.")
    parser.add_argument("--name")
    parser.add_argument("--expect", default="media_or_guidance")
    args = parser.parse_args()

    cases = [] if args.url else load_cases(args.config)
    selected = filter_cases(cases, args)
    if args.list:
        for case in selected:
            print(f"{case.get('group',''):<20} {case.get('name','')}  {case.get('url','')}")
        return 0
    if not selected:
        print("No live site cases selected.", file=sys.stderr)
        return 2

    jobs = max(1, min(args.jobs, len(selected)))
    results: list[dict | None] = [None] * len(selected)
    serial_items = [(index, case) for index, case in enumerate(selected) if case.get("serial")]
    parallel_items = [(index, case) for index, case in enumerate(selected) if not case.get("serial")]
    if jobs == 1:
        for index, case in parallel_items:
            results[index] = run_detect(case, args)
    elif parallel_items:
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            futures = {pool.submit(run_detect, case, args): index for index, case in parallel_items}
            for future in as_completed(futures):
                results[futures[future]] = future.result()
    for index, case in serial_items:
        results[index] = run_detect(case, args)
    completed = [item for item in results if isinstance(item, dict)]
    payload = {
        "success": all(item["passed"] for item in completed),
        "count": len(completed),
        "passed": sum(1 for item in completed if item["passed"]),
        "failed": sum(1 for item in completed if not item["passed"]),
        "results": completed,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print_table(completed)
        print(f"\nLive site smoke tests: {payload['passed']}/{payload['count']} expectations passed")
    return 1 if args.strict and not payload["success"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
