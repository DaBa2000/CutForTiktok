"""For You ranking of untouched clips.

score = (views + views-for-this-channel + freshness) x channel affinity x pinned x same moment,
then re-ranked for variety:
- views: log scale, absolute (across all channels) and relative to the channel's usual clip views,
  so small channels' standout moments can compete with big channels' average ones
- freshness: halves every `HALF_LIFE_H` hours
- affinity: how often you kept vs. ignored this channel's clips before (smoothed, 0.6 .. 1.4);
  channels without history start neutral, so a channel can rise and fall but never drops to zero
- pinned: channels pinned in the Post Selector get `PIN_BOOST`
- same moment: several clips of one situation mean it was a big moment: + `CROWD_BOOST` per doubling of the
  number of clips covering the same instant (peak overlap; merged groups can chain over minutes, so not their size)
- variety: every clip already placed from a channel lowers that channel's next clip by `REPEAT`,
  so no channel dominates the feed and every channel keeps showing up
"""
import json
import math
from datetime import datetime, timezone
from statistics import median

from . import db, store
from .config import load_config

HALF_LIFE_H = 8.0
REPEAT = 0.8
PIN_BOOST = 1.3
CROWD_BOOST = 0.15
CROWD_MAX = 16  # boost stops growing here (x1.6), one viral moment must not bury everything else
ACCEPTED = ("kept", "pending_review", "approved", "uploaded")


def _age_h(iso: str, now: datetime) -> float:
    try:
        return max(0.0, (now - datetime.fromisoformat(iso.replace("Z", "+00:00"))).total_seconds() / 3600)
    except (ValueError, AttributeError):
        return 1e6


def _peak(members: str | None, spans: dict, contained: int) -> int:
    """Clips of the same instant: most member clips overlapping at once (merged row), else this clip plus the
    clips fully inside it (hidden behind it)."""
    if not members:
        return contained
    ev = sorted(e for m in json.loads(members) if m in spans for e in ((spans[m][0], 1), (spans[m][1], -1)))
    best = cur = 0
    for _, d in ev:  # ends sort before starts at the same second: touching clips don't count as overlapping
        cur += d
        best = max(best, cur)
    return max(best, 1)


def rank(limit: int = 60, hidden: set[str] | None = None, max_age_min: int | None = None) -> list[dict]:
    min_views = load_config()["clips"].get("min_views", 0)
    with db.conn() as c:
        cands = [dict(r) for r in c.execute(
            "SELECT id,streamer,title,views,duration,COALESCE(happened_at, created_at) AS created_at,"
            "thumbnail,raw_path,error,"
            "COALESCE(json_array_length(members), 1) AS parts, members FROM clips "
            "WHERE status='new' AND merged_into IS NULL AND views >= ?", (min_views,))]
        hidden_n = dict(c.execute("SELECT merged_into, COUNT(*) FROM clips WHERE merged_into IS NOT NULL GROUP BY merged_into"))
        member_ids = {m for x in cands if x["members"] for m in json.loads(x["members"])}
        hist = {r["streamer"]: (r["acc"], r["ign"]) for r in c.execute(
            f"SELECT streamer, SUM(status IN ({','.join('?' * len(ACCEPTED))})) AS acc, "
            "SUM(status='ignored') AS ign FROM clips GROUP BY streamer", ACCEPTED)}
        spans = {r["id"]: (r["vod_offset"] - r["duration"], r["vod_offset"]) for r in c.execute(
            "SELECT id, vod_offset, duration FROM clips WHERE vod_offset IS NOT NULL AND members IS NULL")
            if r["id"] in member_ids}
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
    pins = set(store.pins())
    for x in cands:
        lv = math.log1p(x["views"] or 0)
        absolute = lv / top
        relative = 1 / (1 + math.exp(-(lv - med.get(x["streamer"], lv))))  # 0.5 = usual for this channel
        fresh = 0.5 ** (_age_h(x["created_at"], now) / HALF_LIFE_H)
        acc, ign = hist.get(x["streamer"], (0, 0))
        rate = (acc + 1) / (acc + ign + 2)
        affinity = 0.6 + 0.8 * rate
        pinned = PIN_BOOST if x["streamer"] in pins else 1.0
        n = _peak(x.pop("members"), spans, 1 + hidden_n.get(x["id"], 0))
        crowd = 1 + CROWD_BOOST * math.log2(min(n, CROWD_MAX))
        x["score"] = (0.45 * absolute + 0.25 * relative + 0.30 * fresh) * affinity * pinned * crowd
        x["why"] = {"views": round(absolute, 2), "channel": round(relative, 2), "fresh": round(fresh, 2),
                    "affinity": round(affinity, 2), "kept": acc or 0, "ignored": ign or 0,
                    "pinned": x["streamer"] in pins, "same_moment": n}
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
