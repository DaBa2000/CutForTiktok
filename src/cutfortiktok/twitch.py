import time
from datetime import datetime, timezone

import requests

from .config import env, require_env

API = "https://api.twitch.tv/helix"
_token: dict = {"value": None, "exp": 0.0}
_ids: dict[str, str] = {}


def _headers() -> dict:
    require_env("TWITCH_CLIENT_ID", "TWITCH_CLIENT_SECRET")
    if time.time() > _token["exp"] - 60:
        r = requests.post(
            "https://id.twitch.tv/oauth2/token",
            data={
                "client_id": env("TWITCH_CLIENT_ID"),
                "client_secret": env("TWITCH_CLIENT_SECRET"),
                "grant_type": "client_credentials",
            },
            timeout=20,
        )
        r.raise_for_status()
        j = r.json()
        _token.update(value=j["access_token"], exp=time.time() + j["expires_in"])
    return {"Authorization": f"Bearer {_token['value']}", "Client-Id": env("TWITCH_CLIENT_ID")}


def _get(path: str, params) -> dict:
    r = requests.get(f"{API}/{path}", headers=_headers(), params=params, timeout=20)
    r.raise_for_status()
    return r.json()


def user_ids(logins: list[str]) -> dict[str, str]:
    missing = [l for l in logins if l not in _ids]
    for i in range(0, len(missing), 100):
        for u in _get("users", [("login", l) for l in missing[i:i + 100]])["data"]:
            _ids[u["login"].lower()] = u["id"]
    return {l: _ids[l] for l in logins if l in _ids}


def _rfc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def clips_between(broadcaster_id: str, start: datetime, end: datetime, max_pages: int = 50) -> list[dict]:
    """All clips created in [start, end] (paginated)."""
    out, cursor = [], None
    for _ in range(max_pages):
        params = {"broadcaster_id": broadcaster_id, "started_at": _rfc(start), "ended_at": _rfc(end), "first": 100}
        if cursor:
            params["after"] = cursor
        j = _get("clips", params)
        out += j["data"]
        cursor = j.get("pagination", {}).get("cursor")
        if not cursor or not j["data"]:
            break
    return out


def vod_starts(video_ids: list[str]) -> dict[str, str]:
    """Start time (created_at, RFC3339) of VODs; deleted/unknown VODs are missing from the result."""
    out = {}
    for i in range(0, len(video_ids), 100):
        try:
            for v in _get("videos", [("id", x) for x in video_ids[i:i + 100]])["data"]:
                out[v["id"]] = v["created_at"]
        except requests.HTTPError:  # a batch with only deleted VODs answers 404
            pass
    return out


def live_candidates(game_id: str, keywords: list[str], language: str | None) -> list[dict]:
    """Live streams in the game whose title matches a keyword (suggestions only)."""
    out, cursor = [], None
    for _ in range(10):
        params = {"game_id": game_id, "first": 100}
        if language:
            params["language"] = language
        if cursor:
            params["after"] = cursor
        j = _get("streams", params)
        for s in j["data"]:
            if any(k.lower() in s["title"].lower() for k in keywords):
                out.append(s)
        cursor = j.get("pagination", {}).get("cursor")
        if not cursor:
            break
    return out
