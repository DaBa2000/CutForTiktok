# Selenium Poster (manueller Fallback)

Postet exportierte Clips aus der Scheduler-Liste per Selenium auf TikTok: Video hochladen, Beschreibung einfügen,
„Posten“ klicken, Dialoge bestätigen bzw. überspringen. Läuft **nur von Hand** und ist nicht Teil der Pipeline
oder des automatischen Schedulers.

## Voraussetzungen
- CutForTiktok-Server läuft (`http://localhost:8080`, sonst `CUTFORTIKTOK_SERVER=http://host:port`)
- Google Chrome ist installiert (den passenden chromedriver lädt Selenium selbst)

## Benutzung
```sh
cd apps/selenium-poster
uv run poster              # Liste anzeigen, Nummern auswählen (z. B. "1 3")
uv run poster <clip-id>    # direkt bestimmte Clips
uv run poster --dry-run    # alles ausfüllen, aber NICHT posten (zum Testen)
uv run poster --no-mark    # nach dem Posten nicht als gepostet markieren
```

Beim ersten Start öffnet sich ein eigenes Chrome-Profil (`.profile/`, nicht im Git). Dort einmal bei TikTok einloggen,
der Login bleibt danach erhalten.

Nach einem von TikTok bestätigten Post wird der Clip als gepostet markiert und verschwindet aus dem Scheduler. Kommt keine
Bestätigung, wird nichts markiert, dann im Browser prüfen.

Die Selektoren entsprechen denen der Browser-Extension (`apps/browser-extension/content.js`). Wenn TikTok die Seite
ändert, müssen beide angepasst werden.
