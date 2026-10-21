from pathlib import Path

import typer

from . import db, pipeline, server, twitch
from .config import load_config

app = typer.Typer(no_args_is_help=True, help="Twitch clips -> TikTok vertical shorts")


@app.command("review")
def review_cmd(listen: bool = True):
    """Start the web app (+ live clip listener). Website, iPhone app and browser extension all use it."""
    server.serve(load_config()["review"]["port"], listen=listen)


@app.command()
def sync(full: bool = False):
    """List new clips of accounts.txt streamers (--full rescans since clips.since)."""
    print(f"{pipeline.sync(full=full)} new clips")


@app.command()
def discover():
    """Suggest live Craft Attack streamers (does NOT add them; add vetted ones to accounts.txt)."""
    d = load_config()["discover"]
    known = set(pipeline.allowlist())
    for s in twitch.live_candidates(d["game_id"], d["title_keywords"], d.get("language")):
        mark = "(already in accounts.txt)" if s["user_login"] in known else ""
        print(f"{s['user_login']:<24} {s['viewer_count']:>6} viewers  {s['title'][:60]} {mark}")


@app.command()
def status():
    """Counts per status."""
    with db.conn() as c:
        for r in c.execute("SELECT status, COUNT(*) n FROM clips GROUP BY status"):
            print(f"{r['status']:<16}{r['n']}")


@app.command("add-local")
def add_local(video: Path, streamer: str = "local"):
    """Add a local video file as a clip (to try the editor without Twitch)."""
    print(pipeline.import_local(video.resolve(), streamer))
