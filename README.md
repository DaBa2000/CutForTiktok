# CutForTiktok

Twitch clips (Craft Attack streamers who allow clipping) -> vertical 1080x1920 shorts
(facecam on top, game below, German word-highlight subtitles) -> manual review -> TikTok.

## Repo
```
src/cutfortiktok/      Python: server + pipeline (runs on the Mac)
  server.py            HTTP routes for website, iPhone app, browser extension
  clips.py             clip lifecycle: status changes, lists, autosave, export queue
  pipeline.py          Twitch sync, download, prepare (facecam + transcript), render, export, weekly cleanup
  foryou.py            For You ranking
  prefetch.py          background downloads, following what is being looked at
  layout.py            facecam / game frames + keyframes (shared geometry of render, editor, app)
  render.py            ffmpeg: frames -> 1080x1920 (animated keyframes via per-frame expressions)
  store.py             configurations, scheduled posts, scheduler settings (JSON in data/)
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
- **Configurations** (⚙️ in the nav, `/settings`; app: Einstellungen): name, which streamers are shown (all or a
  selection) and 📌 pinned channels. Several can be saved; the active one (switch it in the nav) applies everywhere:
  For You, Discovery, streamer profiles, background downloads – on the website and in the app.
- **For You** (`/foryou`): one clip at a time; Behalten → Edit, Ignorieren, ↑/↓ browse. Order "Für dich", "Neueste"
  or "Top", time window 5 Min … 1 Woche. Ranking ("Für dich", foryou.py): views (log scale) and freshness
  (halves every 12 h), multiplied by the number of clips merged into one (several people clipped the same moment:
  2 clips x1.25, 4 x1.5, 8 x1.75 …); a mild variety re-rank keeps one channel from filling the feed.
- **Discovery** (`/`): per streamer the newest or top n clips of a time window, pinned channels first. Click a
  streamer for its **profile**: all its clips (newest / top, 5 Min … 1 Woche) and "▶ Im For-You-Stil ansehen".
- **Edit** (`/edit`): kept clips, title per clip, open in the editor.
- **Scheduler** (`/scheduler`): exported clips → day + time (German time) or distribute automatically,
  reorder; the browser extension posts them at that time. Rate clips with a tier badge
  (🔥 insane / sehr gut / gut / Filler): "Verteilen" plans the best first. "Automatisch posten" switches
  the scheduler off (plans stay, nothing is posted) and on again. Gap filler: if nothing was posted for
  n minutes (default 60, set in the Scheduler, 0 = off), the extension posts the oldest exported "gut" clip
  (else "Filler"); insane/sehr gut stay for planned slots. Not within 15 min before a planned post.
- **Background downloads** follow what you look at (prefetch.py): For You → its next clips; a streamer profile →
  its next clips in the chosen order; Discovery → the shown clips of pinned channels. A perspective you tap while
  watching or editing is downloaded right away and kept. Kept clips get fully prepared (facecam, transcript).
- **Cleanup**: clips older than `clips.max_age_days` (7) leave all lists and their downloads are deleted (hourly);
  clips in Edit and exported ones keep theirs.
- **iPhone**: 📱 in the nav (`/pair`) shows a QR code for the Clipper app (same WiFi). See `apps/ios/README.md`.

One clip, one state: what you do on any page (or in the app) applies everywhere. Ignored clips and
exported clips disappear from For You, Edit, Discovery and the perspective lists; exported clips show up
in the Scheduler, posted ones disappear there too.
- Overlapping clips of the same stream are shown once: a clip containing the others replaces them,
  partially overlapping ones become one merged clip ("🔗 n Clips"), stitched from the member clips and
  aligned by audio. Twitch's `vod_offset` is where a clip *ends* in the VOD.

Other commands: `sync [--full]`, `status`, `discover`, `add-local <video>`.

## Editor
Everything is saved automatically, a moment after each change; facecam frame, facecam height and game frame also
become the default for that streamer (`layouts.json`).
- **Frames**: the source view shows a green facecam frame and a blue game frame. Move them, make them bigger/smaller
  at any corner or edge (the aspect follows the output area), mouse wheel = zoom. What is inside a frame is exactly
  what the video shows; a frame reaching beyond the source shows black there (e.g. the whole game with bars).
  Auto detection ("Facecam erkennen") is unchanged. In the 9:16 preview: drag the seam = facecam height, drag inside
  an area = move its frame, wheel / two fingers = zoom.
- **Timeline**: trim handles `[ ]`, cut-out ranges (mark with I / O, ✂ or X; drag their edges; select + Entf),
  perspective switches, keyframes, playhead. Space = play, ←/→ = 0.1 s (Shift: 1 s).
- **Perspectives**: other streams of the same moment. Tap = preview (downloaded and kept), "⇄ ab hier" switches
  from the current time. Inside a switch you edit that stream's own facecam + game frames.
- **Keyframes** (K): from a keyframe on its frames apply, as a jump or a smooth transition (0.3 … 3 s), e.g. when
  the facecam moves on stream or to follow the action. Between two keyframes you edit the earlier one.
- Subtitles: edit start/end/text per line, delete or add lines.
- Titel-Einblendung: white card between facecam and game for `title_secs` (default: clip title).
- **Exportieren & weiter**: final render in the background → `rendered_clips/` → Scheduler; the next clip opens.
  **Ignorieren** drops the clip everywhere.
- Subtitle look (font, size, highlight color, position) is in `config.yaml` -> `render`.
