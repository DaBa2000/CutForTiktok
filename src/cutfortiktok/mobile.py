"""iPhone app (ios-build-clipper): pairing by QR code + token check for requests from the LAN.
Requests from this Mac (browser, TikTok helper extension) need no token."""
import ipaddress
import secrets
import socket
from urllib.parse import quote

import segno

from .config import paths

COOKIE = "cft"


def token() -> str:
    """Pairing secret, created once; delete data/mobile_token to unpair all phones."""
    f = paths().data / "mobile_token"
    if not f.exists():
        f.write_text(secrets.token_urlsafe(24))
    return f.read_text().strip()


def lan_ip() -> str:
    """This Mac's address in the WiFi (no packet is sent, the OS only picks the outgoing interface)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("10.255.255.255", 1))
            return s.getsockname()[0]
        except OSError:
            return "127.0.0.1"


def is_local(addr: str) -> bool:
    try:
        return ipaddress.ip_address(addr.removeprefix("::ffff:")).is_loopback
    except ValueError:
        return False


def authorized(addr: str, headers, query: dict) -> bool:
    if is_local(addr):
        return True
    tok = token()
    cookies = dict(c.strip().split("=", 1) for c in (headers.get("Cookie") or "").split(";") if "=" in c)
    given = headers.get("X-Clipper-Token") or (query.get("k") or [""])[0] or cookies.get(COOKIE, "")
    return secrets.compare_digest(given, tok)


def pair_url(port: int) -> str:
    return f"clipper://pair?u={quote(f'http://{lan_ip()}:{port}', safe='')}&k={token()}"


def pair_page(port: int) -> bytes:
    url = pair_url(port)
    svg = segno.make(url, error="m").svg_inline(scale=8, dark="#000", light="#fff", border=3)
    return f"""<!doctype html><html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>iPhone verbinden</title>
<style>
body{{font:15px/1.5 -apple-system,system-ui,sans-serif;background:#0c0c0f;color:#ececf1;margin:0;display:grid;place-items:center;min-height:100vh}}
.box{{background:#16161b;border:1px solid #2a2a33;border-radius:18px;padding:28px;max-width:420px;text-align:center}}
.qr{{background:#fff;border-radius:14px;display:inline-block;line-height:0;margin:14px 0}}
code{{color:#25f4ee}}small{{color:#8d8d9a}}a{{color:#8d8d9a}}
</style>
<div class="box"><h2 style="margin:0">📱 iPhone verbinden</h2>
<div class="qr">{svg}</div>
<div>In der <b>Clipper</b>-App „QR-Code scannen“ tippen<br>(oder mit der iPhone-Kamera scannen).</div>
<p><small>Server: <code>http://{lan_ip()}:{port}</code><br>iPhone und Mac müssen im selben WLAN sein.<br>
Alle Handys trennen: <code>data/mobile_token</code> löschen und App neu starten.</small></p>
<a href="/">← zurück</a></div>""".encode()
