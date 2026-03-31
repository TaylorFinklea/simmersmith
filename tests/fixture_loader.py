from __future__ import annotations

from pathlib import Path


FIXTURES_ROOT = Path(__file__).parent / "fixtures"


def load_fixture_text(relative_path: str) -> str:
    return (FIXTURES_ROOT / relative_path).read_text(encoding="utf-8").strip()
