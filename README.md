# CutForTiktok

Twitch clips (Craft Attack streamers who allow clipping) -> vertical 1080x1920 shorts
(facecam on top, game below, German word-highlight subtitles) -> manual review -> TikTok.

## Repo
```
src/cutfortiktok/      Python: server + pipeline (runs on the Mac)
  server.py            HTTP routes for website, iPhone app, browser extension
  clips.py             clip lifecycle: status changes, lists, autosave, export queue
  pipeline.py          Twitch sync, download, prepare (facecam + transcript), render, export
  store.py             scheduled posts + pinned channels (JSON in data/)
  mobile.py            iPhone pairing (QR code) + token check
  web/                 website pages (common.css/js shared by the list pages)
apps/ios/              iPhone app "Clipper" (SwiftUI), same pages as the website
apps/browser-extension/  TikTok helper: posts exported clips (now or at the planned time)
accounts.txt           channels; config.yaml settings; layouts.json facecam per streamer
```

## Setup
1. `uv sync`
2. Fill `.env` (template: `.env.example`) with the Twitch client id/secret.
3. Channels: `accounts.txt` (one twitch URL or login per line; only channels that allow clipping).

## Usage
```
uv run cutfortiktok review        # web app on http://localhost:8080 + live clip listener
```
- The listener lists all clips since `clips.since` (config.yaml) once, then polls every
  `poll_minutes` for new ones. Listing is metadata only.
- Background work (cheap but fast): For You downloads only its next clips (overlapping clips are merged
  there), no transcript. Kept clips and the top clips of 📌 pinned channels get fully prepared (download,
  facecam, transcript), so the editor opens instantly. Nothing else is processed.
- **For You** (`/foryou`): one clip at a time, ranked; Behalten → Edit, Ignorieren. Time filter 15 Min … 7 Tage.
- **Edit** (`/edit`): kept clips, title per clip, open in the editor.
- **Post Selector** (`/`): newest or top n per channel; click a channel for all its clips; channel order
  (newest / most used / top clip) and 📌 pins.
- **Scheduler** (`/scheduler`): exported clips → day + time (German time) or distribute automatically,
  reorder; the browser extension posts them at that time. Rate clips with a tier badge
  (🔥 insane / sehr gut / gut / Filler): "Verteilen" plans the best first. "Automatisch posten" switches
  the scheduler off (plans stay, nothing is posted) and on again. Gap filler: if nothing was posted for
  n minutes (default 60, set in the Scheduler, 0 = off), the extension posts the oldest exported "gut" clip
  (else "Filler"); insane/sehr gut stay for planned slots. Not within 15 min before a planned post.
- Streamer filters (For You, Post Selector) and pins are stored on the Mac: same on website and iPhone.
- **iPhone**: 📱 in the nav (`/pair`) shows a QR code for the Clipper app (same WiFi). See `apps/ios/README.md`.

One clip, one state: what you do on any page (or in the app) applies everywhere. Ignored clips and
exported clips disappear from For You, Edit, Post Selector and the perspective lists; exported clips show up
in the Scheduler, posted ones disappear there too.
- Overlapping clips of the same stream are shown once: a clip containing the others replaces them,
  partially overlapping ones become one merged clip ("🔗 n Clips"), stitched from the member clips and
  aligned by audio. Twitch's `vod_offset` is where a clip *ends* in the VOD.

Other commands: `sync [--full]`, `status`, `discover`, `add-local <video>`.

## Editor
Everything is saved automatically, a moment after each change; facecam box, facecam height and game crop
also become the default for that streamer (`layouts.json`).
- Drag/resize the green facecam box on the source video (or untick "Facecam vorhanden").
- Slider moves the game crop (blue dashed lines); drag the seam in the preview to resize the facecam area.
- Start/Ende trim the clip, cut out ranges, switch to other streams' perspectives of the same moment.
- Subtitles: edit start/end/text per line, delete or add lines.
- Titel-Einblendung: white card between facecam and game for `title_secs` (default: clip title).
- **Exportieren & weiter**: final render in the background → `rendered_clips/` → Scheduler; the next clip opens.
  **Ignorieren** drops the clip everywhere.
- Subtitle look (font, size, highlight color, position) is in `config.yaml` -> `render`.
