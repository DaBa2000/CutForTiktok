import sqlite3
import threading
from contextlib import contextmanager

from .config import paths

# status lifecycle: see clips.py
SCHEMA = """
CREATE TABLE IF NOT EXISTS vods (id TEXT PRIMARY KEY, started_at TEXT);  -- started_at NULL = VOD gone
CREATE TABLE IF NOT EXISTS clips (
  id TEXT PRIMARY KEY,
  streamer TEXT NOT NULL,
  title TEXT,
  url TEXT,
  views INTEGER,
  duration REAL,
  created_at TEXT,
  status TEXT NOT NULL DEFAULT 'new',
  raw_path TEXT,
  out_path TEXT,
  caption TEXT,
  error TEXT,
  tiktok_publish_id TEXT,
  cam TEXT,            -- JSON [x,y,w,h] normalized, or null = no facecam
  game_x REAL,         -- 0..1 horizontal center of game crop
  trim_start REAL,
  trim_end REAL,
  subs TEXT,           -- JSON [{"words":[{"word","start","end"}]}] (source timeline)
  updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);
"""


MIGRATE = {"thumbnail": "TEXT", "game_id": "TEXT", "overlay_title": "TEXT", "cam_h": "INTEGER", "cam": "TEXT", "game_x": "REAL", "zoom": "REAL", "trim_start": "REAL", "trim_end": "REAL", "subs": "TEXT",
           # position in the stream (overlap detection) + merged groups (see merge.py)
           "vod_offset": "REAL", "video_id": "TEXT", "members": "TEXT", "merged_into": "TEXT",
           "kept_at": "TEXT",
           "happened_at": "TEXT",
           "switches": "TEXT",  # JSON [{"t": main time, "clip": other id | null, "off": other - main time}]
           "cuts": "TEXT",  # JSON [{"start": source time, "end": source time}] removed from the final timeline
           "tier": "TEXT",  # Scheduler rating of an exported clip: insane | very_good | good | filler
           "chain": "TEXT",  # joined clip: JSON [clip ids] its source video is made of, see clips.join
           "segments": "TEXT",  # joined clip: JSON [{start, end, clip, streamer, cam, game}] layout per part
           "regrow": "TEXT",  # edited clip that grew (merge.grow): {delta, old_raw, old_len} until finish_grow ran
           "game": "TEXT",  # JSON [x,y,w,h] game frame (layout.py); NULL = from game_x + zoom (older clips)
           "keyframes": "TEXT",  # JSON [{"t", "cam", "game", "ease"}] layout changes during the clip (layout.py)
           "keep_media": "INTEGER"}  # 1 = download stays (perspective watched / used), until the clip ages out


_migrated = False
_migrate_lock = threading.Lock()


def _migrate(c: sqlite3.Connection) -> None:
    """Schema + new columns, once per process (threads open connections concurrently at startup)."""
    global _migrated
    if _migrated:
        return
    with _migrate_lock:
        if _migrated:
            return
        c.executescript(SCHEMA)
        try:  # readers never block writers (many threads use the db); persists in the file once set
            c.execute("PRAGMA journal_mode=WAL")
        except sqlite3.OperationalError:  # another process holds the db right now: next start
            pass
        c.execute("CREATE INDEX IF NOT EXISTS clips_status ON clips(status)")
        have = {r[1] for r in c.execute("PRAGMA table_info(clips)")}
        for col, typ in MIGRATE.items():
            if col not in have:
                try:
                    c.execute(f"ALTER TABLE clips ADD COLUMN {col} {typ}")
                except sqlite3.OperationalError as e:  # added by another process meanwhile
                    if "duplicate column" not in str(e):
                        raise
        c.execute("CREATE INDEX IF NOT EXISTS clips_merged_into ON clips(merged_into)")
        c.commit()
        _migrated = True


@contextmanager
def conn():
    c = sqlite3.connect(paths().db, timeout=30)
    c.row_factory = sqlite3.Row
    _migrate(c)
    try:
        yield c
        c.commit()
    finally:
        c.close()


def has_clip(clip_id: str) -> bool:
    with conn() as c:
        return c.execute("SELECT 1 FROM clips WHERE id=?", (clip_id,)).fetchone() is not None


def insert_clip(**f) -> None:
    cols = ",".join(f)
    q = ",".join("?" * len(f))
    with conn() as c:
        c.execute(f"INSERT OR IGNORE INTO clips ({cols}) VALUES ({q})", tuple(f.values()))


def update_clip(clip_id: str, **f) -> None:
    sets = ",".join(f"{k}=?" for k in f)
    with conn() as c:
        c.execute(
            f"UPDATE clips SET {sets}, updated_at=CURRENT_TIMESTAMP WHERE id=?",
            (*f.values(), clip_id),
        )


def clips_by_status(*statuses: str) -> list[sqlite3.Row]:
    q = ",".join("?" * len(statuses))
    with conn() as c:
        return c.execute(
            f"SELECT * FROM clips WHERE status IN ({q}) ORDER BY created_at DESC", statuses
        ).fetchall()


def upsert_listed(**f) -> bool:
    """Insert a newly listed clip; for known ones refresh view count + stream position. Returns True if new."""
    with conn() as c:
        if c.execute("SELECT 1 FROM clips WHERE id=?", (f["id"],)).fetchone():
            # vod_offset often only appears minutes after the clip was made
            c.execute("UPDATE clips SET views=?, vod_offset=COALESCE(?, vod_offset), video_id=COALESCE(?, video_id) "
                      "WHERE id=?", (f["views"], f.get("vod_offset"), f.get("video_id"), f["id"]))
            return False
        cols = ",".join(f)
        c.execute(f"INSERT INTO clips ({cols}) VALUES ({','.join('?' * len(f))})", tuple(f.values()))
        return True


def get_clip(clip_id: str):
    with conn() as c:
        return c.execute("SELECT * FROM clips WHERE id=?", (clip_id,)).fetchone()
