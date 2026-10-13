"""Words -> ASS: CapCut/TikTok-style subtitles (2-3 words, uppercase, the spoken word
highlighted + enlarged) in the game area, plus a title card between facecam and game."""
import re
import unicodedata
from pathlib import Path


def _t(s: float) -> str:
    cs = int(round(max(0.0, s) * 100))
    return f"{cs // 360000}:{cs // 6000 % 60:02d}:{cs // 100 % 60:02d}.{cs % 100:02d}"


def _ass_color(hex_rgb: str, alpha: int = 0) -> str:
    h = hex_rgb.lstrip("#")
    return f"&H{alpha:02X}{h[4:6]}{h[2:4]}{h[0:2]}".upper()


def _clean(text: str) -> str:
    """User text must not inject ASS override tags; emoji can't be rendered by libass."""
    text = "".join(c for c in text if ord(c) <= 0xFFFF and unicodedata.category(c) != "So"
                   and c not in "\u200d\ufe0f")
    text = text.replace("\\", "/").replace("{", "(").replace("}", ")").replace("\n", " ")
    return re.sub(r"\s{2,}", " ", text).strip()


def chunk_words(words: list[dict], max_words=3, max_chars=18, gap=0.6) -> list[list[dict]]:
    out, cur = [], []
    for w in words:
        if cur and (
            len(cur) >= max_words
            or sum(len(x["word"]) + 1 for x in cur) + len(w["word"]) > max_chars
            or w["start"] - cur[-1]["end"] > gap
            or cur[-1]["word"][-1:] in ".?!"
        ):
            out.append(cur)
            cur = []
        cur.append(w)
    if cur:
        out.append(cur)
    return out


def retime(text: str, start: float, end: float) -> list[dict]:
    """Split edited text into words, distributing [start,end] by character length."""
    toks = text.split()
    if not toks or end <= start:
        return []
    total = sum(len(t) + 1 for t in toks)
    out, t = [], start
    for tok in toks:
        d = (end - start) * (len(tok) + 1) / total
        out.append({"word": tok, "start": round(t, 3), "end": round(t + d, 3)})
        t += d
    return out


def build_ass(chunks: list[list[dict]], out: Path, *, render: dict, offset: float = 0.0,
              duration: float = 1e9, title: str | None = None, credit: str | None = None,
              credits: list[tuple[float, float, str]] | None = None) -> None:
    """credits: (start, end, text) in the trimmed timeline, replaces `credit` (perspective switches)."""
    W, H = render["width"], render["height"]
    seam, subs_y = render["cam_height"], render["subs_y"]
    font, fs = render["font"], render["font_size"]
    hl = _ass_color(render["highlight"])
    head = f"""[Script Info]
ScriptType: v4.00+
PlayResX: {W}
PlayResY: {H}
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Sub,{font},{fs},&H00FFFFFF,&H00FFFFFF,&H00000000,&H90000000,0,0,0,0,100,100,1,0,1,8,5,5,60,60,0,1
Style: Title,{font},{render["title_size"]},&H00111111,&H00111111,&H00FFFFFF,&H64000000,0,0,0,0,100,100,0,0,3,22,0,5,110,110,0,1
Style: Credit,{font},40,&H00FFFFFF,&H00FFFFFF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,4,2,7,30,30,30,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
    lines = []
    # shift into the trimmed timeline and drop what falls outside
    chunks = [[{**w, "start": w["start"] - offset, "end": w["end"] - offset} for w in ch] for ch in chunks if ch]
    chunks = [ch for ch in chunks if ch[-1]["end"] > 0 and ch[0]["start"] < duration]
    pos = f"\\an5\\pos({W // 2},{subs_y})"
    for i, ch in enumerate(chunks):
        start = max(0.0, ch[0]["start"])
        end = min(duration, ch[-1]["end"])
        if i + 1 < len(chunks) and chunks[i + 1][0]["start"] - end < 0.3:
            end = max(end, chunks[i + 1][0]["start"])
        words = [_clean(w["word"]).upper() for w in ch]
        # one event per spoken word: that word is colored + slightly bigger
        for j, w in enumerate(ch):
            ws = start if j == 0 else max(start, w["start"])
            we = end if j == len(ch) - 1 else min(end, ch[j + 1]["start"])
            if we <= ws:
                continue
            pop = "\\fscx92\\fscy92\\t(0,90,\\fscx100\\fscy100)" if j == 0 else ""
            text = " ".join(
                f"{{\\c{hl}\\fscx112\\fscy112}}{t}{{\\c&H00FFFFFF&\\fscx100\\fscy100}}" if k == j else t
                for k, t in enumerate(words)
            )
            lines.append(f"Dialogue: 0,{_t(ws)},{_t(we)},Sub,,0,0,0,,{{{pos}{pop}}}{text}")
    if title and title.strip():
        secs = min(render["title_secs"], duration)
        lines.append(
            f"Dialogue: 2,{_t(0)},{_t(secs)},Title,,0,0,0,,"
            f"{{\\an5\\pos({W // 2},{seam})\\fad(120,220)\\fscx70\\fscy70\\t(0,160,\\fscx104\\fscy104)\\t(160,260,\\fscx100\\fscy100)}}"
            f"{_clean(title.strip())}"
        )
    for a, b, text in credits or ([(0.0, 35999.0, credit)] if credit else []):
        lines.append(f"Dialogue: 1,{_t(a)},{_t(b)},Credit,,0,0,0,,{_clean(text)}")
    out.write_text(head + "\n".join(lines) + "\n", encoding="utf-8")
