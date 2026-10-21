"""For You feed of untouched clips of the active configuration's streamers.

sort="rank" (default):
    score = (0.6 x views + 0.4 x freshness) x same moment
    - views: log scale relative to the most viewed candidate (0..1); more views -> higher
    - freshness: 1 for a brand-new clip, halves every `HALF_LIFE_H` hours; more recent -> higher
    - same moment: the more clips were merged into this one (several people clipped the same situation),
      the higher: x(1 + `CROWD_BOOST` per doubling), so 2 clips x1.25, 4 x1.5, 8 x1.75, 16 x2
    Each factor only ever raises a clip when it grows. Afterwards a mild re-rank for variety: every clip already
    placed from a channel lowers that channel's next clip by `REPEAT`, so one channel can't fill the whole feed.
sort="new": newest first · sort="top": most views first (no variety re-rank).
Optional: only one streamer (streamer profile in "For You style"), only clips of the last `max_age_min` minutes.
"""
import math
from datetime import datetime, timezone

from . import db, store
from .config import load_config

HALF_LIFE_H = 12.0
REPEAT = 0.85
CROWD_BOOST = 0.25
ACCEPTED = ("kept", "pending_review", "approved", "uploaded")
SORTS = ("rank", "new", "top")


def age_h(iso: str | None, now: datetime) -> float:
    try:
        return max(0.0, (now - datetime.fromisoformat(iso.replace("Z", "+00:00"))).total_seconds() / 3600)
    except (ValueError, AttributeError):
        return 1e6


def candidates(streamers: set[str], max_age_min: int | None = None) -> list[dict]:
    """Untouched, not merged away, above min_views, younger than max_age_days (and max_age_min)."""
    cc = load_config()["clips"]
    with db.conn() as c:
        cands = [dict(r) for r in c.execute(
            "SELECT id,streamer,title,views,duration,COALESCE(happened_at, created_at) AS created_at,"
            "thumbnail,raw_path,error,members FROM clips "
            "WHERE status='new' AND merged_into IS NULL AND views >= ?", (cc.get("min_views", 0),))]
        merged_n = dict(c.execute("SELECT merged_into, COUNT(*) FROM clips WHERE merged_into IS NOT NULL GROUP BY merged_into"))
    now = datetime.now(timezone.utc)
    limit = min(max_age_min or 1e9, cc.get("max_age_days", 7) * 1440)
    out = []
    for x in cands:
        if x["streamer"] not in streamers or age_h(x["created_at"], now) * 60 > limit:
            continue
        # clips merged into this one: a merged row's members point to it, a clip containing others keeps itself
        x["parts"] = merged_n.get(x["id"], 0) + (0 if x.pop("members") else 1)
        out.append(x)
    return out


def rank(limit: int = 60, streamers: set[str] | None = None, max_age_min: int | None = None,
         sort: str = "rank") -> list[dict]:
    cands = candidates(store.active_streamers() if streamers is None else streamers, max_age_min)
    if not cands:
        return []
    if sort == "new":
        return sorted(cands, key=lambda x: x["created_at"] or "", reverse=True)[:limit]
    if sort == "top":
        return sorted(cands, key=lambda x: -(x["views"] or 0))[:limit]
    now = datetime.now(timezone.utc)
    top = max(math.log1p(x["views"] or 0) for x in cands) or 1.0
    for x in cands:
        views = math.log1p(x["views"] or 0) / top
        fresh = 0.5 ** (age_h(x["created_at"], now) / HALF_LIFE_H)
        crowd = 1 + CROWD_BOOST * math.log2(max(1, x["parts"]))
        x["score"] = (0.6 * views + 0.4 * fresh) * crowd
        x["why"] = {"views": round(views, 2), "fresh": round(fresh, 2), "same_moment": x["parts"]}
    # greedy re-rank for variety
    best: dict[str, list[dict]] = {}
    for x in sorted(cands, key=lambda x: -x["score"]):
        best.setdefault(x["streamer"], []).append(x)
    placed: dict[str, int] = {}
    out = []
    while len(out) < limit and best:
        s = max(best, key=lambda s: best[s][0]["score"] * REPEAT ** placed.get(s, 0))
        out.append(best[s].pop(0))
        placed[s] = placed.get(s, 0) + 1
        if not best[s]:
            del best[s]
    return out
