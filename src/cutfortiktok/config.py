import os
from dataclasses import dataclass
from pathlib import Path

import yaml
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[2]
load_dotenv(ROOT / ".env")


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def require_env(*names: str) -> None:
    missing = [n for n in names if not env(n)]
    if missing:
        raise SystemExit(
            f"Missing in .env: {', '.join(missing)} (see .env.example)"
        )


@dataclass
class Paths:
    data: Path

    @property
    def raw(self) -> Path: return self.data / "raw"
    @property
    def work(self) -> Path: return self.data / "work"
    @property
    def out(self) -> Path: return self.data / "out"
    @property
    def db(self) -> Path: return self.data / "state.sqlite"

    def ensure(self) -> None:
        for p in (self.raw, self.work, self.out):
            p.mkdir(parents=True, exist_ok=True)


def load_config() -> dict:
    with open(ROOT / "config.yaml") as f:
        return yaml.safe_load(f) or {}


def paths() -> Paths:
    p = Paths(ROOT / env("DATA_DIR", "data"))
    p.ensure()
    return p
