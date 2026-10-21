"""Picture layout of the vertical video, shared by render, editor and iPhone app.

Output: facecam area (width x cam_h) on top, game area below (the whole frame without facecam).
Each area shows a *frame* of the source: [x, y, w, h] in normalized source coords (0..1), with the aspect of
its area, so what is inside the frame is exactly what the area shows. A frame may reach beyond the source:
that part stays black (zoomed-out game = black bars above/below).

Keyframes change the frames during a clip: [{"t": source time, "cam": frame, "game": frame, "ease": s}]
- from `t` on the keyframe's frames are shown, reached over `ease` seconds (0 = jump). Before the first
keyframe the clip's own frames (cam / game columns) apply. The facecam area height is the same for the whole clip.

Old clips stored the game crop as game_x (horizontal center) + zoom (0..1 wider window, black bars); facecam
boxes of any aspect were cropped to the area ("cover"). legacy_game / cover convert them."""
import json


def area_h(r: dict, cam_h: int | None, has_cam: bool, region: str) -> int:
    ch = int(cam_h or r["cam_height"]) // 2 * 2
    if region == "cam":
        return ch
    return r["height"] - ch if has_cam else r["height"]


def fit(rect, aspect: float, sw: int, sh: int) -> list[float]:
    """Same center and height, width from the area aspect (output px width / height): a game frame showing the
    full source height keeps doing so when the facecam area changes."""
    x, y, w, h = rect
    nw = h * sh * aspect / sw
    return [x + (w - nw) / 2, y, nw, h]


def cover(rect, aspect: float, sw: int, sh: int) -> list[float]:
    """Largest frame of the area aspect inside rect, centered (old facecam boxes: crop like ffmpeg increase+crop)."""
    x, y, w, h = rect
    if w * sw / (h * sh) > aspect:
        nw = h * sh * aspect / sw
        return [x + (w - nw) / 2, y, nw, h]
    nh = w * sw / (sh * aspect)
    return [x, y + (h - nh) / 2, w, nh]


def legacy_game(game_x: float | None, zoom: float | None, sw: int, sh: int, W: int, game_h: int) -> list[float]:
    """game_x + zoom -> game frame (full source height, wider = black bars)."""
    fw = min(sw, sh * W / game_h)
    gw = fw + max(0.0, min(1.0, zoom or 0)) * (sw - fw)
    x = max(0.0, min(sw - gw, (0.5 if game_x is None else game_x) * sw - gw / 2))
    h = gw * game_h / W / sh  # >= 1 when zoomed out
    return [x / sw, (1 - h) / 2, gw / sw, h]


def default_game(sw: int, sh: int, W: int, game_h: int) -> list[float]:
    return legacy_game(0.5, 0, sw, sh, W, game_h)


def frames(d, sw: int, sh: int, r: dict, cam_h: int | None) -> dict:
    """{"cam": frame | None, "game": frame} of a clip row / layout dict, normalized to the area aspects."""
    d = dict(d)
    cam, game = (json.loads(v) if isinstance(v, str) else v for v in (d.get("cam"), d.get("game")))
    W = r["width"]
    gh = area_h(r, cam_h, bool(cam), "game")
    if not game:
        game = legacy_game(d.get("game_x"), d.get("zoom"), sw, sh, W, gh)
    return {"cam": cover(cam, W / area_h(r, cam_h, True, "cam"), sw, sh) if cam else None,
            "game": fit(game, W / gh, sw, sh)}


def keyframes(kfs, sw: int, sh: int, r: dict, cam_h: int | None, has_cam: bool) -> list[dict]:
    """Keyframes sorted by time, frames normalized to the area aspects."""
    out = []
    W = r["width"]
    for k in sorted(kfs or [], key=lambda k: float(k["t"])):
        game = k.get("game")
        cam = k.get("cam") if has_cam else None
        out.append({"t": float(k["t"]), "ease": max(0.0, float(k.get("ease") or 0)),
                    "cam": cover(cam, W / area_h(r, cam_h, True, "cam"), sw, sh) if cam else None,
                    "game": fit(game, W / area_h(r, cam_h, has_cam, "game"), sw, sh) if game else None})
    return out


def track(base, kfs: list[dict], region: str, shift: float = 0.0) -> list[tuple[float, float, list[float]]]:
    """Frames of one region over time: [(t, ease, frame)], first entry = base at -inf.
    Keyframes without a frame for this region keep the previous one. shift: subtracted from keyframe times."""
    out = [(-1e9, 0.0, base)]
    for k in kfs:
        f = k.get(region)
        if f:
            out.append((k["t"] - shift, k["ease"], f))
    return out


def at(tr: list[tuple[float, float, list[float]]], t: float) -> list[float]:
    """Frame of a track at time t (same as the expression rendered by ffmpeg and drawn by the previews)."""
    cur = tr[0][2]
    for i in range(1, len(tr)):
        t0, ease, f = tr[i]
        if t < t0:
            break
        nxt = tr[i + 1][0] if i + 1 < len(tr) else 1e9
        e = min(ease, nxt - t0)
        if e > 0 and t < t0 + e:
            k = (t - t0) / e
            return [a + (b - a) * k for a, b in zip(cur, f)]
        cur = f
    return cur


def expr(tr: list[tuple[float, float, list[float]]], j: int) -> str:
    """ffmpeg expression (variable t) of coordinate j of a track: piecewise constant / linear."""
    pieces = []  # (from t, expression) in time order
    prev = tr[0][2][j]
    pieces.append((-1e9, f"{prev:.6f}"))
    for i in range(1, len(tr)):
        t0, ease, f = tr[i]
        nxt = tr[i + 1][0] if i + 1 < len(tr) else 1e9
        e = min(ease, nxt - t0)
        v = f[j]
        if e > 0:
            pieces.append((t0, f"({prev:.6f}+({v - prev:.6f})*(t-({t0:.4f}))/{e:.4f})"))
            pieces.append((t0 + e, f"{v:.6f}"))
        else:
            pieces.append((t0, f"{v:.6f}"))
        prev = v
    s = pieces[-1][1]
    for k in range(len(pieces) - 2, -1, -1):
        s = f"if(lt(t,{pieces[k + 1][0]:.4f}),{pieces[k][1]},{s})"
    return s
