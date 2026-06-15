"""GA-time runner: corpus × backends → scorecards → comparison table.

Not invoked now (run deferred to iOS 27 GA per 2026-06-15). At GA: wire the
backends, run this, paste the table into the Spike-2 report section.

THROWAWAY spike. See .docs/ai/phases/cloudkit-migration-spikes-spec.md.
"""
from __future__ import annotations

from backends import Backend
from corpus import CORPUS
from rubric import Scorecard, format_table, score


def run_backend(backend: Backend) -> list[Scorecard]:
    cards: list[Scorecard] = []
    for context in CORPUS:
        plan, latency = backend.generate(context)      # raises until wired at GA
        cards.append(score(plan, context, latency_seconds=latency))
    return cards


def run_all(backends: list[Backend]) -> dict[str, list[Scorecard]]:
    return {b.name: run_backend(b) for b in backends}


def report_section(results: dict[str, list[Scorecard]]) -> str:
    blocks: list[str] = []
    for name, cards in results.items():
        passes = sum(1 for c in cards if c.passed)
        blocks.append(f"### {name} — {passes}/{len(cards)} allergy-safe\n\n{format_table(cards)}")
    return "\n\n".join(blocks)


if __name__ == "__main__":  # pragma: no cover
    print("Spike 2 run is deferred to iOS 27 GA. Backends are stubs; wire them first.")
    print(f"Corpus: {len(CORPUS)} contexts ready.")
