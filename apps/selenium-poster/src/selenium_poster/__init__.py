"""Manual fallback poster: pick clips from the Scheduler queue (exported, not yet posted), Selenium opens
TikTok Studio in Chrome, uploads the video, pastes the caption, clicks "Post" and confirms/skips dialogs.
Not part of the pipeline: runs only when started by hand. Selectors mirror apps/browser-extension/content.js."""
import argparse
import os
import sys
import time
from pathlib import Path

import requests
from selenium import webdriver
from selenium.common.exceptions import StaleElementReferenceException, WebDriverException
from selenium.webdriver.common.by import By

UPLOAD_URL = "https://www.tiktok.com/tiktokstudio/upload"
PROFILE = Path(__file__).resolve().parents[2] / ".profile"  # own Chrome profile: TikTok login stays

CAPTION = ('[data-e2e="caption_container"] .public-DraftEditor-content[contenteditable="true"], '
           '.public-DraftEditor-content[contenteditable="true"]')
POST_BUTTON = '[data-e2e="post_video_button"]'
# dialogs after "Post" (e.g. "Continue to post? We're still checking your video…") -> confirm, never cancel
CONFIRM = ["post now", "jetzt posten", "post", "posten", "veröffentlichen", "publish", "post anyway", "trotzdem posten",
           "continue", "weiter", "fortfahren", "confirm", "bestätigen"]
# hint/feature popups that block the page (before or after posting) -> dismiss
# (never "cancel"/"abbrechen": in the post confirmation that aborts the post)
SKIP = ["not now", "nicht jetzt", "skip", "überspringen", "got it", "verstanden", "ok", "close", "schließen",
        "später", "maybe later", "dismiss"]
SUCCESS = ("your video has been posted", "your video was posted", "video veröffentlicht", "wurde veröffentlicht",
           "manage your posts", "beiträge verwalten")

# ---------- JS run in the page (Draft.js editor needs a real paste event, see content.js) ----------
JS_SET_CAPTION = """
const [sel, text] = arguments;
const ed = document.querySelector(sel);
if (!ed) return false;
ed.focus();
const r = document.createRange(); r.selectNodeContents(ed);
const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
document.dispatchEvent(new Event('selectionchange'));
document.execCommand('delete', false);
const dt = new DataTransfer(); dt.setData('text/plain', text);
ed.dispatchEvent(new ClipboardEvent('paste', {clipboardData: dt, bubbles: true, cancelable: true}));
return true;
"""
JS_INSERT_CAPTION = """
const [sel, text] = arguments;
const ed = document.querySelector(sel);
ed.focus();
const r = document.createRange(); r.selectNodeContents(ed);
const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
document.execCommand('delete', false);
document.execCommand('insertText', false, text);
"""
JS_UPLOAD_DONE = """
const box = document.querySelector('[data-e2e="upload_status_container"]');
return !!box && (!!box.querySelector('.info-progress.success')
  || /uploaded|hochgeladen/i.test(box.innerText) && !/\\d+\\s*%/.test(box.innerText));
"""
JS_DIALOG_BUTTON = """
const [words] = arguments;
for (const box of document.querySelectorAll('[role="dialog"], .TUXModal, [class*="Modal"], [class*="modal"]')) {
  for (const b of box.querySelectorAll('button, [role="button"]')) {
    const r = b.getBoundingClientRect();
    const t = (b.innerText || '').replace(/\\s+/g, ' ').trim().toLowerCase();
    if (r.width && r.height && !b.closest('[data-e2e="post_video_button"]') && words.includes(t)) return b;
  }
}
return null;
"""


def squash(s: str | None) -> str:
    return "".join(ch for ch in (s or "") if not ch.isspace() and ch not in "​﻿")


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def wait(fn, timeout: float, every: float = 0.5):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if v := fn():
                return v
        except (StaleElementReferenceException, WebDriverException):
            pass
        time.sleep(every)
    return None


# ---------- server ----------

def server() -> str:
    return os.environ.get("CUTFORTIKTOK_SERVER", "http://localhost:8080").rstrip("/")


def queue() -> list[dict]:
    """Scheduler queue: exported clips that are not posted yet (with local file path + caption)."""
    try:
        return requests.get(server() + "/api/queue", timeout=10).json()
    except requests.RequestException as e:
        sys.exit(f"CutForTiktok-Server nicht erreichbar ({server()}): {e}")


def mark_posted(clip_id: str) -> None:
    r = requests.post(f"{server()}/api/clip/{clip_id}/status", json={"status": "uploaded"}, timeout=10)
    r.raise_for_status()


# ---------- browser ----------

def browser() -> webdriver.Chrome:
    PROFILE.mkdir(exist_ok=True)
    o = webdriver.ChromeOptions()
    o.add_argument(f"--user-data-dir={PROFILE}")
    o.add_argument("--window-size=1400,1000")
    o.add_argument("--disable-blink-features=AutomationControlled")
    o.add_experimental_option("excludeSwitches", ["enable-automation"])
    return webdriver.Chrome(options=o)  # Selenium Manager fetches the matching chromedriver


def find(d, css: str):
    els = [e for e in d.find_elements(By.CSS_SELECTOR, css) if e.is_displayed() or css.startswith("input")]
    return els[0] if els else None


def click_dialogs(d, words: list[str]) -> str | None:
    b = d.execute_script(JS_DIALOG_BUTTON, words)
    if not b:
        return None
    text = b.text.strip()
    d.execute_script("arguments[0].click()", b)
    return text


def open_upload(d) -> None:
    d.get(UPLOAD_URL)
    if not wait(lambda: d.find_elements(By.CSS_SELECTOR, 'input[type=file]'), 20):
        log("Nicht eingeloggt? Bitte im Chrome-Fenster bei TikTok einloggen – ich warte (max. 10 Min)…")
        if not wait(lambda: "/upload" in d.current_url and d.find_elements(By.CSS_SELECTOR, 'input[type=file]'), 600, 2):
            raise RuntimeError("Upload-Seite nicht erreicht (Login?)")


def set_caption(d, text: str) -> None:
    for js in (JS_SET_CAPTION, JS_SET_CAPTION, JS_INSERT_CAPTION):
        d.execute_script(js, CAPTION, text)
        if wait(lambda: squash(find(d, CAPTION).text) == squash(text), 2, 0.2):
            time.sleep(1.5)  # TikTok may still overwrite it with the file name
            if squash(find(d, CAPTION).text) == squash(text):
                return
    raise RuntimeError("Beschreibung konnte nicht gesetzt werden")


def post_ready(d):
    b = find(d, POST_BUTTON)
    if not b:
        return None
    busy = [b.get_attribute(a) for a in ("disabled", "aria-disabled", "data-disabled", "data-loading")]
    return None if "true" in busy else b


def post(d, clip: dict, dry: bool) -> bool:
    """Upload + caption + Post + dialogs. True when TikTok confirmed the post."""
    path = Path(clip["file"])
    if not path.exists():
        raise RuntimeError(f"Datei fehlt: {path}")
    log(f"Öffne Upload-Seite für „{clip['title']}“")
    open_upload(d)
    inp = (d.find_elements(By.CSS_SELECTOR, 'input[type=file][accept*="video"]') or d.find_elements(By.CSS_SELECTOR, 'input[type=file]'))[0]
    inp.send_keys(str(path.resolve()))
    log("Video wird hochgeladen…")
    if not wait(lambda: find(d, CAPTION), 90):
        raise RuntimeError("Beschreibungsfeld nicht gefunden")
    def uploaded():
        click_dialogs(d, SKIP)  # feature hints may pop up while uploading
        return d.execute_script(JS_UPLOAD_DONE)
    if not wait(uploaded, 600, 1):
        raise RuntimeError("Upload wurde nicht fertig")
    time.sleep(1.5)  # TikTok writes the file name into the caption around upload completion
    log("Beschreibung einfügen…")
    set_caption(d, clip["caption"] or clip["title"])
    while t := click_dialogs(d, SKIP):
        log(f"Dialog übersprungen: „{t}“")
        time.sleep(0.5)
    btn = wait(lambda: post_ready(d), 600, 1)
    if not btn:
        raise RuntimeError("„Posten“-Button blieb deaktiviert")
    if dry:
        log("Probelauf: alles ausgefüllt, „Posten“ wird NICHT geklickt.")
        return False
    if squash(find(d, CAPTION).text) != squash(clip["caption"] or clip["title"]):
        set_caption(d, clip["caption"] or clip["title"])  # last check right before posting
    time.sleep(1.5)
    log("Klicke „Posten“…")
    d.execute_script("arguments[0].click()", btn)
    start, clicked = d.current_url, set()
    end = time.time() + 180
    while time.time() < end:
        if d.current_url != start and "/upload" not in d.current_url:
            return True
        if any(s in d.find_element(By.TAG_NAME, "body").text.lower() for s in SUCCESS):
            return True
        t = click_dialogs(d, CONFIRM) or click_dialogs(d, SKIP)
        if t and t not in clicked:
            clicked.add(t)
            log(f"Dialog bestätigt/übersprungen: „{t}“")
        time.sleep(1)
    return False


# ---------- CLI ----------

def choose(items: list[dict]) -> list[dict]:
    for i, c in enumerate(items, 1):
        tier = f" [{c['tier']}]" if c.get("tier") else ""
        print(f"  {i:>2}. @{c['streamer']}{tier} – {c['title']}")
    raw = input("\nWelche posten? Nummern (z. B. 1 3), Enter = abbrechen: ").replace(",", " ").split()
    picked = []
    for x in raw:
        if not x.isdigit() or not 1 <= int(x) <= len(items):
            sys.exit(f"Ungültige Auswahl: {x}")
        picked.append(items[int(x) - 1])
    return picked


def main() -> None:
    ap = argparse.ArgumentParser(description="Clips aus der Scheduler-Liste per Selenium auf TikTok posten (manuell).")
    ap.add_argument("ids", nargs="*", help="Clip-IDs direkt (sonst Auswahl-Liste)")
    ap.add_argument("--dry-run", action="store_true", help="alles ausfüllen, aber nicht auf „Posten“ klicken")
    ap.add_argument("--no-mark", action="store_true", help="danach nicht als gepostet markieren")
    ap.add_argument("--gap", type=int, default=30, help="Sekunden Pause zwischen mehreren Posts")
    a = ap.parse_args()

    items = queue()
    if not items:
        sys.exit("Keine exportierten Clips in der Scheduler-Liste.")
    picked = [c for c in items if c["id"] in a.ids] if a.ids else choose(items)
    if a.ids and len(picked) != len(a.ids):
        sys.exit("Nicht alle IDs sind in der Scheduler-Liste.")
    if not picked:
        return

    d = browser()
    failed = 0
    try:
        for n, clip in enumerate(picked):
            try:
                ok = post(d, clip, a.dry_run)
            except Exception as e:
                failed += 1
                log(f"✗ „{clip['title']}“: {e}")
                continue
            if a.dry_run:
                input("Enter = weiter / Browser schließen… ")
            elif ok:
                log(f"✓ Gepostet: „{clip['title']}“")
                if not a.no_mark:
                    mark_posted(clip["id"])
                    log("  als gepostet markiert (verschwindet aus Scheduler)")
            else:
                failed += 1
                log(f"? Keine Bestätigung von TikTok für „{clip['title']}“ – bitte im Browser prüfen, NICHT markiert.")
                input("Enter = weiter… ")
            if n < len(picked) - 1 and not a.dry_run:
                log(f"Warte {a.gap}s bis zum nächsten Post…")
                time.sleep(a.gap)
    finally:
        d.quit()
    sys.exit(1 if failed else 0)
