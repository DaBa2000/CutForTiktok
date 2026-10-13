from pathlib import Path

from .config import ROOT, load_config
from .media import FFMPEG, probe, run

FONTS_DIR = str(ROOT / "assets" / "fonts")


def _even(x: float) -> int:
    return int(x) // 2 * 2


def render(src: Path, out: Path, cam: list | None, ass: Path | None, *, r: dict | None = None,
           game_x: float | None = None, trim: tuple[float, float] | None = None, preset: str = "medium") -> None:
    r = r or load_config()["render"]
    W, H, CAMH = r["width"], r["height"], r["cam_height"]
    GAMEH = H - CAMH
    sw, sh, _ = probe(src)

    # game window: full source height, cropped to the bottom area's aspect
    gw = _even(min(sw, sh * W / GAMEH))
    gx = _even(max(0, min(sw - gw, (r["game_center_x"] if game_x is None else game_x) * sw - gw / 2)))
    game = f"crop={gw}:{sh}:{gx}:0,scale={W}:{GAMEH}"

    if cam:
        x, y, w, h = cam
        top = (f"crop={_even(w * sw)}:{_even(h * sh)}:{_even(x * sw)}:{_even(y * sh)},"
               f"scale={W}:{CAMH}:force_original_aspect_ratio=increase,crop={W}:{CAMH}")
    else:  # no facecam: show the whole frame on top
        top = f"scale={W}:{CAMH}:force_original_aspect_ratio=increase,crop={W}:{CAMH}"

    fc = f"[0:v]split=2[a][b];[a]{top}[t];[b]{game}[g];[t][g]vstack,setsar=1[v]"
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
