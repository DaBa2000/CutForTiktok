"""Clip lifecycle: every status change and its side effects happen here, so a clip that is ignored or
exported in one place (For You, Edit, Discovery, editor, iPhone app) is gone from all of them.

status: new (listed) -> kept (For You "Behalten", prepared with priority) -> pending_review (edited)
        -> approved (exported to rendered_clips/) -> uploaded (posted)
        ignored: dropped by the user (from any stage)
Lists: For You = new · Edit = kept + pending_review · Discovery = new + pending_review ·
       Scheduler = approved. Clips being exported, ignored or merged into another clip show up nowhere.
For You and Discovery only show the active configuration's streamers (store.py) and clips younger than
`clips.max_age_days` (older ones are deleted, pipeline.purge_old)."""
import hashlib
import json
import queue
import threading
import time
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import db, facecam, foryou, perspectives, pipeline, prefetch, store
from .config import load_config

DISCOVERY = ("new", "pending_review")
EDITING = ("kept", "pending_review")
GONE = ("approved", "uploaded", "ignored")  # handled: not offered anywhere anymore (also not as perspective)
SET_BY_USER = ("new", "kept", "ignored", "uploaded", "restore")
TIERS = ("insane", "very_good", "good", "filler")  # Scheduler rating, best first

LIST_COLS = ("id,streamer,title,overlay_title,views,duration,status,error,thumbnail,"
             "COALESCE(happened_at, created_at) AS created_at,"  # moment in the stream, else clip creation
             "subs IS NOT NULL AS ready, COALESCE(json_array_length(members), 1) AS parts")


# ---------- lists ----------

def _cutoff() -> str:
    days = load_config()["clips"].get("max_age_days", 7)
    return (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")


def when(row) -> str:
    """Moment in the stream, else clip creation (sort key)."""
    return row["happened_at"] or row["created_at"] or ""


def discovery_list() -> list[dict]:
    """Discovery: clips still to decide on of the active configuration (overlapping clips are merged: members are
    hidden). `parts` = clips merged into it."""
    q = ",".join("?" * len(DISCOVERY))
    shown = store.active_streamers()
    with db.conn() as c:
        rows = c.execute(
            f"SELECT {LIST_COLS}, raw_path FROM clips WHERE status IN ({q}) AND merged_into IS NULL AND views >= ? "
            "AND COALESCE(happened_at, created_at) >= ? ORDER BY created_at DESC",
            (*DISCOVERY, load_config()["clips"].get("min_views", 0), _cutoff())).fetchall()
        merged_n = dict(c.execute("SELECT merged_into, COUNT(*) FROM clips WHERE merged_into IS NOT NULL GROUP BY merged_into"))
    out = []
    for r in rows:
        if r["streamer"] not in shown or r["id"] in exporting:
            continue
        d = dict(r)
        rp = d.pop("raw_path")
        d["downloaded"] = bool(rp) and Path(rp).exists()
        d["parts"] = merged_n.get(d["id"], 0) + (1 if d["parts"] <= 1 else 0)
        out.append(d)
    return out


def edit_list() -> list[dict]:
    """Edit: kept + edited, not yet exported (clips being exported stay visible with their state)."""
    q = ",".join("?" * len(EDITING))
    with db.conn() as c:
        rows = c.execute(f"SELECT {LIST_COLS}, raw_path, COALESCE(json_array_length(chain), 1) AS chained FROM clips WHERE status IN ({q}) AND merged_into IS NULL "
                         "ORDER BY COALESCE(kept_at, updated_at)", EDITING).fetchall()
    out = []
    for r in rows:  # downloaded = watchable already, while facecam + transcript are still being prepared
        d = dict(r)
        rp = d.pop("raw_path")
        d["downloaded"] = bool(rp) and Path(rp).exists()
        out.append(d)
    return out


def foryou_list(max_age_min: int | None, streamer: str | None = None, sort: str = "rank", skip: int = 0) -> list[dict]:
    """For You feed (all streamers of the active configuration, or one streamer's profile "For You style").
    skip: clips already watched in this session (the next ones after them get downloaded in background)."""
    if sort not in foryou.SORTS:
        raise ValueError("bad sort")
    ranked = foryou.rank(streamers={streamer} if streamer else None, max_age_min=max_age_min, sort=sort,
                         limit=200 if streamer else 60)
    prefetch.set_focus("profile" if streamer else "foryou", [x["id"] for x in ranked[skip:skip + 6]])
    for x in ranked:
        rp = x.pop("raw_path")
        x["ready"] = bool(rp) and Path(rp).exists()
    return ranked


def export_queue() -> list[dict]:
    """Scheduler / TikTok helper extension: exported, not yet posted."""
    out = []
    for r in db.clips_by_status("approved"):
        if f := pipeline.export_path(r["id"]):
            out.append({"id": r["id"], "streamer": r["streamer"], "title": r["overlay_title"] or r["title"],
                        "caption": r["caption"] or "", "thumbnail": r["thumbnail"], "file": str(f),
                        "filename": f.name, "tier": r["tier"]})
    return out


def used_per_channel() -> dict[str, int]:
    """Clips used per channel (kept, edited, exported or posted) -> Discovery channel order "meist genutzt"."""
    q = ",".join("?" * len(foryou.ACCEPTED))
    with db.conn() as c:
        return {r[0]: r[1] for r in c.execute(
            f"SELECT streamer, COUNT(*) FROM clips WHERE status IN ({q}) GROUP BY streamer", foryou.ACCEPTED)}


def perspectives_of(clip_id: str) -> list[dict]:
    """Clips of other channels at the same moment, without handled ones."""
    return [p for p in perspectives.find(clip_id) if db.get_clip(p["id"])["status"] not in GONE]


# ---------- status ----------

def set_status(clip_id: str, status: str) -> str:
    """User decision from any page. Returns the status that was set."""
    row = db.get_clip(clip_id)
    if status not in SET_BY_USER:
        raise ValueError("bad status")
    if status == "restore":  # un-ignore
        status = "pending_review" if row["subs"] else "new"
    db.update_clip(clip_id, status=status)
    if status == "kept":  # For You "Behalten": prepare with priority
        db.update_clip(clip_id, kept_at=time.strftime("%Y-%m-%d %H:%M:%S"), error=None)
        prefetch.wake()
    if status in ("ignored", "uploaded"):  # extension must not post it, exported file no longer needed
        store.unplan(clip_id)
        pipeline.delete_export(clip_id)
    if status == "ignored":
        pipeline.release_files(clip_id)
    if status == "ignored" and row["chain"]:  # joined clip dropped: its clips come back to the Edit list
        with db.conn() as c:
            c.execute("UPDATE clips SET merged_into=NULL WHERE merged_into=?", (clip_id,))
    if status == "uploaded":
        for i in json.loads(row["chain"] or "[]"):  # posted as part of this clip
            db.update_clip(i, status="uploaded")
            pipeline.drop_media(i)
        pipeline.drop_media(clip_id)
        store.save_settings({"last_posted": int(time.time() * 1000)}, internal=True)
    return status


def set_title(clip_id: str, title: str) -> None:
    """Edit list: overlay title; the generated caption follows it."""
    row = db.get_clip(clip_id)
    new = title.strip()
    old = row["overlay_title"] or row["title"] or ""
    cap = row["caption"]
    if cap and old and cap.startswith(old):
        cap = new + cap[len(old):]
    db.update_clip(clip_id, overlay_title=new, caption=cap)


FILL_TIERS = ("good", "filler")  # insane / very good clips are kept for planned slots
FILL_CLEARANCE_MIN = 15  # no gap filler right before a planned post


def fill_gap() -> dict | None:
    """Called by the extension every minute: if nothing was posted for `fill_after` minutes, plan the oldest
    exported good clip (else filler) for now; the extension then posts it like any planned post."""
    st = store.settings()
    now = int(time.time() * 1000)
    if not st["scheduler"] or not st["fill_after"]:
        return None
    if not st["last_posted"]:  # start counting from now
        store.save_settings({"last_posted": now}, internal=True)
        return None
    if now - st["last_posted"] < st["fill_after"] * 60_000:
        return None
    plans = store.schedules()
    if any(p.get("state") == "running" or (p.get("state") == "planned" and p["at"] < now + FILL_CLEARANCE_MIN * 60_000)
           for p in plans.values()):
        return None  # a post is running or (over)due soon anyway
    q = ",".join("?" * len(FILL_TIERS))
    with db.conn() as c:
        rows = c.execute(f"SELECT * FROM clips WHERE status='approved' AND tier IN ({q}) ORDER BY updated_at",
                         FILL_TIERS).fetchall()
    for tier in FILL_TIERS:
        for r in rows:
            if r["tier"] == tier and r["id"] not in plans and pipeline.export_path(r["id"]):
                store.plan(r, now)
                store.save_settings({"last_posted": now}, internal=True)  # a failed attempt waits a full gap again
                print(f"[fill] {r['tier']} clip after {st['fill_after']} min without post: {r['id']}")
                return {"id": r["id"], "tier": r["tier"]}
    return None


def set_tier(clip_id: str, tier: str | None) -> None:
    """Scheduler: how good an exported clip is (decides the order when distributing)."""
    if tier and tier not in TIERS:
        raise ValueError("bad tier")
    db.update_clip(clip_id, tier=tier or None)


# ---------- editing ----------

def save_edit(clip_id: str, body: dict) -> None:
    """Editor autosave: store the edit state and remember facecam/split/crop as the streamer's default."""
    row = db.get_clip(clip_id)
    ts, te = float(body["trim_start"]), float(body["trim_end"])
    if te - ts < 1:
        raise ValueError("Clip muss mindestens 1s lang sein")
    cuts = sorted(({"start": float(c["start"]), "end": float(c["end"])} for c in body.get("cuts") or []),
                  key=lambda c: c["start"])
    for c in cuts:
        if c["start"] < ts or c["end"] > te or c["end"] - c["start"] < .1:
            raise ValueError("Jeder ausgeschnittene Bereich muss innerhalb des Ausschnitts liegen und mindestens 0,1s lang sein")
    if any(b["start"] < a["end"] for a, b in zip(cuts, cuts[1:])):
        raise ValueError("Ausgeschnittene Bereiche dürfen sich nicht überschneiden")
    cam_h = max(240, min(1400, int(body.get("cam_h") or load_config()["render"]["cam_height"])))
    cam, game = _frame(body.get("cam")), _frame(body.get("game"))
    if not game:  # older app: game crop as game_x + zoom
        legacy = {"game_x": float(body.get("game_x", 0.5)), "zoom": max(0.0, min(1.0, float(body.get("zoom") or 0)))}
    else:
        legacy = {"game_x": None, "zoom": None}
    kfs = sorted(({"t": round(float(k["t"]), 3), "cam": _frame(k.get("cam")), "game": _frame(k.get("game")),
                   "ease": max(0.0, min(10.0, float(k.get("ease") or 0)))} for k in body.get("keyframes") or []),
                 key=lambda k: k["t"])
    switches = [{**s, "cam": _frame(s.get("cam")), "game": _frame(s.get("game"))} if "game" in s else s
                for s in body.get("switches") or []]
    db.update_clip(
        clip_id, cam=json.dumps(cam), game=json.dumps(game) if game else None, cam_h=cam_h, **legacy,
        keyframes=json.dumps(kfs), trim_start=ts, trim_end=te, caption=body["caption"],
        overlay_title=body.get("overlay_title", ""),
        subs=json.dumps(body["subs"], ensure_ascii=False), switches=json.dumps(switches),
        cuts=json.dumps(cuts), error=None,
        **({"segments": json.dumps(body["segments"])} if row["segments"] and body.get("segments") else {}),
        status="pending_review" if row["status"] in ("new", "kept") else row["status"])
    # remembered as the streamers' default layout (first frames of the clip; a perspective's own frames)
    facecam.save_layout(row["streamer"], {"cam": cam, "cam_h": cam_h, **({"game": game} if game else legacy)})
    for s in switches:
        if s.get("game") and s.get("streamer"):
            facecam.save_layout(s["streamer"], {**facecam.load_layouts().get(s["streamer"], {}), "cam": s["cam"], "game": s["game"]})


def _frame(v) -> list[float] | None:
    """Validated layout frame [x, y, w, h] (layout.py) or None."""
    if not v:
        return None
    x, y, w, h = (float(a) for a in v)
    if not (0.01 <= w <= 5 and 0.01 <= h <= 5 and -4 <= x <= 1 and -4 <= y <= 1):
        raise ValueError("Ungültiger Bildausschnitt")
    return [round(a, 5) for a in (x, y, w, h)]


def open_in_editor(clip_id: str) -> None:
    """Make sure source video + edit state exist (prepares on first open; refetches after export)."""
    row = db.get_clip(clip_id)
    with pipeline.user_work():
        if db.get_clip(clip_id)["regrow"]:  # grew by new neighbouring clips (merge.grow)
            pipeline.finish_grow(clip_id)
        elif not db.get_clip(clip_id)["subs"]:  # prefetch may have finished meanwhile
            pipeline.prepare(clip_id)
        elif not (row["raw_path"] and Path(row["raw_path"]).exists()):
            pipeline.fetch_raw(row)


# ---------- export ("Exportieren & weiter": final render + export in background) ----------

_jobs: "queue.Queue[str]" = queue.Queue()
exporting: set[str] = set()  # queued or rendering; hidden from Discovery


def export(clip_id: str, body: dict) -> None:
    save_edit(clip_id, body)
    _queue_export(clip_id)


def join(ids: list[str]) -> str:
    """Edit list "Clips verbinden": a new clip whose source video is these clips one after another (each cut
    to its trim range), with their subtitles; it is edited like any clip (title only at its start).
    The video is built when the editor opens it (pipeline.fetch_raw).
    The single clips leave the lists and come back if the joined clip is ignored. Returns the new id."""
    if len(ids) < 2 or len(set(ids)) != len(ids):
        raise ValueError("Mindestens zwei verschiedene Clips auswählen")
    rows = [db.get_clip(i) for i in ids]
    if any(not r or not r["subs"] for r in rows):
        raise ValueError("Alle Clips müssen fertig vorbereitet sein")
    jid = "j-" + hashlib.sha1(",".join(ids).encode()).hexdigest()[:16]
    subs, segments, t = [], [], 0.0
    for r in rows:
        ts, te = r["trim_start"] or 0.0, r["trim_end"]
        segments.append({"start": round(t, 3), "end": round(t + te - ts, 3), "clip": r["id"], "streamer": r["streamer"],
                         "cam": json.loads(r["cam"] or "null"), "game": json.loads(r["game"] or "null"),
                         "game_x": r["game_x"], "zoom": r["zoom"]})
        for ch in json.loads(r["subs"]):
            words = [{**w, "start": round(w["start"] - ts + t, 3), "end": round(w["end"] - ts + t, 3)}
                     for w in ch["words"] if ts <= w["start"] < te]
            if words:
                subs.append({"words": words})
        t += te - ts
    first = rows[0]
    db.insert_clip(id=jid, streamer=first["streamer"], status="pending_review", url=None)
    db.update_clip(
        jid, title=first["title"], overlay_title=first["overlay_title"], caption=first["caption"],
        thumbnail=first["thumbnail"], game_id=first["game_id"], created_at=first["created_at"],
        happened_at=first["happened_at"], views=sum(r["views"] or 0 for r in rows), duration=round(t, 2),
        cam=first["cam"], cam_h=first["cam_h"], game=first["game"], game_x=first["game_x"], zoom=first["zoom"], keyframes="[]",
        trim_start=0.0, trim_end=round(t, 2), subs=json.dumps(subs, ensure_ascii=False),
        switches="[]", cuts="[]", chain=json.dumps(ids), segments=json.dumps(segments), error=None, merged_into=None,
        kept_at=time.strftime("%Y-%m-%d %H:%M:%S"))
    with db.conn() as c:
        c.executemany("UPDATE clips SET merged_into=? WHERE id=?", [(jid, i) for i in ids])
    return jid


def _queue_export(clip_id: str) -> None:
    if clip_id in exporting:
        return
    exporting.add(clip_id)
    pipeline.exports_pending += 1
    _jobs.put(clip_id)


def _worker() -> None:
    while True:
        cid = _jobs.get()
        try:
            while pipeline.user_is_waiting():  # opening/preparing the next clip goes first
                time.sleep(0.3)
            if db.get_clip(cid)["status"] in GONE:  # ignored meanwhile
                continue
            with pipeline.WORK_LOCK:
                pipeline.render_clip(cid)
            if db.get_clip(cid)["status"] in GONE:
                continue
            pipeline.export_clip(cid)  # -> approved: leaves all lists, appears in the Scheduler
            print(f"[export] {cid} -> rendered_clips/")
        except Exception as e:
            traceback.print_exc()
            db.update_clip(cid, error=f"Export fehlgeschlagen: {e}"[:500])
        finally:
            exporting.discard(cid)
            pipeline.exports_pending -= 1


def start_export_worker() -> None:
    threading.Thread(target=_worker, daemon=True, name="export-jobs").start()



# ---------- back to Edit (Scheduler) ----------

def unexport(clip_id: str) -> None:
    """Exported clip goes back to the Edit list (plan + exported file dropped; the edit state stays)."""
    row = db.get_clip(clip_id)
    if row["status"] != "approved":
        raise ValueError("Nur exportierte Clips")
    store.unplan(clip_id)
    pipeline.delete_export(clip_id)
    db.update_clip(clip_id, status="pending_review" if row["subs"] else "kept", error=None)
