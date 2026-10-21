"""Small JSON state next to the database, shared by website, iPhone app and extension:
scheduled posts, scheduler on/off, pinned channels, hidden channels per page."""
import json
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


def hidden(page: str) -> list[str]:
    """Channels unticked in a page's streamer filter (page: foryou | selector)."""
    return _read("filters.json", {}).get(page, [])


def save_hidden(page: str, logins: list[str]) -> None:
    if page not in ("foryou", "selector"):
        raise ValueError("bad page")
    f = _read("filters.json", {})
    f[page] = sorted(set(logins))
    _file("filters.json").write_text(json.dumps(f))


def exclude_channel(login: str) -> None:
    """For You "Streamer ausblenden": unticked in the streamer filter of For You and Post Selector."""
    for page in ("foryou", "selector"):
        save_hidden(page, hidden(page) + [login])


def pins() -> list[str]:
    """Pinned channels (Post Selector: always on top)."""
    f = _file("pins.json")
    return json.loads(f.read_text()) if f.exists() else []


def save_pins(p: list[str]) -> None:
    _file("pins.json").write_text(json.dumps(sorted(set(p))))
