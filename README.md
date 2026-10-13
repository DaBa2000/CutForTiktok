# CutForTiktok

Twitch clips (Craft Attack streamers who allow clipping) -> vertical 1080x1920 shorts
(facecam on top, game below, German word-highlight subtitles) -> manual review -> TikTok.

## Setup
1. `uv sync`
2. Fill `.env` (template: `.env.example`): Twitch client id/secret (TikTok keys only needed for the optional API upload).
3. Channels: `accounts.txt` (one twitch URL or login per line; only channels that allow clipping).

## Usage
```
uv run cutfortiktok review        # web app on http://localhost:8080 + live clip listener
```
- The listener lists all clips since `clips.since` (config.yaml) once, then polls every
  `poll_minutes` for new ones. Listing is metadata only; nothing is downloaded until you click Bearbeiten
  (or the background prefetch prepares the clips at the top of the list).
- **Post Selector** (`/`): pick streamers, then "Neueste" (n newest per channel) or "Top" (n most viewed
  per channel among clips of the last t minutes). Only clips still to decide on are shown; exported,
  posted and ignored clips are tracked in the database but hidden, and their videos are deleted
  (the exported file in `rendered_clips/` stays until the clip is posted).
- Overlapping clips of the same stream are shown once: a clip containing the others replaces them,
  partially overlapping ones become one merged clip ("🔗 n Clips"), stitched from the member clips and
  aligned by audio. Twitch's `vod_offset` is where a clip *ends* in the VOD.
- **Scheduler** (`/scheduler`): exported clips → pick day + time (German time) or distribute them
  automatically; the TikTok helper extension posts them at that time.

Other commands: `sync [--full]`, `upload` (all approved), `status`, `add-local <video>`, `facecam-preview`.
Facecam rects are cached per streamer in `layouts.json` (normalized x,y,w,h; `null` = no cam).

## Editor (`review`)
- Drag/resize the green facecam box on the source video (or untick "Facecam vorhanden");
  "als Standard speichern" stores it in `layouts.json` for that streamer's future clips.
- Slider moves the game crop (blue dashed lines).
- Start/Ende trim the clip; live canvas preview shows the vertical result with subtitles.
- Subtitles: edit start/end/text per line, delete or add lines.
- Titel-Einblendung: shown as a white card between facecam and game for `title_secs` (default: clip title).
- "Speichern & Rendern" renders the final mp4 (shown below).
- "Exportieren" copies it to `rendered_clips/` for manual posting.
- After posting it yourself: "Als gepostet markieren" hides it (tab Gepostet). "Ignorieren" hides it too.
- Subtitle look (font, size, highlight color, position) is in `config.yaml` -> `render`.
