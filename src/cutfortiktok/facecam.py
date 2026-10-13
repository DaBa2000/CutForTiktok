"""Facecam detection. Rects are stored normalized (0..1) per streamer in layouts.json
so they survive different source resolutions. Edit layouts.json by hand to override."""
import json
from pathlib import Path

import cv2
import requests
import numpy as np

from .config import ROOT

LAYOUTS = ROOT / "layouts.json"
YUNET = ROOT / "models" / "face_detection_yunet_2023mar.onnx"
YUNET_URL = "https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx"
NO_CAM = {"cam": None}


def load_layouts() -> dict:
    return json.loads(LAYOUTS.read_text()) if LAYOUTS.exists() else {}


def save_layout(streamer: str, layout: dict) -> None:
    d = load_layouts()
    d[streamer] = layout
    LAYOUTS.write_text(json.dumps(d, indent=2))


def _iou(a, b) -> float:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ix = max(0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0, min(ay + ah, by + bh) - max(ay, by))
    inter = ix * iy
    return inter / (aw * ah + bw * bh - inter + 1e-9)


EDGE_W = 640  # edge analysis resolution


def _edge_maps(frames: list[np.ndarray]) -> tuple[np.ndarray, np.ndarray]:
    """Time-averaged binary edge maps (vertical, horizontal). Moving game footage averages out;
    static overlay borders stay strong."""
    vx, hy = [], []
    for f in frames:
        g = cv2.GaussianBlur(f, (3, 3), 0).astype(np.float32)
        vx.append(np.abs(cv2.Sobel(g, cv2.CV_32F, 1, 0, ksize=3)) > 40)
        hy.append(np.abs(cv2.Sobel(g, cv2.CV_32F, 0, 1, ksize=3)) > 40)
    return np.mean(vx, axis=0), np.mean(hy, axis=0)


def _best_line(profile_fn, candidates, edge_pos) -> tuple[int, float]:
    """Strongest straight border among candidates; the frame edge counts as a border."""
    best, score = None, 0.0
    for c in candidates:
        sc = profile_fn(c)
        if sc > score:
            best, score = c, sc
    if edge_pos is not None and score < 0.5:
        return edge_pos, 1.0
    return best, score


def _overlay_box(frames, face, W, H) -> tuple[float, float, float, float]:
    """Grow from the face to the surrounding overlay border (in EDGE_W pixel space)."""
    ex, ey = _edge_maps(frames)
    h, w = ex.shape
    fx, fy, fw, fh = face
    cx, cy = fx + fw / 2, fy + fh / 2
    # initial guess: typical webcam framing around a face
    x0, x1 = cx - 2.2 * fw, cx + 2.2 * fw
    y0, y1 = cy - 1.6 * fh, cy + 2.2 * fh
    S = 0.7  # min fraction of the side that must be edge pixels
    for _ in range(3):
        ya, yb = int(max(0, y0)), int(min(h, y1))
        xa, xb = int(max(0, x0)), int(min(w, x1))
        col = lambda x: float(np.mean(np.maximum.reduce([ex[ya:yb, max(0, x - 1)], ex[ya:yb, x], ex[ya:yb, min(w - 1, x + 1)]])))
        row = lambda y: float(np.mean(np.maximum.reduce([ey[max(0, y - 1), xa:xb], ey[y, xa:xb], ey[min(h - 1, y + 1), xa:xb]])))
        lo = int(max(0, cx - 8 * fw)); hi = int(min(w - 1, cx + 8 * fw))
        L, sl = _best_line(col, range(lo, int(cx - 1.2 * fw)), 0 if lo == 0 else None)
        R, sr = _best_line(col, range(int(cx + 1.2 * fw), hi + 1), w if hi >= w - 1 else None)
        lo = int(max(0, cy - 6 * fh)); hi = int(min(h - 1, cy + 7 * fh))
        T, st = _best_line(row, range(lo, int(cy - 1.0 * fh)), 0 if lo == 0 else None)
        B, sb = _best_line(row, range(int(cy + 1.2 * fh), hi + 1), h if hi >= h - 1 else None)
        if L is not None and sl >= S * 0.7: x0 = L
        if R is not None and sr >= S * 0.7: x1 = R
        if T is not None and st >= S * 0.7: y0 = T
        if B is not None and sb >= S * 0.7: y1 = B
    # step inside the border line so the overlay frame itself isn't in the crop
    inset = 3
    x0, y0 = max(0.0, x0 + (inset if x0 > 0 else 0)), max(0.0, y0 + (inset if y0 > 0 else 0))
    x1, y1 = min(float(w), x1 - (inset if x1 < w else 0)), min(float(h), y1 - (inset if y1 < h else 0))
    return x0 / w, y0 / h, (x1 - x0) / w, (y1 - y0) / h


def detect(video: Path, samples: int = 16) -> dict:
    """Return {"cam": [x,y,w,h] normalized} or {"cam": None} if no consistent face found."""
    cap = cv2.VideoCapture(str(video))
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    W = cap.get(cv2.CAP_PROP_FRAME_WIDTH)
    H = cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
    if not YUNET.exists():
        YUNET.parent.mkdir(exist_ok=True)
        YUNET.write_bytes(requests.get(YUNET_URL, timeout=60).content)
    yunet = cv2.FaceDetectorYN.create(str(YUNET), "", (int(W), int(H)), score_threshold=0.75)
    k = EDGE_W / W
    dets, small = [], []
    for i in range(samples):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int((i + 0.5) * n / samples))
        ok, frame = cap.read()
        if not ok:
            continue
        small.append(cv2.cvtColor(cv2.resize(frame, (EDGE_W, int(H * k))), cv2.COLOR_BGR2GRAY))
        _, faces = yunet.detect(frame)
        if faces is not None:
            dets += [tuple(map(int, f[:4])) for f in faces if f[2] >= W * 0.02]
    cap.release()
    if not dets:
        return NO_CAM

    # Cluster by overlap; a real facecam shows a face in roughly the same place across frames.
    best, best_count = None, 0
    for d in dets:
        members = [e for e in dets if _iou(d, e) > 0.2]
        if len(members) > best_count:
            best, best_count = members, len(members)
    if best_count < max(3, samples * 0.35):
        return NO_CAM
    face = [float(np.median([m[j] for m in best])) * k for j in range(4)]
    x, y, w, h = _overlay_box(small, face, W, H)
    return {"cam": [round(x, 4), round(y, 4), round(w, 4), round(h, 4)]}


def get_layout(streamer: str, video: Path) -> dict:
    """Cached per streamer; detects on first use."""
    d = load_layouts()
    if streamer not in d:
        save_layout(streamer, detect(video))
        d = load_layouts()
    return d[streamer]


def preview(video: Path, layout: dict, out: Path) -> None:
    cap = cv2.VideoCapture(str(video))
    cap.set(cv2.CAP_PROP_POS_FRAMES, int(cap.get(cv2.CAP_PROP_FRAME_COUNT) / 2))
    ok, frame = cap.read()
    cap.release()
    if ok and layout.get("cam"):
        H, W = frame.shape[:2]
        x, y, w, h = layout["cam"]
        cv2.rectangle(frame, (int(x * W), int(y * H)), (int((x + w) * W), int((y + h) * H)), (0, 255, 0), 4)
    if ok:
        cv2.imwrite(str(out), frame)
