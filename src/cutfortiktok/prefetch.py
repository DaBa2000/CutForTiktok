"""Background work so opening a clip is instant. Priority:
1. kept clips (For You "Behalten"): full preparation (download, facecam, transcript, first render)
2. the next clips of the For You feed: download only
3. channels marked `prep` in accounts.txt: full preparation of their best-ranked untouched clips
Nothing else is prepared automatically. Untouched downloads are evicted again beyond `prefetch.keep`."""
import threading
import time
import traceback
from pathlib import Path

from . import db, foryou, pipeline
from .config import load_config

_prep: list[str] = []  # clips of `prep` channels currently queued
_feed: list[str] = []
_cond = threading.Condition()
_failed: set[str] = set()
_current: str | None = None


def set_feed(ids: list[str]) -> None:
    """For You: the next clips of the feed (downloaded only)."""
    global _feed
    with _cond:
        _feed = [i for i in ids if i not in _failed]
        _cond.notify()


def wake() -> None:
    with _cond:
        _cond.notify()


def status() -> dict:
    return {"current": _current, "queued": len(_prep) + len(_feed)}


def _has_raw(row) -> bool:
    return bool(row["raw_path"]) and Path(row["raw_path"]).exists()


def _pick() -> tuple[str, str] | None:
    with db.conn() as c:
        kept = c.execute("SELECT id FROM clips WHERE status='kept' AND subs IS NULL ORDER BY kept_at").fetchall()
    for r in kept:
        if r["id"] not in _failed:
            return "prepare", r["id"]
    for cid in _feed:
        row = db.get_clip(cid)
        if row and row["status"] == "new" and not _has_raw(row) and cid not in _failed:
            return "download", cid
    global _prep
    chans = pipeline.prep_channels()
    if chans:
        n = load_config().get("prefetch", {}).get("ahead", 12)
        _prep = [x["id"] for x in foryou.rank(limit=400) if x["streamer"] in chans][:n]
        for cid in _prep:
            row = db.get_clip(cid)
            if row and not row["subs"] and cid not in _failed:
                return "prepare", cid
    return None


def _next() -> tuple[str, str]:
    with _cond:
        while True:
            job = _pick()
            if job:
                return job
            _cond.wait(timeout=30)


def _evict(protect: set[str]) -> None:
    keep = load_config().get("prefetch", {}).get("keep", 40)
    with db.conn() as c:
        rows = c.execute("SELECT id, status FROM clips WHERE raw_path IS NOT NULL AND status IN ('new','ignored') "
                         "ORDER BY updated_at").fetchall()
    # ignored clips first, then oldest untouched prefetched ones
    candidates = [r["id"] for r in rows if r["status"] == "ignored"] + [r["id"] for r in rows if r["status"] == "new"]
    excess = len(rows) - keep
    pinned = pipeline.protected()  # perspectives in use while editing
    for cid in candidates:
        if excess <= 0:
            break
        if cid in protect or cid in pinned:
            continue
        pipeline.release_files(cid)
        excess -= 1


def _loop() -> None:
    global _current
    while True:
        kind, cid = _next()
        while pipeline.user_is_waiting() or pipeline.exports_pending:  # user actions + exports first
            time.sleep(0.5)
        with pipeline.WORK_LOCK:
            row = db.get_clip(cid)
            if not row or (kind == "prepare" and row["subs"]) or (kind == "download" and _has_raw(row)):
                continue
            _current = cid
            try:
                t = time.time()
                if kind == "prepare":
                    pipeline.prepare(cid)
                else:
                    pipeline.fetch_raw(row)
                print(f"[prefetch] {kind} {row['streamer']}: {row['title'][:40]} ({time.time() - t:.0f}s)")
            except Exception as e:
                traceback.print_exc()
                _failed.add(cid)
                db.update_clip(cid, error=f"Vorbereitung fehlgeschlagen: {e}"[:500])
            finally:
                _current = None
        try:
            _evict(protect=set(_prep) | set(_feed))
        except Exception:
            traceback.print_exc()


def start() -> None:
    threading.Thread(target=_loop, daemon=True, name="prefetch").start()
