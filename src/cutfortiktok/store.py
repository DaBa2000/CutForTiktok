"""Small JSON state next to the database, shared by website, iPhone app and extension:
scheduled posts, scheduler on/off, configurations (shown streamers + pinned channels)."""
import json
import re
import threading

from .config import paths

_lock = threading.Lock()


def _file(name: str):
    return paths().data / name


def schedules() -> dict:
    """{clip_id: {id, title, streamer, at (epoch ms), state, error}}; kept here so they survive extension
    reinstalls and are shared by website, app and extension."""
    f = _file("schedules.json")
    return json.loads(f.read_text()) if f.exists() else {}


def schedules_written() -> bool:
    """False until anything was planned (the extension then uploads its local copy)."""
    return _file("schedules.json").exists()


def _write(s: dict) -> None:
    _file("schedules.json").write_text(json.dumps(s, ensure_ascii=False, indent=1))


def save_schedules(s: dict) -> None:
    """Extension writes its whole list (states running/failed/done)."""
    with _lock:
        _write(s)


def plan(row, at: int | None) -> None:
    """Plan a post at `at` (epoch ms), or unplan it (None)."""
    with _lock:
        s = schedules()
        if at:
            s[row["id"]] = {"id": row["id"], "title": row["overlay_title"] or row["title"],
                            "streamer": row["streamer"], "at": int(at), "state": "planned"}
        else:
            s.pop(row["id"], None)
        _write(s)


def unplan(clip_id: str) -> None:
    with _lock:
        s = schedules()
        if s.pop(clip_id, None):
            _write(s)


def _read(name: str, default):
    f = _file(name)
    return json.loads(f.read_text()) if f.exists() else default


def settings() -> dict:
    """scheduler: auto-posting by the extension on/off (plans stay, nothing is posted while off).
    fill_after: minutes without a post after which a good/filler clip is posted automatically (0 = never).
    last_posted: epoch ms of the last post (set when a clip becomes "uploaded")."""
    return {"scheduler": True, "fill_after": 60, "last_posted": None, **_read("settings.json", {})}


def save_settings(patch: dict, internal: bool = False) -> dict:
    allowed = ("scheduler", "fill_after", "last_posted") if internal else ("scheduler", "fill_after")
    s = {**settings(), **{k: v for k, v in patch.items() if k in allowed}}
    s["fill_after"] = max(0, int(s["fill_after"] or 0))
    _file("settings.json").write_text(json.dumps(s))
    return s


# ---------- configurations ----------
# A configuration = which streamers are shown + pinned channels. The active one applies everywhere: For You,
# Discovery, background downloads (website and iPhone app). streamers None = all of accounts.txt (new ones too).

def _all_logins() -> list[str]:
    from .pipeline import allowlist  # pipeline doesn't import store; late import keeps it that way
    return sorted(allowlist())


def _configs() -> dict:
    d = _read("configs.json", None)
    if d is None:  # first start: one configuration from the old per-page filter + pins
        old = _read("filters.json", {}).get("foryou", [])
        logins = [l for l in _all_logins() if l not in old] if old else None
        d = {"active": "alle", "items": {"alle": {"name": "Alle Streamer", "streamers": logins, "pins": _read("pins.json", [])}}}
        _file("configs.json").write_text(json.dumps(d, ensure_ascii=False, indent=1))
    return d


def configs() -> dict:
    """{"active": id, "configs": [{id, name, streamers (null = all), pins}], "streamers": all logins}"""
    d = _configs()
    return {"active": d["active"], "configs": [{"id": k, **v} for k, v in d["items"].items()],
            "streamers": _all_logins()}


def active() -> dict:
    d = _configs()
    return {"id": d["active"], **d["items"][d["active"]]}


def active_streamers() -> set[str]:
    """Streamers of the active configuration (only these are shown and downloaded)."""
    a = active()["streamers"]
    return set(_all_logins()) if a is None else set(a)


def _save_configs(d: dict) -> None:
    _file("configs.json").write_text(json.dumps(d, ensure_ascii=False, indent=1))


def save_config(cid: str | None, name: str, streamers: list[str] | None, pins: list[str] | None = None) -> str:
    """Create (cid None) or change a configuration. Returns its id."""
    name = name.strip() or "Konfiguration"
    with _lock:
        d = _configs()
        if not cid:
            base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "konfig"
            cid, n = base, 2
            while cid in d["items"]:
                cid, n = f"{base}-{n}", n + 1
        old = d["items"].get(cid, {})
        d["items"][cid] = {"name": name, "streamers": None if streamers is None else sorted(set(streamers)),
                           "pins": sorted(set(old.get("pins", []) if pins is None else pins))}
        _save_configs(d)
    return cid


def activate_config(cid: str) -> None:
    with _lock:
        d = _configs()
        if cid not in d["items"]:
            raise ValueError("Konfiguration nicht gefunden")
        d["active"] = cid
        _save_configs(d)


def delete_config(cid: str) -> None:
    with _lock:
        d = _configs()
        if len(d["items"]) <= 1:
            raise ValueError("Die letzte Konfiguration kann nicht gelöscht werden")
        d["items"].pop(cid, None)
        if d["active"] not in d["items"]:
            d["active"] = next(iter(d["items"]))
        _save_configs(d)


def exclude_channel(login: str) -> None:
    """For You "Streamer ausblenden": removed from the active configuration."""
    a = active()
    save_config(a["id"], a["name"], sorted(active_streamers() - {login}))


def pins() -> list[str]:
    """Pinned channels of the active configuration (Discovery: on top, their clips downloaded in background)."""
    return active().get("pins", [])


def save_pins(p: list[str]) -> None:
    a = active()
    save_config(a["id"], a["name"], a["streamers"], p)
