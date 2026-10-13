"""Local web app: clip list (live via listener), editor (facecam, trim, title, subtitles, caption),
export to rendered_clips/ / ignore / mark as posted."""
import json
import queue
import re
import socket
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import db, facecam, foryou, mobile, perspectives, pipeline, prefetch
from .config import ROOT, load_config, paths

WEB = Path(__file__).parent / "web"

# background "export & next": render + export queued clips one after another
_jobs: "queue.Queue[str]" = queue.Queue()
_rendering: set[str] = set()


def _job_worker() -> None:
    while True:
        cid = _jobs.get()
        _rendering.add(cid)
        try:
            while pipeline.user_is_waiting():  # opening/preparing the next clip goes first
                time.sleep(0.3)
            with pipeline.WORK_LOCK:
                pipeline.render_clip(cid)
            pipeline.export_clip(cid)
            print(f"[export] {cid} -> rendered_clips/")
        except Exception as e:
            traceback.print_exc()
            db.update_clip(cid, error=f"Export fehlgeschlagen: {e}"[:500])
        finally:
            _rendering.discard(cid)
            pipeline.exports_pending -= 1
FONTS = ROOT / "assets" / "fonts"
VIEWS = {  # list filter -> statuses
    "active": ("new", "pending_review", "failed"),
    "exported": ("approved",),
    "ignored": ("ignored",),
    "uploaded": ("uploaded",),
}
_sched_lock = threading.Lock()


def _schedules() -> dict:
    """Scheduled posts of the browser extension ({clip_id: {at, state, error, ...}}), kept here so they
    survive extension reinstalls and show up in the clip list."""
    f = paths().data / "schedules.json"
    return json.loads(f.read_text()) if f.exists() else {}


def _save_schedules(s: dict) -> None:
    (paths().data / "schedules.json").write_text(json.dumps(s, ensure_ascii=False, indent=1))


def _unschedule(clip_id: str) -> None:
    with _sched_lock:
        s = _schedules()
        if s.pop(clip_id, None):
            _save_schedules(s)


def _pins() -> list[str]:
    f = paths().data / "pins.json"
    return json.loads(f.read_text()) if f.exists() else []


def _used() -> dict[str, int]:
    """Clips used per channel (kept, edited, exported or posted) -> Post Selector sort "meist genutzt"."""
    q = ",".join("?" * len(foryou.ACCEPTED))
    with db.conn() as c:
        return {r[0]: r[1] for r in c.execute(
            f"SELECT streamer, COUNT(*) FROM clips WHERE status IN ({q}) GROUP BY streamer", foryou.ACCEPTED)}


RENDER_KEYS = ("width", "height", "cam_height", "subs_y", "font_size", "highlight", "title_secs", "title_size")


def _row(r) -> dict:
    d = dict(r)
    for k in ("cam", "subs"):
        d[k] = json.loads(d[k]) if d.get(k) else None
    return d


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _cors(self):
        # the TikTok helper extension fetches the queue + videos from tiktok.com / its own origin
        origin = self.headers.get("Origin") or ""
        if origin.startswith(("https://www.tiktok.com", "safari-web-extension://", "chrome-extension://")):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type, Range")
            self.send_header("Access-Control-Allow-Private-Network", "true")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send(self, code, body: bytes, ctype="text/html; charset=utf-8", extra=None):
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        if getattr(self, "_set_cookie", False):  # app opened a web page with ?k=: links/videos then work too
            self.send_header("Set-Cookie", f"{mobile.COOKIE}={mobile.token()}; Path=/; Max-Age=31536000; SameSite=Lax")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):  # browser cancelled (seek / switched video)
            self.close_connection = True

    def _guard(self) -> bool:
        """LAN requests (iPhone app) need the pairing token; this Mac needs none."""
        q = parse_qs(urlparse(self.path).query)
        if mobile.authorized(self.client_address[0], self.headers, q):
            self._set_cookie = bool(q.get("k")) and not mobile.is_local(self.client_address[0])
            return True
        self._set_cookie = False
        self._json({"error": "nicht verbunden – QR-Code auf dem Mac neu scannen"}, 401)
        return False

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode(), "application/json")

    def _file(self, path: Path | None, ctype="video/mp4"):
        if not path or not path.exists():
            return self._send(404, b"not found")
        size = path.stat().st_size
        rng = self.headers.get("Range")
        with open(path, "rb") as f:
            if rng and (m := re.match(r"bytes=(\d+)-(\d*)", rng)):  # needed for seeking
                a = int(m.group(1))
                # open-ended ranges ("bytes=N-") are answered in pieces; players ask for the rest
                b = min(int(m.group(2)) if m.group(2) else a + 4 * 1024 * 1024 - 1, size - 1)
                f.seek(a)
                return self._send(206, f.read(b - a + 1), ctype,
                                  {"Content-Range": f"bytes {a}-{b}/{size}", "Accept-Ranges": "bytes"})
            self._send(200, f.read(), ctype, {"Accept-Ranges": "bytes"})

    def do_GET(self):
        if not self._guard():
            return
        u = urlparse(self.path)
        path = u.path
        if path == "/pair":  # QR code for the iPhone app (only shown on this Mac)
            if not mobile.is_local(self.client_address[0]):
                return self._send(403, b"nur auf dem Mac")
            return self._send(200, mobile.pair_page(self.server.server_port))
        if path == "/api/info":  # app: connection check
            return self._json({"ok": True, "app": "cutfortiktok", "host": socket.gethostname()})
        if path == "/":
            return self._send(200, (WEB / "index.html").read_bytes())
        if path in ("/scheduler", "/foryou", "/edit"):
            page = {"/scheduler": "scheduler.html", "/foryou": "foryou.html", "/edit": "editlist.html"}[path]
            return self._send(200, (WEB / page).read_bytes())
        if path == "/api/foryou":  # ranked untouched clips; the next ones get downloaded in background
            hidden = {h for h in parse_qs(u.query).get("hidden", [""])[0].split(",") if h}
            age = parse_qs(u.query).get("age", [""])[0]  # only clips of the last `age` minutes
            ranked = foryou.rank(hidden=hidden, max_age_min=int(age) if age.isdigit() else None)
            prefetch.set_feed([x["id"] for x in ranked[:6]])
            for x in ranked:
                rp = x.pop("raw_path")
                x["ready"] = bool(rp) and Path(rp).exists()
            return self._json({"clips": ranked, "streamers": sorted(pipeline.allowlist()),
                               "next_sync": pipeline.next_sync_at, "prefetch": prefetch.status()})
        if path == "/api/editlist":  # kept (For You) + edited, not yet exported
            with db.conn() as c:
                rows = c.execute(
                    "SELECT id,streamer,title,overlay_title,views,duration,status,error,thumbnail,"
                    "COALESCE(happened_at, created_at) AS created_at,"
                    "subs IS NOT NULL AS ready, COALESCE(json_array_length(members), 1) AS parts FROM clips "
                    "WHERE status IN ('kept','pending_review') AND merged_into IS NULL "
                    "ORDER BY COALESCE(kept_at, updated_at)").fetchall()
            return self._json({"clips": [dict(r) for r in rows], "rendering": sorted(_rendering),
                               "prefetch": prefetch.status()})
        if re.fullmatch(r"/edit/[\w-]+", path):
            return self._send(200, (WEB / "editor.html").read_bytes())
        if m := re.fullmatch(r"/fonts/([\w-]+\.ttf)", path):
            return self._file(FONTS / m.group(1), "font/ttf")
        if path == "/api/queue":  # exported, not yet posted -> TikTok helper extension
            out = []
            for r in db.clips_by_status("approved"):
                f = pipeline.export_path(r["id"])
                if f:
                    out.append({"id": r["id"], "streamer": r["streamer"], "title": r["overlay_title"] or r["title"],
                                "caption": r["caption"] or "", "thumbnail": r["thumbnail"], "file": str(f),
                                "filename": f.name, "video_url": f"http://localhost:{self.server.server_port}/export/{r['id']}"})
            return self._json(out)
        if m := re.fullmatch(r"/export/([\w-]+)", path):
            return self._file(pipeline.export_path(m.group(1)))
        if path == "/api/schedules":  # null = never written (extension then uploads its local copy)
            return self._json(_schedules() if (paths().data / "schedules.json").exists() else None)
        if path == "/api/clips":
            # selector shows only clips still to decide on; exported/posted/ignored are tracked, not shown.
            # Clips swallowed by an overlapping one (merged_into) are hidden, merged groups count their parts.
            statuses = VIEWS["active"]
            q = ",".join("?" * len(statuses))
            min_views = load_config()["clips"].get("min_views", 0)
            with db.conn() as c:
                rows = c.execute(
                    f"SELECT id,streamer,title,views,duration,status,error,thumbnail,"
                    f"COALESCE(happened_at, created_at) AS created_at,"  # moment in the stream, else clip creation
                    f"subs IS NOT NULL AS ready, COALESCE(json_array_length(members), 1) AS parts FROM clips "
                    f"WHERE status IN ({q}) AND merged_into IS NULL AND views >= ? ORDER BY created_at DESC",
                    (*statuses, min_views)).fetchall()
            return self._json({"clips": [dict(r) for r in rows], "streamers": sorted(pipeline.allowlist()),
                               "rendering": sorted(_rendering), "schedules": _schedules(),
                               "next_sync": pipeline.next_sync_at, "pins": _pins(), "used": _used(),
                               "prefetch": prefetch.status()})
        if m := re.fullmatch(r"/api/clip/([\w-]+)/perspectives", path):  # same moment, other channels
            found = perspectives.find(m.group(1))
            pipeline.pin([m.group(1)] + [p["id"] for p in found])  # keep their downloads while editing
            return self._json(found)
        m = re.fullmatch(r"/(api/clip|raw|video)/([\w-]+)", path)
        row = db.get_clip(m.group(2)) if m else None
        if not row:
            return self._send(404, b"not found")
        if m.group(1) == "api/clip":
            with db.conn() as c:  # opened in editor -> newest for prefetch cache eviction
                c.execute("UPDATE clips SET updated_at=CURRENT_TIMESTAMP WHERE id=?", (row["id"],))
            r = load_config()["render"]
            return self._json({**_row(row), "render": {k: r[k] for k in RENDER_KEYS}})
        p = row["raw_path"] if m.group(1) == "raw" else row["out_path"]
        self._file(Path(p) if p else None)

    def do_POST(self):
        if not self._guard():
            return
        path = urlparse(self.path).path
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if path == "/api/debug-dump":  # TikTok page structure from the helper extension (for selector fixes)
            d = paths().data / "debug"
            d.mkdir(exist_ok=True)
            if "html_part" in body:  # page HTML arrives in chunks, appended to the report's .html
                stem = re.sub(r"[^\w-]", "", body["stem"])
                with open(d / f"{stem}.html", "a", encoding="utf-8") as f:
                    f.write(body["html_part"])
                return self._json({"ok": True})
            stem = f"{time.strftime('%Y%m%d-%H%M%S')}_{body.get('stage', 'page')}_{'top' if body.get('top') else 'frame'}"
            (d / f"{stem}.json").write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
            return self._json({"ok": True, "file": stem})
        if path == "/api/pins":  # pinned channels (Post Selector), shared by website and app
            (paths().data / "pins.json").write_text(json.dumps(body.get("pins") or []))
            return self._json({"ok": True})
        if path == "/api/schedules":  # extension writes its whole schedule list
            with _sched_lock:
                _save_schedules(body.get("schedules") or {})
            return self._json({"ok": True})
        if path == "/api/sync":
            try:
                return self._json({"new": pipeline.sync(full=bool(body.get("full")))})
            except Exception as e:
                return self._json({"error": str(e)}, 400)
        if m := re.fullmatch(r"/api/schedule/([\w-]+)", path):  # scheduler page: plan / unplan a post
            row = db.get_clip(m.group(1))
            if not row:
                return self._json({"error": "not found"}, 404)
            with _sched_lock:
                s = _schedules()
                if body.get("at"):
                    s[row["id"]] = {"id": row["id"], "title": row["overlay_title"] or row["title"],
                                    "streamer": row["streamer"], "at": int(body["at"]), "state": "planned"}
                else:
                    s.pop(row["id"], None)
                _save_schedules(s)
            return self._json({"ok": True})
        m = re.fullmatch(r"/api/clip/([\w-]+)(/\w+)?", path)
        row = db.get_clip(m.group(1)) if m else None
        if not row:
            return self._json({"error": "not found"}, 404)
        cid, action = row["id"], (m.group(2) or "/save")[1:]
        try:
            if action == "prepare":
                if row["subs"] and not (row["raw_path"] and Path(row["raw_path"]).exists()):
                    with pipeline.user_work():  # edited before, videos dropped after export
                        pipeline.ensure_media(cid)
                elif not row["subs"]:
                    with pipeline.user_work():
                        if not db.get_clip(cid)["subs"]:  # prefetch may have finished meanwhile
                            pipeline.prepare(cid)
                return self._json({"ok": True})
            if action == "fetch":  # download only (watch another perspective); not queued behind background jobs
                pipeline.fetch_raw(row)
                pipeline.pin([cid])
                return self._json({"ok": True})
            if action == "align":  # editor: offset + facecam layout of a perspective clip
                other = db.get_clip(body["other"])
                main_raw = pipeline.fetch_raw(row)
                oraw = pipeline.fetch_raw(other)
                pipeline.pin([cid, other["id"]])
                off, refined = perspectives.refine(main_raw, oraw, float(body["off"]), float(body["at"]))
                lay = facecam.get_layout(other["streamer"], oraw)
                return self._json({"off": round(off, 3), "refined": refined, "layout": lay})
            if action == "redetect":
                with pipeline.user_work():
                    return self._json(facecam.detect(Path(row["raw_path"])))
            if action in ("save", "export_async"):
                ts, te = float(body["trim_start"]), float(body["trim_end"])
                if te - ts < 1:
                    raise ValueError("Clip muss mindestens 1s lang sein")
                cuts = sorted(({"start": float(c["start"]), "end": float(c["end"])} for c in body.get("cuts", [])),
                              key=lambda c: c["start"])
                for c in cuts:
                    if c["start"] < ts or c["end"] > te or c["end"] - c["start"] < .1:
                        raise ValueError("Jeder ausgeschnittene Bereich muss innerhalb des Ausschnitts liegen und mindestens 0,1s lang sein")
                if any(b["start"] < a["end"] for a, b in zip(cuts, cuts[1:])):
                    raise ValueError("Ausgeschnittene Bereiche dürfen sich nicht überschneiden")
                db.update_clip(
                    cid, cam=json.dumps(body["cam"]), game_x=float(body["game_x"]),
                    trim_start=ts, trim_end=te, caption=body["caption"],
                    overlay_title=body.get("overlay_title", ""),
                    cam_h=max(240, min(1400, int(body.get("cam_h") or load_config()["render"]["cam_height"]))),
                    subs=json.dumps(body["subs"], ensure_ascii=False),
                    switches=json.dumps(body.get("switches") or []),
                    cuts=json.dumps(cuts),
                )
                # remember facecam/split/crop for this streamer's next clips
                facecam.save_layout(row["streamer"], {
                    "cam": body["cam"], "cam_h": int(body.get("cam_h") or 0) or None, "game_x": float(body["game_x"])})
                if row["status"] == "new":
                    db.update_clip(cid, status="pending_review")
                if action == "export_async":  # final render + export in background, editor moves on
                    db.update_clip(cid, error=None)
                    pipeline.exports_pending += 1
                    _jobs.put(cid)
                    return self._json({"ok": True, "queued": True})
                with pipeline.user_work():
                    pipeline.render_clip(cid, preset="fast")
                return self._json({"ok": True})
            if action == "title":  # Edit list: overlay title; the auto caption follows it
                new = body.get("overlay_title", "").strip()
                old = row["overlay_title"] or row["title"] or ""
                cap = row["caption"]
                if cap and old and cap.startswith(old):
                    cap = new + cap[len(old):]
                db.update_clip(cid, overlay_title=new, caption=cap)
                return self._json({"ok": True})
            if action == "status":
                st = body["status"]
                if st == "restore":  # un-ignore
                    st = "pending_review" if row["subs"] else "new"
                if st not in ("ignored", "pending_review", "new", "uploaded", "kept"):
                    raise ValueError("bad status")
                db.update_clip(cid, status=st)
                if st == "kept":  # For You "Behalten": prepare with priority
                    db.update_clip(cid, kept_at=time.strftime("%Y-%m-%d %H:%M:%S"), error=None)
                    prefetch.wake()
                if st in ("uploaded", "ignored"):  # posted/dropped elsewhere -> extension must not post it
                    _unschedule(cid)
                if st == "uploaded":  # posted -> exported file is no longer needed
                    pipeline.delete_export(cid)
                    pipeline.drop_media(cid)
                if st == "ignored":
                    pipeline.release_files(cid)
                return self._json({"ok": True, "status": st})
            if action == "export":
                f = pipeline.export_clip(cid)
                return self._json({"ok": True, "file": str(f.relative_to(ROOT))})
            return self._json({"error": "unknown action"}, 404)
        except (Exception, SystemExit) as e:
            db.update_clip(cid, error=str(e)[:500])
            return self._json({"error": str(e)}, 400)


def serve(port: int, listen: bool = True) -> None:
    if listen:
        pipeline.start_listener()
    prefetch.start()
    threading.Thread(target=lambda: print(f"[cleanup] videos of {pipeline.cleanup_media()} finished clips deleted"),
                     daemon=True).start()
    threading.Thread(target=_job_worker, daemon=True, name="export-jobs").start()
    lan = load_config()["review"].get("lan", True)  # iPhone app reaches the server over WiFi
    print(f"App: http://localhost:{port}  (Ctrl+C to stop)")
    if lan:
        print(f"iPhone: http://localhost:{port}/pair  (QR-Code scannen, Server {mobile.lan_ip()}:{port})")
    ThreadingHTTPServer(("0.0.0.0" if lan else "127.0.0.1", port), Handler).serve_forever()
