from pathlib import Path

import typer

from . import db, facecam, pipeline, review, tiktok, twitch
from .config import load_config, paths

app = typer.Typer(no_args_is_help=True, help="Twitch clips -> TikTok vertical shorts")


@app.command()
def discover():
    """Suggest live Craft Attack streamers (does NOT add them; add vetted ones to config.yaml)."""
    d = load_config()["discover"]
    known = set(pipeline.allowlist())
    for s in twitch.live_candidates(d["game_id"], d["title_keywords"], d.get("language")):
        mark = "(already in allowlist)" if s["user_login"] in known else ""
        print(f"{s['user_login']:<24} {s['viewer_count']:>6} viewers  {s['title'][:60]} {mark}")


@app.command()
def sync(full: bool = False):
    """List new clips of accounts.txt streamers (--full rescans since clips.since)."""
    print(f"{pipeline.sync(full=full)} new clips")


@app.command("review")
def review_cmd(listen: bool = True):
    """Start the web app (+ live clip listener)."""
    review.serve(load_config()["review"]["port"], listen=listen)


@app.command()
def upload(limit: int = 5):
    """Upload approved clips to TikTok."""
    for row in db.clips_by_status("approved")[:limit]:
        try:
            pid = tiktok.upload(Path(row["out_path"]), row["caption"])
            db.update_clip(row["id"], status="uploaded", tiktok_publish_id=pid)
            print(f"uploaded {row['id']} -> publish_id {pid}")
        except Exception as e:
            db.update_clip(row["id"], status="failed", error=str(e)[:500])
            print(f"upload failed {row['id']}: {e}")


@app.command("tiktok-auth")
def tiktok_auth():
    """One-time TikTok OAuth login."""
    tiktok.auth()


@app.command("tiktok-status")
def tiktok_status():
    """Show TikTok processing status of uploaded clips."""
    for row in db.clips_by_status("uploaded"):
        print(row["id"], tiktok.status(row["tiktok_publish_id"]))


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


@app.command("facecam-preview")
def facecam_preview(video: Path, streamer: str = "local", redetect: bool = False):
    """Detect facecam, save an annotated frame to check it. Edit layouts.json to correct."""
    video = video.resolve()
    if redetect:
        facecam.save_layout(streamer, facecam.detect(video))
    layout = facecam.get_layout(streamer, video)
    img = paths().work / f"{streamer}_cam_preview.jpg"
    facecam.preview(video, layout, img)
    print(layout, "->", img)
