# Clipper (iOS)

iPhone app for CutForTiktok: For You, Edit, Scheduler, Discovery and Einstellungen, working on the same data as the
website. All the work (download, transcribing, rendering, the TikTok extension) stays on the Mac; the app only calls
its API over WiFi.

## Connect
1. On the Mac: `uv run cutfortiktok review` (it also listens in the WiFi, see `review.lan` in config.yaml).
2. In the browser open http://localhost:8080/pair (📱 in the nav) and scan the QR code with the app
   (or with the iPhone camera, which opens `clipper://pair?...`).
3. Requests from the WiFi need the token from the QR code; the browser and extension on the Mac don't.
   To unpair all phones, delete `data/mobile_token` and restart the server.

## Build
Open `Clipper.xcodeproj`, choose your team under Signing (target Clipper), select your iPhone and run.
The project uses folder-synced groups: new files in `Clipper/` are picked up automatically.

## Configurations
Einstellungen: create / edit configurations (shown streamers, 📌 pinned channels), the active one applies everywhere
(also on the website). Switch it in the toolbar of For You / Discovery.

## For You / Discovery
For You: "Für dich" ranking, newest or top, time window 5 Min … 1 Woche; swipe ← / → to decide, ↑ / ↓ to browse.
Discovery: per streamer the newest / top clips; tap a streamer for its profile and "Im For-You-Stil ansehen".
The Mac downloads what you are about to see next (and the clips of pinned channels in Discovery).

## Editor
Same as the website's editor, autosaved: live 9:16 preview (drag the seam = facecam height, drag inside an area =
move what it shows, two fingers = zoom), "Quelle & Rahmen" (green facecam frame, blue game frame: drag = move,
corner = bigger / smaller, pinch = zoom), timeline with trim handles, cut-out ranges, perspective switches and
keyframes, tabs Bild / Schnitt / Perspektiven / Keyframes / Text / Untertitel. Joined clips ("Clips verbinden") have a
layout per part: ⋯ → "Im Web-Editor öffnen".
