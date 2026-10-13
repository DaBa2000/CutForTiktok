"""Overlapping clips of the same VOD are shown as one: a clip that fully contains the others replaces them,
partially overlapping clips become one merged clip ("m-…" row, stitched seamlessly from the member clips)."""
import hashlib
import json
import subprocess
from pathlib import Path

import numpy as np

from . import db
from .config import paths
from .download import download_clip
from .media import FFMPEG, probe, run

TOL = 1.0  # vod_offset is whole seconds


def _span(r) -> tuple[float, float]:
    # Twitch's vod_offset is where the clip ENDS in the VOD (verified against matching video frames)
    return r["vod_offset"] - r["duration"], r["vod_offset"]


def update_groups() -> int:
    """Recompute overlap groups of all untouched clips. Returns number of hidden clips."""
    with db.conn() as c:
        rows = c.execute(
            "SELECT * FROM clips WHERE video_id IS NOT NULL AND vod_offset IS NOT NULL AND members IS NULL").fetchall()
        status = {r["id"]: r["status"] for r in c.execute("SELECT id, status FROM clips WHERE members IS NOT NULL")}
    by_vod: dict[str, list] = {}
    for r in rows:
        by_vod.setdefault(r["video_id"], []).append(r)
    hidden = 0
    for clips in by_vod.values():
        clips.sort(key=lambda r: _span(r)[0])
        comp, end = [], -1.0
        for r in clips + [None]:
            if r is not None and comp and _span(r)[0] < end - TOL:
                comp.append(r)
                end = max(end, _span(r)[1])
                continue
            if len(comp) > 1:
                hidden += _apply(comp, status)
            if r is not None:
                comp, end = [r], _span(r)[1]
    return hidden


def _point(ids: list[str], target: str) -> None:
    with db.conn() as c:
        c.executemany("UPDATE clips SET merged_into=? WHERE id=? AND status='new'", [(target, i) for i in ids])


def _apply(comp: list, merged_status: dict) -> int:
    new = [r for r in comp if r["status"] == "new"]
    # a moment already handled (edited/exported/posted/ignored) -> hide the other clips of it
    anchors = [r["id"] for r in comp if r["status"] != "new"]
    anchors += [r["merged_into"] for r in new if r["merged_into"] and merged_status.get(r["merged_into"], "new") != "new"]
    if anchors:
        _point([r["id"] for r in new if r["merged_into"] != anchors[0]], anchors[0])
        return len(new)
    start = min(_span(r)[0] for r in comp)
    end = max(_span(r)[1] for r in comp)
    for r in comp:  # one clip covers everything -> it stays, others hidden
        if _span(r)[0] <= start + TOL and _span(r)[1] >= end - TOL:
            _point([x["id"] for x in comp if x["id"] != r["id"]], r["id"])
            with db.conn() as c:
                c.execute("UPDATE clips SET merged_into=NULL WHERE id=?", (r["id"],))
            return len(comp) - 1
    ids = sorted(r["id"] for r in comp)
    mid = "m-" + hashlib.sha1(",".join(ids).encode()).hexdigest()[:16]
    top = max(comp, key=lambda r: r["views"] or 0)
    order = [r["id"] for r in sorted(comp, key=lambda r: _span(r)[0])]
    db.insert_clip(id=mid, streamer=top["streamer"], status="new", url=None)
    db.update_clip(
        mid, title=top["title"], views=sum(r["views"] or 0 for r in comp), duration=end - start,
        created_at=max(r["created_at"] for r in comp), thumbnail=top["thumbnail"], game_id=top["game_id"],
        happened_at=min((r["happened_at"] for r in comp if r["happened_at"]), default=None),
        video_id=top["video_id"], vod_offset=end, members=json.dumps(order),
    )
    # older merged rows of a smaller group are replaced by this one
    old = {r["merged_into"] for r in comp if r["merged_into"] and r["merged_into"] != mid}
    _point([r["id"] for r in comp] + [o for o in old if o.startswith("m-")], mid)
    return len(comp)


# ---------- building the merged video ----------

def _audio(path: Path, start: float, dur: float, sr: int) -> np.ndarray:
    p = subprocess.run([FFMPEG, "-v", "error", "-ss", f"{max(start, 0):.3f}", "-t", f"{dur:.3f}", "-i", str(path),
                        "-vn", "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"], capture_output=True)
    return np.frombuffer(p.stdout, dtype=np.float32)


def _align(a: Path, a_dur: float, b: Path, nominal: float, sr: int = 8000, search: float = 3.0) -> float:
    """Offset of clip b in clip a's timeline (a_time = b_time + offset), refined by audio cross-correlation
    around the nominal offset from vod_offset (whole seconds, so up to ~1s off)."""
    overlap = a_dur - nominal
    if overlap < 1.5:
        return nominal
    win = min(4.0, overlap - 0.5)
    b0 = max(0.0, overlap / 2 - win / 2)
    ref = _audio(b, b0, win, sr)
    a_start = max(0.0, nominal + b0 - search)
    hay = _audio(a, a_start, win + 2 * search, sr)
    if len(ref) < sr or len(hay) <= len(ref) or np.std(ref) < 1e-4:
        return nominal
    n = 1 << int(np.ceil(np.log2(len(hay) + len(ref))))
    corr = np.fft.irfft(np.fft.rfft(hay, n) * np.conj(np.fft.rfft(ref, n)), n)[: len(hay) - len(ref) + 1]
    k = int(np.argmax(corr))
    seg = hay[k:k + len(ref)]
    score = corr[k] / (np.linalg.norm(seg) * np.linalg.norm(ref) + 1e-9)
    return a_start + k / sr - b0 if score > 0.5 else nominal


def build(row) -> Path:
    """Download the member clips and stitch them into one video covering the whole group."""
    members = [db.get_clip(i) for i in json.loads(row["members"])]
    members = sorted([m for m in members if m], key=lambda m: _span(m)[0])
    end = max(_span(m)[1] for m in members)
    chain, covered = [], _span(members[0])[0]
    while covered < end - TOL:  # fewest clips covering the whole span
        nxt = max((m for m in members if _span(m)[0] <= covered + TOL), key=lambda m: _span(m)[1])
        if chain and nxt is chain[-1]:
            break
        chain.append(nxt)
        covered = _span(nxt)[1]
    files = [download_clip(m["id"], m["url"]) for m in chain]
    durs = [probe(f)[2] or m["duration"] for f, m in zip(files, chain)]
    # each clip plays to its end, the next one continues from the matching moment
    cuts = [(0.0, durs[0])]
    for i in range(1, len(chain)):
        off = _align(files[i - 1], durs[i - 1], files[i], _span(chain[i])[0] - _span(chain[i - 1])[0])
        cuts.append((max(0.0, durs[i - 1] - off), durs[i]))
    w, h, _ = probe(files[0])
    parts, fc = [], []
    for i, (a, b) in enumerate(cuts):
        fc.append(f"[{i}:v]trim=start={a:.3f}:end={b:.3f},setpts=PTS-STARTPTS,scale={w}:{h},fps=60,setsar=1[v{i}];"
                  f"[{i}:a]atrim=start={a:.3f}:end={b:.3f},asetpts=PTS-STARTPTS,aresample=48000[a{i}]")
        parts.append(f"[v{i}][a{i}]")
    out = paths().raw / f"{row['id']}.mp4"
    tmp = out.with_suffix(".tmp.mp4")
    cmd = [FFMPEG, "-y"]
    for f in files:
        cmd += ["-i", str(f)]
    cmd += ["-filter_complex", ";".join(fc) + ";" + "".join(parts) + f"concat=n={len(files)}:v=1:a=1[v][a]",
            "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-crf", "17", "-preset", "fast", "-c:a", "aac", str(tmp)]
    run(cmd)
    tmp.replace(out)
    for f in files:  # member downloads are not needed anymore
        f.unlink(missing_ok=True)
    return out
