import base64
import hashlib
import json
import secrets
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse

import requests

from .config import ROOT, env, require_env

TOKENS = ROOT / "tokens.json"
API = "https://open.tiktokapis.com/v2"
SCOPES = "user.info.basic,video.upload,video.publish"


def auth() -> None:
    """One-time OAuth (Authorization Code + PKCE). Opens a browser; local server catches the redirect."""
    require_env("TIKTOK_CLIENT_KEY", "TIKTOK_CLIENT_SECRET", "TIKTOK_REDIRECT_URI")
    redirect = env("TIKTOK_REDIRECT_URI")
    verifier = secrets.token_urlsafe(64)[:100]
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    url = "https://www.tiktok.com/v2/auth/authorize/?" + urlencode({
        "client_key": env("TIKTOK_CLIENT_KEY"), "scope": SCOPES, "response_type": "code",
        "redirect_uri": redirect, "state": state,
        "code_challenge": challenge, "code_challenge_method": "S256",
    })
    got: dict = {}

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            q = parse_qs(urlparse(self.path).query)
            got.update({k: v[0] for k, v in q.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"OK - you can close this tab.")
        def log_message(self, *a): pass

    u = urlparse(redirect)
    srv = HTTPServer((u.hostname, u.port or 80), H)
    print("Opening browser to authorize TikTok...\n", url)
    webbrowser.open(url)
    while "code" not in got and "error" not in got:
        srv.handle_request()
    if got.get("state") != state or "code" not in got:
        raise SystemExit(f"Auth failed: {got}")
    r = requests.post(f"{API}/oauth/token/", data={
        "client_key": env("TIKTOK_CLIENT_KEY"), "client_secret": env("TIKTOK_CLIENT_SECRET"),
        "code": got["code"], "grant_type": "authorization_code",
        "redirect_uri": redirect, "code_verifier": verifier,
    }, timeout=30)
    _save(r)
    print("Saved tokens.json")


def _save(r: requests.Response) -> dict:
    j = r.json()
    if "access_token" not in j:
        raise RuntimeError(f"TikTok token error: {j}")
    j["expires_at"] = time.time() + j["expires_in"]
    TOKENS.write_text(json.dumps(j, indent=2))
    return j


def _access_token() -> str:
    if not TOKENS.exists():
        raise SystemExit("Not authorized with TikTok. Run: cutfortiktok tiktok-auth")
    t = json.loads(TOKENS.read_text())
    if time.time() > t["expires_at"] - 300:
        r = requests.post(f"{API}/oauth/token/", data={
            "client_key": env("TIKTOK_CLIENT_KEY"), "client_secret": env("TIKTOK_CLIENT_SECRET"),
            "grant_type": "refresh_token", "refresh_token": t["refresh_token"],
        }, timeout=30)
        t = _save(r)
    return t["access_token"]


def _post(path: str, body: dict) -> dict:
    r = requests.post(
        f"{API}{path}", json=body, timeout=60,
        headers={"Authorization": f"Bearer {_access_token()}", "Content-Type": "application/json; charset=UTF-8"},
    )
    j = r.json()
    if j.get("error", {}).get("code", "ok") != "ok":
        raise RuntimeError(f"TikTok {path}: {j['error']}")
    return j.get("data", {})


def upload(video: Path, caption: str) -> str:
    """Upload one video. Returns publish_id. Mode via TIKTOK_POST_MODE (inbox|direct)."""
    require_env("TIKTOK_CLIENT_KEY", "TIKTOK_CLIENT_SECRET")
    size = video.stat().st_size
    if size > 64 * 1024 * 1024:
        raise RuntimeError("video >64MB; chunked upload not implemented")
    source = {"source": "FILE_UPLOAD", "video_size": size, "chunk_size": size, "total_chunk_count": 1}
    if env("TIKTOK_POST_MODE", "inbox") == "direct":
        info = _post("/post/publish/creator_info/query/", {})
        privacy = env("TIKTOK_PRIVACY", "SELF_ONLY")
        if privacy not in info.get("privacy_level_options", [privacy]):
            raise RuntimeError(f"privacy {privacy} not allowed; options: {info['privacy_level_options']}")
        data = _post("/post/publish/video/init/", {
            "post_info": {"title": caption[:2200], "privacy_level": privacy},
            "source_info": source,
        })
    else:
        data = _post("/post/publish/inbox/video/init/", {"source_info": source})
    pr = requests.put(
        data["upload_url"], data=video.read_bytes(), timeout=600,
        headers={"Content-Type": "video/mp4", "Content-Range": f"bytes 0-{size - 1}/{size}"},
    )
    pr.raise_for_status()
    return data["publish_id"]


def status(publish_id: str) -> dict:
    return _post("/post/publish/status/fetch/", {"publish_id": publish_id})
