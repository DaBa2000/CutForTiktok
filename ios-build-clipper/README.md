# Clipper (iOS)

iPhone app for CutForTiktok: For You, Edit, Scheduler and Post Selector, working on the same data as the
website. All the work (download, transcribing, rendering, the TikTok extension) stays on the Mac; the app only calls
its API over WiFi.

## Connect
1. On the Mac: `uv run cutfortiktok review` (it now also listens in the WiFi, see `review.lan` in config.yaml).
2. In the browser open http://localhost:8080/pair (📱 in the nav) and scan the QR code with the app
   (or with the iPhone camera, which opens `clipper://pair?...`).
3. Requests from the WiFi need the token from the QR code; the browser and extension on the Mac don't.
   To unpair all phones, delete `data/mobile_token` and restart the server.

## Build
Open `Clipper.xcodeproj`, choose your team under Signing (target Clipper), select your iPhone and run.
The project uses folder-synced groups: new files in `Clipper/` are picked up automatically.

## Editor
Touch editor with a live 9:16 preview: drag the seam to change the facecam height. In the "Facecam & Spiel" view,
drag the box to move it and its corner to resize it. Also: game crop, trim (drag the red handles), title card,
caption and subtitles. Switching to other streams' perspectives is only in the web editor (⋯ → Web-Editor), which
opens inside the app.
