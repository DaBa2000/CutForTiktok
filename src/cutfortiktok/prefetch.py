"""Background work, depending on what is being looked at right now (the page / app view sends its next clips):
- For You: the next clips of the feed
- streamer profile (Discovery → a streamer): the next clips in its order (newest / top)
- Discovery: the shown clips of 📌 pinned channels, in the chosen order (newest / top)
Those are downloaded only (merged clips stitched), no transcript. Priority:
1. edited clips that grew (merge.grow): rebuild
2. what is being looked at (the view's next clips, in order)
3. kept clips (For You "Behalten"): full preparation (download, facecam, transcript) -> editor opens instantly
A view's wish expires `FOCUS_TTL` s after its last update (page closed). Perspectives clicked while watching or
editing are downloaded right away by the server and kept (pipeline.keep). Untouched downloads beyond
`prefetch.keep` are evicted again, clips older than `clips.max_age_days` are deleted (pipeline.purge_old)."""
import threading
import time
import traceback
from pathlib import Path

from . import db, pipeline
from .config import load_config

FOCUS_TTL = 90
FOCUS_MAX = 12
VIEWS = ("foryou", "profile", "discovery", "editor")
_focus: dict = {"view": None, "ids": [], "at": 0.0}
_cond = threading.Condition()
_failed: set[str] = set()
_current: str | None = None


def set_focus(view: str, ids: list[str]) -> None:
    """The view being looked at and its next clips (in the order they will be shown)."""
    if view not in VIEWS:
        raise ValueError("bad view")
    with _cond:
        _focus.update(view=view, ids=[str(i) for i in ids][:FOCUS_MAX], at=time.time())
        _cond.notify()


def wake() -> None:
    """Something to do (kept clip)."""
    with _cond:
        _cond.notify()


def focus_ids() -> list[str]:
    return _focus["ids"] if time.time() - _focus["at"] < FOCUS_TTL else []


def status() -> dict:
    return {"current": _current, "view": _focus["view"] if focus_ids() else None,
            "queued": sum(1 for i in focus_ids() if i not in _failed and not _has_raw(db.get_clip(i)))}


def _has_raw(row) -> bool:
    return bool(row) and bool(row["raw_path"]) and Path(row["raw_path"]).exists()


def _pick() -> tuple[str, str] | None:
    with db.conn() as c:
        grown = c.execute("SELECT id FROM clips WHERE regrow IS NOT NULL AND merged_into IS NULL").fetchall()
        kept = c.execute("SELECT id FROM clips WHERE status='kept' AND subs IS NULL AND merged_into IS NULL "
                         "ORDER BY kept_at").fetchall()
    for r in grown:  # edited clip got new neighbouring clips: rebuild its video
        if r["id"] not in _failed:
            return "regrow", r["id"]
    for cid in focus_ids():
        row = db.get_clip(cid)
        if row and row["status"] not in ("ignored", "uploaded") and not _has_raw(row) and cid not in _failed:
            return "download", cid
    for r in kept:
        if r["id"] not in _failed:
            return "prepare", r["id"]
    return None


def _next() -> tuple[str, str]:
    with _cond:
        while True:
            job = _pick()
            if job:
                return job
            _cond.wait(timeout=30)


def _evict() -> None:
    keep = load_config().get("prefetch", {}).get("keep", 40)
    with db.conn() as c:
        rows = c.execute("SELECT id, status FROM clips WHERE raw_path IS NOT NULL AND status IN ('new','ignored') "
                         "ORDER BY updated_at").fetchall()
    # ignored clips first, then oldest untouched downloaded ones
    candidates = [r["id"] for r in rows if r["status"] == "ignored"] + [r["id"] for r in rows if r["status"] == "new"]
    excess = len(rows) - keep
    protect = set(focus_ids()) | pipeline.protected()
    for cid in candidates:
        if excess <= 0:
            break
        if cid in protect:
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
            if not row or (kind == "prepare" and row["subs"]) or (kind == "download" and _has_raw(row)) \
                    or (kind == "regrow" and not row["regrow"]):
                continue
            _current = cid
            try:
                t = time.time()
                if kind == "prepare":
                    pipeline.prepare(cid)
                elif kind == "regrow":
                    pipeline.finish_grow(cid)
                else:
                    pipeline.fetch_raw(row)
                print(f"[prefetch] {kind} {row['streamer']}: {(row['title'] or '')[:40]} ({time.time() - t:.0f}s)")
            except Exception as e:
                traceback.print_exc()
                _failed.add(cid)
                db.update_clip(cid, error=f"Vorbereitung fehlgeschlagen: {e}"[:500])
            finally:
                _current = None
        try:
            _evict()
        except Exception:
            traceback.print_exc()


def start() -> None:
    threading.Thread(target=_loop, daemon=True, name="prefetch").start()
