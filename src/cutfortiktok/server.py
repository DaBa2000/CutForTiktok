"""HTTP server for the website (web/), the iPhone app (apps/ios) and the TikTok helper extension
(apps/browser-extension). Routing only: clip logic is in clips.py, pairing/auth in mobile.py."""
import json
import re
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import clips, db, facecam, mobile, perspectives, pipeline, prefetch, store
from .config import ROOT, load_config

WEB = Path(__file__).parent / "web"
FONTS = ROOT / "assets" / "fonts"
PAGES = {"/": "index.html", "/foryou": "foryou.html", "/edit": "editlist.html", "/scheduler": "scheduler.html"}
STATIC = {"common.css": "text/css; charset=utf-8", "common.js": "text/javascript; charset=utf-8"}
RENDER_KEYS = ("width", "height", "cam_height", "subs_y", "font_size", "highlight", "title_secs", "title_size")


def _clip_json(row) -> dict:
    d = dict(row)
    for k in ("cam", "subs"):
        d[k] = json.loads(d[k]) if d.get(k) else None
    r = load_config()["render"]
    return {**d, "render": {k: r[k] for k in RENDER_KEYS}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    # ---------- plumbing ----------

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
        if self._set_cookie:  # app opened a web page with ?k=: its own requests are authorized too
            self.send_header("Set-Cookie", f"{mobile.COOKIE}={mobile.token()}; Path=/; Max-Age=31536000; SameSite=Lax")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):  # browser cancelled (seek / switched video)
            self.close_connection = True

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode(), "application/json")

    def _file(self, path: Path | None, ctype="video/mp4"):
        if not path or not path.exists():
            return self._send(404, b"not found")
        size = path.stat().st_size
        with open(path, "rb") as f:
            if (rng := self.headers.get("Range")) and (m := re.match(r"bytes=(\d+)-(\d*)", rng)):  # seeking
                a = int(m.group(1))
                # open-ended ranges ("bytes=N-") are answered in pieces; players ask for the rest
                b = min(int(m.group(2)) if m.group(2) else a + 4 * 1024 * 1024 - 1, size - 1)
                f.seek(a)
                return self._send(206, f.read(b - a + 1), ctype,
                                  {"Content-Range": f"bytes {a}-{b}/{size}", "Accept-Ranges": "bytes"})
            self._send(200, f.read(), ctype, {"Accept-Ranges": "bytes"})

    def _guard(self) -> bool:
        """LAN requests (iPhone app) need the pairing token; this Mac needs none."""
        q = parse_qs(urlparse(self.path).query)
        local = mobile.is_local(self.client_address[0])
        self._set_cookie = False
        if mobile.authorized(self.client_address[0], self.headers, q):
            self._set_cookie = bool(q.get("k")) and not local
            return True
        self._json({"error": "nicht verbunden – QR-Code auf dem Mac neu scannen"}, 401)
        return False

    # ---------- GET ----------

    def do_GET(self):
        if not self._guard():
            return
        u = urlparse(self.path)
        path, q = u.path, parse_qs(u.query)
        if path in PAGES:
            return self._send(200, (WEB / PAGES[path]).read_bytes())
        if re.fullmatch(r"/edit/[\w-]+", path):
            return self._send(200, (WEB / "editor.html").read_bytes())
        if (m := re.fullmatch(r"/static/([\w.]+)", path)) and m.group(1) in STATIC:
            return self._send(200, (WEB / m.group(1)).read_bytes(), STATIC[m.group(1)])
        if m := re.fullmatch(r"/fonts/([\w-]+\.ttf)", path):
            return self._file(FONTS / m.group(1), "font/ttf")
        if path == "/pair":  # QR code for the iPhone app (only shown on this Mac)
            if not mobile.is_local(self.client_address[0]):
                return self._send(403, b"nur auf dem Mac")
            return self._send(200, mobile.pair_page(self.server.server_port))

        if path == "/api/info":  # app: connection check
            return self._json({"ok": True, "app": "cutfortiktok", "host": socket.gethostname()})
        if path == "/api/foryou":
            age = q.get("age", [""])[0]  # only clips of the last `age` minutes
            return self._json({"clips": clips.foryou_list(int(age) if age.isdigit() else None),
                               "streamers": sorted(pipeline.allowlist()), "hidden": store.hidden("foryou"),
                               "next_sync": pipeline.next_sync_at})
        if path == "/api/editlist":
            return self._json({"clips": clips.edit_list(), "rendering": sorted(clips.exporting),
                               "prefetch": prefetch.status()})
        if path == "/api/clips":  # Post Selector
            return self._json({"clips": clips.selector_list(), "streamers": sorted(pipeline.allowlist()),
                               "rendering": sorted(clips.exporting), "next_sync": pipeline.next_sync_at,
                               "pins": store.pins(), "hidden": store.hidden("selector"),
                               "used": clips.used_per_channel(), "prefetch": prefetch.status()})
        if path == "/api/queue":  # Scheduler + extension
            port = self.server.server_port
            return self._json([{**c, "video_url": f"http://localhost:{port}/export/{c['id']}"} for c in clips.export_queue()])
        if path == "/api/settings":  # scheduler on/off (extension checks it before posting)
            return self._json(store.settings())
        if path == "/api/schedules":  # null = never written (extension then uploads its local copy)
            return self._json(store.schedules() if store.schedules_written() else None)
        if m := re.fullmatch(r"/export/([\w-]+)", path):
            return self._file(pipeline.export_path(m.group(1)))

        m = re.fullmatch(r"/(api/clip|raw)/([\w-]+)(/perspectives)?", path)
        row = db.get_clip(m.group(2)) if m else None
        if not row:
            return self._send(404, b"not found")
        if m.group(3):  # same moment, other channels
            return self._json(clips.perspectives_of(row["id"]))
        if m.group(1) == "raw":
            return self._file(Path(row["raw_path"]) if row["raw_path"] else None)
        with db.conn() as c:  # opened in editor -> newest for prefetch cache eviction
            c.execute("UPDATE clips SET updated_at=CURRENT_TIMESTAMP WHERE id=?", (row["id"],))
        return self._json(_clip_json(row))

    # ---------- POST ----------

    def do_POST(self):
        if not self._guard():
            return
        path = urlparse(self.path).path
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        try:
            if path == "/api/sync":
                return self._json({"new": pipeline.sync(full=bool(body.get("full")))})
            if path == "/api/pins":  # pinned channels get prepared in background
                store.save_pins(body.get("pins") or [])
                prefetch.wake()
                return self._json({"ok": True})
            if path == "/api/filters":  # streamer filter of a page, same on website and app
                store.save_hidden(body.get("page", ""), body.get("hidden") or [])
                return self._json({"ok": True})
            if path == "/api/filters/exclude":  # For You: hide a streamer in For You + Post Selector
                store.exclude_channel(str(body["streamer"]))
                return self._json({"ok": True})
            if path == "/api/settings":
                return self._json(store.save_settings(body))
            if path == "/api/fill-gap":  # extension tick: post a good/filler clip after too long without a post
                return self._json({"planned": clips.fill_gap()})
            if path == "/api/join":  # Edit list: render these clips one after another as one video
                return self._json({"id": clips.join([str(i) for i in body.get("ids") or []])})
            if path == "/api/unexport":  # Scheduler: back to Edit; join=True attaches them to the earliest one
                ids = [str(i) for i in body.get("ids") or []]
                for i in ids:
                    clips.unexport(i)
                if body.get("join") and len(ids) > 1:  # stream order, opened in the editor afterwards
                    ids.sort(key=lambda i: clips._when(db.get_clip(i)))
                    return self._json({"id": clips.join(ids)})
                return self._json({"ok": True})
            if path == "/api/schedules":  # extension writes its whole schedule list
                store.save_schedules(body.get("schedules") or {})
                return self._json({"ok": True})
            m = re.fullmatch(r"/api/(clip|schedule)/([\w-]+)(?:/(\w+))?", path)
            row = db.get_clip(m.group(2)) if m else None
            if not row:
                return self._json({"error": "not found"}, 404)
            if m.group(1) == "schedule":  # plan (at = epoch ms) or unplan (at = null)
                store.plan(row, body.get("at"))
                return self._json({"ok": True})
            return self._clip_action(row, m.group(3) or "save", body)
        except Exception as e:
            return self._json({"error": str(e)}, 400)

    def _clip_action(self, row, action: str, body: dict):
        cid = row["id"]
        try:
            if action == "prepare":  # editor opened
                clips.open_in_editor(cid)
            elif action == "save":  # editor autosave
                clips.save_edit(cid, body)
            elif action == "export":  # "Exportieren & weiter"
                clips.export(cid, body)
            elif action == "status":
                return self._json({"ok": True, "status": clips.set_status(cid, body["status"])})
            elif action == "tier":  # Scheduler rating
                clips.set_tier(cid, body.get("tier"))
            elif action == "title":
                clips.set_title(cid, body.get("overlay_title", ""))
            elif action == "redetect":
                with pipeline.user_work():
                    return self._json(facecam.detect(Path(row["raw_path"])))
            elif action == "fetch":  # download only (watch another perspective), not queued behind background jobs
                pipeline.fetch_raw(row)
                pipeline.pin([cid])
            elif action == "align":  # editor: sync offset + facecam layout of a perspective clip
                other = db.get_clip(body["other"])
                main_raw, oraw = pipeline.fetch_raw(row), pipeline.fetch_raw(other)
                pipeline.pin([cid, other["id"]])
                off, refined = perspectives.refine(main_raw, oraw, float(body["off"]), float(body["at"]))
                return self._json({"off": round(off, 3), "refined": refined,
                                   "layout": facecam.get_layout(other["streamer"], oraw)})
            else:
                return self._json({"error": "unknown action"}, 404)
            return self._json({"ok": True})
        except (Exception, SystemExit) as e:
            if action == "prepare":  # shown in the lists (download/transcription failed)
                db.update_clip(cid, error=str(e)[:500])
            return self._json({"error": str(e)}, 400)


def serve(port: int, listen: bool = True) -> None:
    if listen:
        pipeline.start_listener()
    prefetch.start()
    clips.start_export_worker()
    threading.Thread(target=lambda: print(f"[cleanup] videos of {pipeline.cleanup_media()} finished clips deleted"),
                     daemon=True).start()
    lan = load_config()["review"].get("lan", True)  # iPhone app reaches the server over WiFi
    print(f"App: http://localhost:{port}  (Ctrl+C to stop)")
    if lan:
        print(f"iPhone: http://localhost:{port}/pair  (QR-Code scannen, Server {mobile.lan_ip()}:{port})")
    ThreadingHTTPServer(("0.0.0.0" if lan else "127.0.0.1", port), Handler).serve_forever()
