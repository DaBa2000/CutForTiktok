import hashlib
import json
import os
import re
import shutil
import threading
import time
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import db, facecam, layout, merge, twitch
from .config import ROOT, load_config, paths
from .download import download_clip
from .media import FFMPEG, probe, run
from .render import FONTS_DIR, render
from .subtitles import build_ass, chunk_words
from .transcribe import transcribe

ACCOUNTS = ROOT / "accounts.txt"
EXPORT_DIR = ROOT / "rendered_clips"


def allowlist() -> dict[str, dict]:
    """Streamers from accounts.txt (twitch URLs or logins), merged with optional config extras."""
    extra = {s["login"].lower(): s for s in (load_config().get("streamers") or [])}
    out = {}
    if ACCOUNTS.exists():
        for line in ACCOUNTS.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            url = line.split()[0]
            login = re.sub(r"^(https?://)?(www\.)?twitch\.tv/", "", url).strip("/").split("/")[0].lower()
            out[login] = extra.get(login, {"login": login})
    for login, s in extra.items():
        out.setdefault(login, s)
    return out


def make_caption(title: str, streamer: str, extra_tags: list[str] | None = None) -> str:
    c = load_config()["caption"]
    tags = list(dict.fromkeys([*c["hashtags"], *(extra_tags or [])]))
    return c["template"].format(title=title, streamer=streamer) + " " + " ".join(f"#{t}" for t in tags)


def sync(full: bool = False) -> int:
    """List clips (metadata only) of all streamers. full=True scans since `clips.since`,
    otherwise only the recent poll window. Returns number of newly listed clips."""
    cc = load_config()["clips"]
    now = datetime.now(timezone.utc)
    since = datetime.fromisoformat(cc["since"]).replace(tzinfo=timezone.utc)
    last = paths().data / "last_sync.txt"
    if not full and last.exists():
        # catch up from the last successful sync (minus window for Twitch's indexing delay)
        prev = datetime.fromisoformat(last.read_text().strip())
        since = max(since, min(prev, now) - timedelta(hours=cc["poll_window_hours"]))
    game = str(cc.get("only_game_id") or "")
    logins = list(allowlist())
    ids = twitch.user_ids(logins)
    for l in logins:
        if l not in ids:
            print(f"  unknown twitch login: {l}")
    new = 0
    for login, uid in ids.items():
        try:
            # Twitch silently truncates large ranges -> query in small windows
            clips, t = [], since
            while t < now:
                clips += twitch.clips_between(uid, t, min(now, t + timedelta(hours=3)))
                t += timedelta(hours=3)
        except Exception as e:
            print(f"  {login}: {e}")
            continue
        for c in clips:
            if game and c.get("game_id") != game:
                continue
            if c["duration"] < cc["min_duration"]:
                continue
            new += db.upsert_listed(
                id=c["id"], streamer=login, title=c["title"], url=c["url"],
                views=c["view_count"], duration=c["duration"], created_at=c["created_at"],
                thumbnail=c["thumbnail_url"], game_id=c.get("game_id"), status="new",
                vod_offset=c.get("vod_offset"), video_id=c.get("video_id") or None,
            )
    last.write_text(now.isoformat())
    update_happened_at()
    merge.update_groups()
    return new


def update_happened_at() -> int:
    """happened_at = VOD start + clip start in the VOD (vod_offset is where the clip ends, see merge.py).
    Clips without a VOD position keep using created_at (when the clip was made)."""
    with db.conn() as c:
        need = [r[0] for r in c.execute(
            "SELECT DISTINCT video_id FROM clips WHERE happened_at IS NULL AND vod_offset IS NOT NULL "
            "AND video_id IS NOT NULL AND members IS NULL AND video_id NOT IN (SELECT id FROM vods)")]
    if need:
        starts = twitch.vod_starts(need)
        with db.conn() as c:
            c.executemany("INSERT OR REPLACE INTO vods (id, started_at) VALUES (?, ?)",
                          [(v, starts.get(v)) for v in need])
    with db.conn() as c:
        rows = c.execute(
            "SELECT c.id, c.vod_offset, c.duration, v.started_at FROM clips c JOIN vods v ON v.id = c.video_id "
            "WHERE c.happened_at IS NULL AND c.vod_offset IS NOT NULL AND v.started_at IS NOT NULL").fetchall()
        upd = []
        for r in rows:
            t = datetime.fromisoformat(r["started_at"].replace("Z", "+00:00")) + timedelta(
                seconds=r["vod_offset"] - (r["duration"] or 0))
            upd.append((t.strftime("%Y-%m-%dT%H:%M:%SZ"), r["id"]))
        c.executemany("UPDATE clips SET happened_at=? WHERE id=?", upd)
    return len(upd)


next_sync_at = 0.0  # epoch seconds of the listener's next automatic scan (countdown in the UI)


def start_listener() -> threading.Thread:
    """Background thread: catch up since last sync, then poll for new clips every `poll_minutes`."""
    def loop():
        # one full re-scan to backfill stream positions (overlap merging) of clips listed before that existed
        marker = paths().data / "vod_backfill_done"
        full = not marker.exists()
        while True:
            try:
                n = sync(full=full)
                print(f"[listener] {datetime.now():%H:%M:%S} {n} new clips")
                if full:
                    marker.touch()
                full = False
            except Exception:
                traceback.print_exc()
            global next_sync_at
            wait = load_config()["clips"]["poll_minutes"] * 60
            next_sync_at = time.time() + wait
            time.sleep(wait)

    t = threading.Thread(target=loop, daemon=True, name="clip-listener")
    t.start()
    return t


# One heavy job (download/transcribe/render) at a time. Interactive requests get priority over
# background prefetching via user_work().
WORK_LOCK = threading.Lock()
_user_waiting = 0


class user_work:
    def __enter__(self):
        global _user_waiting
        _user_waiting += 1
        WORK_LOCK.acquire()

    def __exit__(self, *a):
        global _user_waiting
        _user_waiting -= 1
        WORK_LOCK.release()


def user_is_waiting() -> bool:
    return _user_waiting > 0


# queued background exports, see clips.export (priority: interactive > export jobs > prefetch)
exports_pending = 0


def release_files(clip_id: str) -> None:
    """Drop cached download/render/transcript of an untouched clip (prefetch cache eviction)."""
    row = db.get_clip(clip_id)
    p = paths()
    for f in (row["raw_path"], row["out_path"], p.work / f"{clip_id}.words.json", p.work / f"{clip_id}.ass"):
        if f:
            Path(f).unlink(missing_ok=True)
    db.update_clip(clip_id, raw_path=None, out_path=None, subs=None, cam=None, cam_h=None, game=None,
                   game_x=None, trim_start=None, trim_end=None)


_fetch_locks: dict[str, threading.Lock] = {}
_fetch_guard = threading.Lock()


def fetch_raw(row) -> Path:
    """Source video of a clip (merged groups are stitched from their member clips).
    Downloaded once: concurrent requests for the same clip wait for the first download."""
    with _fetch_guard:
        lock = _fetch_locks.setdefault(row["id"], threading.Lock())
    with lock:
        row = db.get_clip(row["id"])
        if row["raw_path"] and Path(row["raw_path"]).exists():
            return Path(row["raw_path"])
        raw = (merge.build(row) if row["members"] else build_joined(row["id"], json.loads(row["chain"])) if row["chain"]
               else download_clip(row["id"], row["url"]))
        db.update_clip(row["id"], raw_path=str(raw))
        return raw


def keep(ids) -> None:
    """These downloads stay (perspective watched in For You / the editor, parts of a joined clip) until the clip is
    older than `clips.max_age_days` (purge_old)."""
    with db.conn() as c:
        c.executemany("UPDATE clips SET keep_media=1 WHERE id=?", [(i,) for i in ids])


def protected() -> set[str]:
    """Clips whose downloads must stay: kept ones + perspectives used in switches of clips being edited."""
    with db.conn() as c:
        keep = {r[0] for r in c.execute("SELECT id FROM clips WHERE keep_media=1")}
        for r in c.execute("SELECT switches FROM clips WHERE switches IS NOT NULL AND switches != '[]' "
                           "AND status IN ('new','kept','pending_review')"):
            keep |= {s["clip"] for s in json.loads(r[0]) if s.get("clip")}
    return keep


def drop_media(clip_id: str) -> None:
    """Delete source + preview video, keep the edit state (exported / posted / ignored clips)."""
    row = db.get_clip(clip_id)
    for f in (row["raw_path"], row["out_path"]):
        if f:
            Path(f).unlink(missing_ok=True)
    db.update_clip(clip_id, raw_path=None, out_path=None)


def cleanup_media() -> int:
    """Drop videos of clips that left Discovery (exported, posted, ignored, hidden by a merge)."""
    with db.conn() as c:
        ids = [r[0] for r in c.execute(
            "SELECT id FROM clips WHERE (raw_path IS NOT NULL OR out_path IS NOT NULL) "
            "AND (status IN ('approved','uploaded','ignored') OR merged_into IS NOT NULL)")]
    for i in ids:
        drop_media(i)
    return len(ids)


def purge_old() -> int:
    """Clips older than `clips.max_age_days` (default 7) leave all lists (see clips.py) and their downloads and
    work files are deleted. Clips in Edit and exported ones keep theirs."""
    days = load_config()["clips"].get("max_age_days", 7)
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    with db.conn() as c:
        ids = [r[0] for r in c.execute(
            "SELECT id FROM clips WHERE COALESCE(happened_at, created_at) < ? "
            "AND status NOT IN ('kept','pending_review','approved') "
            "AND (raw_path IS NOT NULL OR out_path IS NOT NULL OR keep_media IS NOT NULL)", (cutoff,))]
    work = paths().work
    for i in ids:
        drop_media(i)
        for f in work.glob(f"{i}.*"):
            f.unlink(missing_ok=True)
        db.update_clip(i, keep_media=None)
    return len(ids)


def start_janitor() -> None:
    """Hourly: delete old clips' files (purge_old) and videos of finished clips (cleanup_media)."""
    def loop():
        while True:
            try:
                n, m = purge_old(), cleanup_media()
                if n or m:
                    print(f"[cleanup] {n} alte Clips, {m} fertige Clips: Videos gelöscht")
            except Exception:
                traceback.print_exc()
            time.sleep(3600)
    threading.Thread(target=loop, daemon=True, name="janitor").start()


def prepare(clip_id: str) -> None:
    """Download, detect facecam, transcribe; store editable state.
    Status is left unchanged (also used for background prefetching)."""
    row = db.get_clip(clip_id)
    raw = fetch_raw(row)
    lay = facecam.get_layout(row["streamer"], raw)
    words = transcribe(raw, paths().work)
    sw, sh, dur = probe(raw)
    r = effective_render(lay.get("cam_h"))
    fr = layout.frames(lay, sw, sh, r, r["cam_height"])
    tags = (allowlist().get(row["streamer"]) or {}).get("hashtags")
    row = db.get_clip(clip_id)  # title may have been changed in the Edit list while this ran
    db.update_clip(
        clip_id, cam=json.dumps(fr["cam"]), cam_h=r["cam_height"], game=json.dumps(fr["game"]), keyframes="[]",
        trim_start=0.0, trim_end=round(dur, 2),
        subs=json.dumps([{"words": ch} for ch in chunk_words(words)], ensure_ascii=False),
        overlay_title=row["overlay_title"] or row["title"],
        caption=row["caption"] or make_caption(row["overlay_title"] or row["title"], row["streamer"], tags),
    )
    db.update_clip(clip_id, error=None)


def finish_grow(clip_id: str) -> None:
    """Edited clip that grew into a bigger group (merge.grow): build the new video, fix the offset of the old part
    by audio, shift the edit state by the correction and add subtitles for the new parts."""
    row = db.get_clip(clip_id)
    g = json.loads(row["regrow"])
    old = paths().work / f"{clip_id}.old.mp4"  # building deletes member downloads (the old video may be one)
    if g.get("old_raw") and Path(g["old_raw"]).exists() and not old.exists():
        os.link(g["old_raw"], old)
    raw = fetch_raw(row)
    _, _, dur = probe(raw)
    delta, old_len = g["delta"], g["old_len"]
    if old.exists():  # exact place + real length of the old video inside the new one
        old_len = probe(old)[2] or old_len
        delta = merge.locate(raw, old, g["delta"], old_len)
        old.unlink()
    d = round(delta - g["delta"], 3)
    sh = lambda t: round(t + d, 3)
    subs = [{"words": [{**w, "start": sh(w["start"]), "end": sh(w["end"])} for w in ch["words"]]}
            for ch in json.loads(row["subs"] or "[]")]
    a, b = delta, delta + old_len  # covered by the old video (and its subtitles)
    words = [w for w in transcribe(raw, paths().work) if not (a - .2 <= w["start"] < b + .2)]
    subs = sorted(subs + [{"words": ch} for ch in chunk_words(words)], key=lambda ch: ch["words"][0]["start"])
    db.update_clip(
        clip_id, subs=json.dumps(subs, ensure_ascii=False), regrow=None, error=None,
        # trim reached the old start/end -> include the new parts there, else keep the chosen range
        trim_start=0.0 if sh(row["trim_start"] or 0) <= a + 0.5 else sh(row["trim_start"]),
        trim_end=round(dur, 2) if sh(row["trim_end"] or dur) >= b - 0.5 else min(round(dur, 2), sh(row["trim_end"])),
        cuts=json.dumps([{"start": sh(c["start"]), "end": sh(c["end"])} for c in json.loads(row["cuts"] or "[]")]),
        keyframes=json.dumps([{**k, "t": sh(k["t"])} for k in json.loads(row["keyframes"] or "[]")]),
        switches=json.dumps([{**x, "t": sh(x["t"]), "off": x["off"] - d} for x in json.loads(row["switches"] or "[]")]))
    print(f"[merge] {clip_id}: Video neu gebaut, alter Teil ab {delta:.2f}s")


def effective_render(cam_h: int | None) -> dict:
    """Render settings with a per-clip facecam/game split; subtitles stay inside the game area."""
    r = dict(load_config()["render"])
    if cam_h:
        r["cam_height"] = int(cam_h) // 2 * 2
    r["subs_y"] = min(max(r["subs_y"], r["cam_height"] + 170), r["height"] - 300)
    return r


def _segments(row, ts: float, te: float) -> list[tuple[float, float, dict | None]]:
    """Trimmed timeline split by perspective switches: (start, end, switch or None = main clip).
    Parts a perspective clip doesn't cover fall back to the main clip."""
    sw = sorted(json.loads(row["switches"] or "[]"), key=lambda s: s["t"])
    cuts, cur, t = [], None, ts
    for s in [x for x in sw if ts < x["t"] < te] + [{"t": te, "end": True}]:
        if s["t"] > t:
            cuts.append((t, s["t"], cur))
        t, cur = s["t"], (s if s.get("clip") else None)
    out = []
    for a, b, s in cuts:
        if not s:
            out.append((a, b, None))
            continue
        o = db.get_clip(s["clip"])
        lo, hi = -s["off"], (o["duration"] or 0) - s["off"]  # main times the other clip covers
        ca, cb = max(a, lo), min(b, hi)
        if cb - ca < 0.5:
            out.append((a, b, None))
            continue
        out += [x for x in ((a, ca, None), (ca, cb, s), (cb, b, None)) if x[1] - x[0] > 0.05]
    return out


def _without_cuts(segs: list[tuple[float, float, dict | None]], cuts: list[dict]) -> list[tuple[float, float, dict | None]]:
    """Subtract removed source-time ranges from already perspective-split segments."""
    out = []
    for a, b, switch in segs:
        here = a
        for cut in cuts:
            if cut["end"] <= here:
                continue
            if cut["start"] >= b:
                break
            if cut["start"] > here:
                out.append((here, min(cut["start"], b), switch))
            here = max(here, cut["end"])
            if here >= b:
                break
        if here < b:
            out.append((here, b, switch))
    return [(a, b, s) for a, b, s in out if b - a > .05]


def _frames(d, src: Path, r: dict) -> dict:
    sw, sh, _ = probe(src)
    return layout.frames(d, sw, sh, r, r["cam_height"])


def _main_layout(row, r: dict) -> tuple[dict, list[dict]]:
    """Frames + keyframes of the clip itself (layout.py)."""
    sw, sh, _ = probe(Path(row["raw_path"]))
    fr = layout.frames(row, sw, sh, r, r["cam_height"])
    kfs = layout.keyframes(json.loads(row["keyframes"] or "[]"), sw, sh, r, r["cam_height"], bool(fr["cam"]))
    return fr, kfs


def _render_switched(row, segs, out: Path, r: dict, preset: str, title: str | None) -> None:
    p = paths()
    parts, chunks, credits = [], [], []
    main_chunks = [c["words"] for c in json.loads(row["subs"] or "[]")]
    raw = Path(row["raw_path"])
    main_fr, kfs = _main_layout(row, r)
    out_t = 0.0
    for i, (a, b, s) in enumerate(segs):
        part = p.work / f"{row['id']}.seg{i}.mp4"
        if s and "part" in s:  # joined clip: this part keeps its own clip's facecam layout + credit
            render(raw, part, _frames({"zoom": row["zoom"], **s["part"]}, raw, r), None, r=r, trim=(a, b), preset="ultrafast")
            source_chunks = [ch for ch in main_chunks if a <= ch[0]["start"] < b]
            name = s["part"]["streamer"]
        elif s is None:
            render(raw, part, main_fr, None, r=r, kfs=kfs, trim=(a, b), preset="ultrafast")
            source_chunks = [ch for ch in main_chunks if a <= ch[0]["start"] < b]
            name = row["streamer"]
        else:
            o = db.get_clip(s["clip"])
            oraw = fetch_raw(o)
            # layout chosen for this perspective in the editor, else that streamer's default
            lay = s if s.get("game") else facecam.get_layout(o["streamer"], oraw)
            render(oraw, part, _frames(lay, oraw, r), None, r=r, trim=(a + s["off"], b + s["off"]), preset="ultrafast")
            words = [{**w, "start": w["start"] - s["off"], "end": w["end"] - s["off"]}
                     for w in transcribe(oraw, p.work)]
            source_chunks = chunk_words([w for w in words if a <= w["start"] < b])
            name = o["streamer"]
        # Each retained source segment follows directly after the previous one in the output.
        # Move subtitle timing into that compacted output timeline.
        chunks += [[{**w, "start": w["start"] - a + out_t, "end": w["end"] - a + out_t} for w in ch]
                   for ch in source_chunks]
        if credits and credits[-1][2] == "@" + name:
            credits[-1] = (credits[-1][0], out_t + b - a, credits[-1][2])
        else:
            credits.append((out_t, out_t + b - a, "@" + name))
        parts.append(part)
        out_t += b - a
    ass = p.work / f"{row['id']}.ass"
    build_ass(chunks, ass, duration=out_t, render=r, title=title, credits=credits)
    cmd = [FFMPEG, "-y"]
    for f in parts:
        cmd += ["-i", str(f)]
    n = len(parts)
    fc = "".join(f"[{i}:v][{i}:a]" for i in range(n)) + f"concat=n={n}:v=1:a=1[v][a];" \
         f"[v]ass={ass.resolve()}:fontsdir={FONTS_DIR}[vo]"
    run([*cmd, "-filter_complex", fc, "-map", "[vo]", "-map", "[a]", "-c:v", "libx264", "-preset", preset,
         "-crf", str(r["crf"]), "-pix_fmt", "yuv420p", "-r", "30", "-c:a", "aac", "-b:a", "160k",
         "-movflags", "+faststart", str(out)])
    for f in parts:
        f.unlink(missing_ok=True)


def render_clip(clip_id: str, preset: str = "medium", title: str | None = None) -> Path:
    """Render from the clip's stored edit state. title: overlay title instead of the clip's own ("" = none)."""
    row = db.get_clip(clip_id)
    title = row["overlay_title"] if title is None else title
    p = paths()
    raw = Path(row["raw_path"])
    out = p.out / f"{clip_id}.mp4"
    r = effective_render(row["cam_h"])
    ts, te = row["trim_start"] or 0.0, row["trim_end"]
    if row["segments"]:  # joined clip: one segment per part
        segs = [(max(a, ts), min(b, te), {"part": p}) for p in json.loads(row["segments"])
                for a, b in [(p["start"], p["end"])] if min(b, te) > max(a, ts)]
    else:
        segs = _segments(row, ts, te)
    cuts = json.loads(row["cuts"] or "[]")
    segs = _without_cuts(segs, cuts)
    if not segs:
        raise ValueError("Der gesamte Ausschnitt wurde entfernt")
    if cuts or any(s for _, _, s in segs):  # perspective switches or cut-out ranges
        _render_switched(row, segs, out, r, preset, title)
        db.update_clip(clip_id, out_path=str(out))
        return out
    ass = p.work / f"{clip_id}.ass"
    build_ass(
        [c["words"] for c in json.loads(row["subs"] or "[]")], ass,
        offset=ts, duration=te - ts, render=r,
        title=title, credit=f"@{row['streamer']}",
    )
    fr, kfs = _main_layout(row, r)
    render(raw, out, fr, ass, r=r, kfs=kfs, trim=(ts, te), preset=preset)
    db.update_clip(clip_id, out_path=str(out))
    return out


def import_local(video: Path, streamer: str = "local") -> str:
    """Add a local file as a clip (testing the editor without Twitch)."""
    clip_id = "local-" + video.stem
    db.insert_clip(id=clip_id, streamer=streamer, title=video.stem, url=str(video),
                   views=0, created_at=datetime.now(timezone.utc).isoformat(),
                   raw_path=str(video), status="new")
    return clip_id


def _export_tag(clip_id: str) -> str:
    """Short unique tag for file names (Twitch clip ids often share their first characters)."""
    return hashlib.sha1(clip_id.encode()).hexdigest()[:10]


def export_path(clip_id: str) -> Path | None:
    hits = sorted(EXPORT_DIR.glob(f"*_{_export_tag(clip_id)}.mp4")) if EXPORT_DIR.exists() else []
    return hits[0] if hits else None


def delete_export(clip_id: str) -> None:
    for f in (EXPORT_DIR.glob(f"*_{_export_tag(clip_id)}.*") if EXPORT_DIR.exists() else []):
        f.unlink()


def export_clip(clip_id: str) -> Path:
    """Copy the rendered video into rendered_clips/ for manual posting."""
    row = db.get_clip(clip_id)
    if not row["out_path"] or not Path(row["out_path"]).exists():
        raise RuntimeError("Noch nicht gerendert")
    EXPORT_DIR.mkdir(exist_ok=True)
    slug = re.sub(r"[^\w]+", "-", (row["overlay_title"] or row["title"] or "").lower()).strip("-")[:50]
    stem = f"{(row['created_at'] or '')[:10]}_{row['streamer']}_{slug}_{_export_tag(clip_id)}"
    for old in EXPORT_DIR.glob(f"*_{_export_tag(clip_id)}.*"):  # re-export replaces older version
        old.unlink()
    dst = EXPORT_DIR / f"{stem}.mp4"
    shutil.copy2(row["out_path"], dst)
    db.update_clip(clip_id, status="approved", error=None)
    drop_media(clip_id)  # only the exported file is kept (until posted)
    return dst


def build_joined(clip_id: str, ids: list[str]) -> Path:
    """Source video of a joined clip (Edit "Clips verbinden"): the clips' trim ranges one after another,
    scaled to the first clip's size."""
    rows = [db.get_clip(i) for i in ids]
    files = [fetch_raw(r) for r in rows]
    w, h, _ = probe(files[0])
    fc = []
    for i, r in enumerate(rows):
        ts, te = r["trim_start"] or 0.0, r["trim_end"]
        fc.append(f"[{i}:v]trim=start={ts:.3f}:end={te:.3f},setpts=PTS-STARTPTS,scale={w}:{h}:force_original_aspect_ratio=decrease,"
                  f"pad={w}:{h}:-1:-1,setsar=1,fps=60,format=yuv420p[v{i}];"
                  f"[{i}:a]atrim=start={ts:.3f}:end={te:.3f},asetpts=PTS-STARTPTS,aresample=48000[a{i}]")
    fc.append("".join(f"[v{i}][a{i}]" for i in range(len(rows))) + f"concat=n={len(rows)}:v=1:a=1[v][a]")
    out = paths().raw / f"{clip_id}.mp4"
    tmp = out.with_suffix(".tmp.mp4")
    cmd = [FFMPEG, "-y"]
    for f in files:
        cmd += ["-i", str(f)]
    run([*cmd, "-filter_complex", ";".join(fc), "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-crf", "17",
         "-preset", "fast", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(tmp)])
    tmp.replace(out)
    keep(ids)  # the single clips' downloads stay (rebuild after export would need them)
    return out
