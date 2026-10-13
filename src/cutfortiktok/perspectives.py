"""Other perspectives: clips of other channels that show the same moment (overlapping happened_at windows).

Offsets: `off` = other clip time - main clip time for the same moment. Base value from happened_at
(VOD start + position, ~±2s), refined by audio cross-correlation when both streams hear the same
thing (e.g. shared voice chat)."""
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np

from . import db
from .merge import _audio

MIN_OVERLAP = 2.0


def _ts(iso: str) -> datetime:
    return datetime.fromisoformat(iso.replace("Z", "+00:00"))


def find(clip_id: str, limit: int = 12) -> list[dict]:
    row = db.get_clip(clip_id)
    if not row or not row["happened_at"]:
        return []
    h0, d0 = _ts(row["happened_at"]), row["duration"] or 0
    lo = (h0 - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
    hi = (h0 + timedelta(seconds=d0)).strftime("%Y-%m-%dT%H:%M:%SZ")
    with db.conn() as c:
        rows = c.execute(
            "SELECT id,streamer,title,views,thumbnail,duration,happened_at,raw_path FROM clips "
            "WHERE streamer != ? AND merged_into IS NULL AND happened_at BETWEEN ? AND ?",
            (row["streamer"], lo, hi)).fetchall()
    out = []
    for r in rows:
        delta = (_ts(r["happened_at"]) - h0).total_seconds()  # other clip starts at this main time
        a, b = max(0.0, delta), min(d0, delta + (r["duration"] or 0))
        if b - a < MIN_OVERLAP:
            continue
        out.append({"id": r["id"], "streamer": r["streamer"], "title": r["title"], "views": r["views"],
                    "thumbnail": r["thumbnail"], "duration": r["duration"], "off": -delta,
                    "from": round(a, 2), "to": round(b, 2),
                    "ready": bool(r["raw_path"]) and Path(r["raw_path"]).exists()})
    # best coverage first, then views; one entry per channel
    out.sort(key=lambda x: (-(x["to"] - x["from"]), -(x["views"] or 0)))
    seen, res = set(), []
    for x in out:
        if x["streamer"] not in seen:
            seen.add(x["streamer"])
            res.append(x)
    return res[:limit]


def refine(main: Path, other: Path, off: float, at: float, sr: int = 8000, search: float = 4.0) -> tuple[float, bool]:
    """Refine `off` around main time `at` (inside the overlap). Returns (offset, refined?)."""
    win = 6.0
    ref = _audio(main, max(0.0, at), win, sr)
    o_start = max(0.0, at + off - search)
    hay = _audio(other, o_start, win + 2 * search, sr)
    if len(ref) < sr * 2 or len(hay) <= len(ref) or np.std(ref) < 1e-4:
        return off, False
    n = 1 << int(np.ceil(np.log2(len(hay) + len(ref))))
    corr = np.fft.irfft(np.fft.rfft(hay, n) * np.conj(np.fft.rfft(ref, n)), n)[: len(hay) - len(ref) + 1]
    csum = np.concatenate([[0.0], np.cumsum(hay.astype(np.float64) ** 2)])
    energy = np.sqrt(csum[len(ref):len(ref) + len(corr)] - csum[:len(corr)]) + 1e-9
    score = corr / (energy * np.linalg.norm(ref))
    k = int(np.argmax(score))
    if score[k] < 0.3:  # streams don't share audio here -> keep the stream-time estimate
        return off, False
    return o_start + k / sr - max(0.0, at), True
