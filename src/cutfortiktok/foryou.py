"""For You ranking of untouched clips.

score = (views + views-for-this-channel + freshness) x channel affinity, then re-ranked for variety:
- views: log scale, absolute (across all channels) and relative to the channel's usual clip views,
  so small channels' standout moments can compete with big channels' average ones
- freshness: halves every `HALF_LIFE_H` hours
- affinity: how often you kept vs. ignored this channel's clips before (smoothed, 0.6 .. 1.4);
  channels without history start neutral, so a channel can rise and fall but never drops to zero
- variety: every clip already placed from a channel lowers that channel's next clip by `REPEAT`,
  so no channel dominates the feed and every channel keeps showing up
"""
import math
from datetime import datetime, timezone
from statistics import median

from . import db
from .config import load_config

HALF_LIFE_H = 8.0
REPEAT = 0.8
ACCEPTED = ("kept", "pending_review", "approved", "uploaded")


def _age_h(iso: str, now: datetime) -> float:
    try:
        return max(0.0, (now - datetime.fromisoformat(iso.replace("Z", "+00:00"))).total_seconds() / 3600)
    except (ValueError, AttributeError):
        return 1e6


def rank(limit: int = 60, hidden: set[str] | None = None, max_age_min: int | None = None) -> list[dict]:
    min_views = load_config()["clips"].get("min_views", 0)
    with db.conn() as c:
        cands = [dict(r) for r in c.execute(
            "SELECT id,streamer,title,views,duration,COALESCE(happened_at, created_at) AS created_at,"
            "thumbnail,raw_path,error,"
            "COALESCE(json_array_length(members), 1) AS parts FROM clips "
            "WHERE status='new' AND merged_into IS NULL AND views >= ?", (min_views,))]
        hist = {r["streamer"]: (r["acc"], r["ign"]) for r in c.execute(
            f"SELECT streamer, SUM(status IN ({','.join('?' * len(ACCEPTED))})) AS acc, "
            "SUM(status='ignored') AS ign FROM clips GROUP BY streamer", ACCEPTED)}
        views_by = {}
        for r in c.execute("SELECT streamer, views FROM clips WHERE members IS NULL"):
            views_by.setdefault(r["streamer"], []).append(math.log1p(r["views"] or 0))
    if hidden:
        cands = [x for x in cands if x["streamer"] not in hidden]
    now = datetime.now(timezone.utc)
    if max_age_min:  # For You time filter: only clips of the last n minutes
        cands = [x for x in cands if _age_h(x["created_at"], now) * 60 <= max_age_min]
    if not cands:
        return []
    top = max(math.log1p(x["views"] or 0) for x in cands) or 1.0
    med = {s: median(v) for s, v in views_by.items()}
    for x in cands:
        lv = math.log1p(x["views"] or 0)
        absolute = lv / top
        relative = 1 / (1 + math.exp(-(lv - med.get(x["streamer"], lv))))  # 0.5 = usual for this channel
        fresh = 0.5 ** (_age_h(x["created_at"], now) / HALF_LIFE_H)
        acc, ign = hist.get(x["streamer"], (0, 0))
        rate = (acc + 1) / (acc + ign + 2)
        affinity = 0.6 + 0.8 * rate
        x["score"] = (0.35 * absolute + 0.30 * relative + 0.35 * fresh) * affinity
        x["why"] = {"views": round(absolute, 2), "channel": round(relative, 2), "fresh": round(fresh, 2),
                    "affinity": round(affinity, 2), "kept": acc or 0, "ignored": ign or 0}
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
