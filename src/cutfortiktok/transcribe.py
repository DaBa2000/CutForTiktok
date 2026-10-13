import json
from pathlib import Path

from .config import ROOT, env, load_config
from .media import extract_audio

_model = None


def _get_model():
    global _model
    if _model is None:
        from faster_whisper import WhisperModel
        name = env("WHISPER_MODEL") or load_config()["transcribe"]["model"]
        # CPU int8 is the fast path on Apple Silicon for faster-whisper.
        # Cached model first: the hub update check can hang on a broken network (e.g. dead IPv6).
        try:
            _model = WhisperModel(name, device="cpu", compute_type="int8", local_files_only=True)
        except Exception:
            _model = WhisperModel(name, device="cpu", compute_type="int8")
    return _model


def transcribe(video: Path, work: Path) -> list[dict]:
    """Returns words: [{"word","start","end"}]. Cached next to the work files."""
    cache = work / f"{video.stem}.words.json"
    if cache.exists():
        return json.loads(cache.read_text())
    cfg = load_config()["transcribe"]
    gloss = ROOT / cfg.get("glossary_file", "")
    prompt = gloss.read_text().strip() if gloss.is_file() else None
    wav = work / f"{video.stem}.wav"
    extract_audio(video, wav)
    segments, _ = _get_model().transcribe(
        str(wav), language=cfg["language"], word_timestamps=True,
        vad_filter=True, initial_prompt=prompt, beam_size=5,
    )
    words = [
        {"word": w.word.strip(), "start": w.start, "end": w.end}
        for s in segments for w in (s.words or []) if w.word.strip()
    ]
    wav.unlink(missing_ok=True)
    cache.write_text(json.dumps(words, ensure_ascii=False))
    return words
