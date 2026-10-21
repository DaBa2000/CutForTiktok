# Clipper (iOS)

iPhone app for CutForTiktok: For You, Edit, Scheduler and Post Selector, working on the same data as the
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

## Editor
Same as the website's editor, autosaved: live 9:16 preview (drag the seam = facecam height), "Facecam & Spiel"
(drag the box, corner = resize), game crop, trim (red handles), title card, caption, subtitles.
Perspective switches and cut-out ranges: "Web-Editor" (top right) opens the website's editor in the app.
