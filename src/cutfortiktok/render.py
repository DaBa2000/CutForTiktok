from math import ceil, floor
from pathlib import Path

from . import layout
from .config import ROOT, load_config
from .media import FFMPEG, probe, run

FONTS_DIR = str(ROOT / "assets" / "fonts")


def _even(x: float) -> int:
    return max(2, int(round(x)) // 2 * 2)


def _region(src: str, out: str, tr: list, AW: int, AH: int, sw: int, sh: int) -> str:
    """Filter chain: the frame track `tr` of the source (layout.track) scaled into an AW x AH area, black where
    the frame reaches beyond the source. Animated (keyframes with ease) via per-frame expressions."""
    rects = [f for _, _, f in tr]
    x0 = max(0.0, min(f[0] for f in rects) * sw)
    y0 = max(0.0, min(f[1] for f in rects) * sh)
    x1 = min(float(sw), max(f[0] + f[2] for f in rects) * sw)
    y1 = min(float(sh), max(f[1] + f[3] for f in rects) * sh)
    bg = f"color=black:s={AW}x{AH}:r=30"
    if x1 - x0 < 2 or y1 - y0 < 2:  # frame entirely outside the source
        return f"{bg}[{out}];[{src}]nullsink"
    cx0, cy0 = floor(x0 / 2) * 2, floor(y0 / 2) * 2
    cw, ch = min(sw - cx0, _even(ceil(x1 - cx0))), min(sh - cy0, _even(ceil(y1 - cy0)))
    crop = f"crop={cw}:{ch}:{cx0}:{cy0}"
    if len(tr) == 1:
        x, y, w, h = rects[0]
        s = AW / (w * sw)
        if x >= 0 and y >= 0 and x + w <= 1.0001 and y + h <= 1.0001:  # inside the source: plain crop + scale
            px, py = int(x * sw) // 2 * 2, int(y * sh) // 2 * 2
            return (f"[{src}]crop={min(sw - px, _even(w * sw))}:{min(sh - py, _even(h * sh))}:{px}:{py},"
                    f"scale={AW}:{AH},setsar=1[{out}]")
        return (f"[{src}]{crop},scale={_even(cw * s)}:{_even(ch * s)},setsar=1[{src}s];{bg}[{src}b];"
                f"[{src}b][{src}s]overlay={round((cx0 - x * sw) * s)}:{round((cy0 - y * sh) * s)}:shortest=1[{out}]")
    X, Y, Wd = (layout.expr(tr, j) for j in (0, 1, 2))
    s = f"{AW}/(({Wd})*{sw})"
    return (f"[{src}]{crop},scale=w='max(2,trunc({cw}*{s}/2)*2)':h='max(2,trunc({ch}*{s}/2)*2)':eval=frame,setsar=1[{src}s];"
            f"{bg}[{src}b];[{src}b][{src}s]overlay=x='({cx0}-({X})*{sw})*{s}':y='({cy0}-({Y})*{sh})*{s}':eval=frame:shortest=1[{out}]")


def render(src: Path, out: Path, fr: dict, ass: Path | None, *, r: dict | None = None,
           kfs: list | None = None, trim: tuple[float, float] | None = None, preset: str = "medium") -> None:
    """fr: {"cam": frame | None, "game": frame} (layout.frames), kfs: layout.keyframes in source time."""
    r = r or load_config()["render"]
    W, H, CAMH = r["width"], r["height"], r["cam_height"]
    cam = fr.get("cam")
    GAMEH = H - CAMH if cam else H  # no facecam: the stream fills the whole frame
    sw, sh, _ = probe(src)
    shift = trim[0] if trim else 0.0
    game = _region("g0", "g", layout.track(fr["game"], kfs or [], "game", shift), W, GAMEH, sw, sh)
    if cam:
        top = _region("c0", "t", layout.track(cam, kfs or [], "cam", shift), W, CAMH, sw, sh)
        fc = f"[0:v]split=2[c0][g0];{top};{game};[t][g]vstack,setsar=1[v]"
    else:
        fc = f"[0:v]null[g0];{game};[g]null[v]"
    if ass:
        fc += f";[v]ass={ass.resolve()}:fontsdir={FONTS_DIR}[vo]"
    else:
        fc += ";[v]null[vo]"
    cut = ["-ss", f"{trim[0]:.3f}", "-to", f"{trim[1]:.3f}"] if trim else []
    run([
        FFMPEG, "-y", *cut, "-i", str(src), "-filter_complex", fc, "-map", "[vo]", "-map", "0:a?",
        "-c:v", "libx264", "-preset", preset, "-crf", str(r["crf"]), "-pix_fmt", "yuv420p",
        "-r", "30", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", str(out),
    ])
