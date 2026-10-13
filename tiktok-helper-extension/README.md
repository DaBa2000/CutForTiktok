# TikTok Clip Poster (Browser-Extension)

Liste der exportierten Clips (aus der CutForTiktok-App) → Klick → Video + Beschreibung werden auf
der TikTok-Upload-Seite eingefügt → du klickst „Posten“ → Clip wird automatisch als gepostet markiert.

Voraussetzung: `uv run cutfortiktok review` läuft (http://localhost:8080) und du bist bei tiktok.com eingeloggt.

## Safari installieren
1. Xcode aus dem App Store installieren, dann `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
2. `./build-safari.sh` (baut die App und kopiert sie nach /Applications)
3. Safari → Einstellungen → Erweitert → „Funktionen für Webentwickler anzeigen“ an
4. Menü Entwickler → „Nicht signierte Erweiterungen erlauben“ (muss nach jedem Safari-Neustart erneut
   aktiviert werden, solange die App nicht mit einer Apple-ID in Xcode signiert ist)
5. Safari → Einstellungen → Erweiterungen → „TikTok Clip Poster“ aktivieren, Zugriff auf tiktok.com + localhost erlauben

Tipp: In Xcode einmal mit deiner (kostenlosen) Apple-ID signieren, dann entfällt Schritt 4.

## Chrome / Edge (ohne Build, zum Testen)
chrome://extensions → Entwicklermodus → „Entpackte Erweiterung laden“ → diesen Ordner wählen.

## Ablauf
1. Im Editor „Exportieren“ → Clip landet in `rendered_clips/` und in der Extension-Liste.
2. Extension-Symbol → „Einfügen“ beim gewünschten Clip. Öffnet bei Bedarf die Upload-Seite,
   lädt das Video hoch und setzt die Beschreibung (zusätzlich in der Zwischenablage).
3. Prüfen, „Posten“ klicken → nach TikToks Bestätigung wird der Clip als gepostet markiert.
   Wird keine Bestätigung erkannt, erscheint unten rechts ein Button „Als gepostet markieren“.

## Geplante Posts
„⏰ planen“ beim Clip → Datum + Uhrzeit (**deutsche Zeit**) → „Planen“. Zur geplanten Zeit öffnet die
Extension selbst einen Tab mit der Upload-Seite, fügt Video + Beschreibung ein, wartet bis „Posten“
klickbar ist, klickt ihn (und bestätigt evtl. Nachfrage-Dialoge) und markiert den Clip als gepostet.
- Dafür müssen zur geplanten Zeit laufen: Mac wach (nicht im Ruhezustand), Browser offen, App
  (`uv run cutfortiktok review`), TikTok eingeloggt. Bildschirm darf aus sein, Ruhezustand nicht
  (z. B. `caffeinate -i` im Terminal oder Systemeinstellungen → Energie).
- Nicht gestartet innerhalb 1 h nach der geplanten Zeit → „Verpasst“, wird nicht nachgeholt.
- Mehrere Posts zur selben Zeit laufen nacheinander. Status/Fehler stehen im Popup beim Clip.

## Hinweis
TikTok ändert seine Seite gelegentlich. Wenn Upload-Feld/Beschreibung/Posten-Button nicht mehr
gefunden werden, die Selektoren oben in `content.js` anpassen (`fileInput`, `captionEditor`, `isPostButton`).
