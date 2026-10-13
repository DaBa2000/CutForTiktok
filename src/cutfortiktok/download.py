import subprocess
from pathlib import Path

from .config import paths

TIMEOUT = 180  # a hung download would otherwise hold the work lock forever


def download_clip(clip_id: str, url: str) -> Path:
    out = paths().raw / f"{clip_id}.mp4"
    if out.exists():
        return out
    # IPv4 + curl: on a broken IPv6 route yt-dlp's native downloader hangs on Twitch's clip CDN
    cmd = ["yt-dlp", "-q", "--no-warnings", "--no-update", "--force-ipv4", "--downloader", "curl",
           "-f", "best[ext=mp4]/best", "-o", str(out), url]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        for f in out.parent.glob(f"{out.name}.*"):  # leftover .part files
            f.unlink(missing_ok=True)
        raise RuntimeError(f"yt-dlp timed out after {TIMEOUT}s for {url}")
    if p.returncode != 0 or not out.exists():
        raise RuntimeError(f"yt-dlp failed for {url}: {p.stderr[-500:]}")
    return out
