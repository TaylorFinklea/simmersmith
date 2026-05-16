"""SimmerSmith Shopping CLI.

Two modes:

- `python -m simmersmith_shopping --list "SimmerSmith"` runs the full
  Reminders → split → cart-fill pipeline.
- `python -m simmersmith_shopping login --store aldi` opens an
  interactive Playwright window so the user can sign in once; the
  cookies persist in `~/.config/simmersmith/skill-profile/<store>/`.

`--dry-run` prints the parsed list + proposed split without opening
any cart.
"""
from __future__ import annotations

import argparse
import logging
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from rich.console import Console
from rich.table import Table

from .parser import GroceryLine, parse
from .reminders import RemindersAccessError, read_list
from .splitter import Candidate, StoreSplit, split as split_items
from .stores import REGISTRY


console = Console()


# ---------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------

def _load_env() -> None:
    """Best-effort: read `~/.config/simmersmith/skill.env` so per-user
    preferences (delivery minimums, API base, etc.) override defaults
    without env-var ceremony in every shell."""
    try:
        from dotenv import load_dotenv  # type: ignore

        path = Path("~/.config/simmersmith/skill.env").expanduser()
        if path.exists():
            load_dotenv(path)
    except ImportError:
        pass


def _minimums() -> dict[str, float]:
    return {
        "aldi": float(os.environ.get("SIMMERSMITH_ALDI_MIN", "35")),
        "walmart": float(os.environ.get("SIMMERSMITH_WALMART_MIN", "35")),
        "sams_club": float(os.environ.get("SIMMERSMITH_SAMS_MIN", "50")),
        "instacart": float(os.environ.get("SIMMERSMITH_INSTACART_MIN", "10")),
    }


# ---------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------

def _ensure_playwright_chromium() -> None:
    """Auto-install Playwright's Chromium binary if it isn't present.
    Avoids forcing the user to remember `playwright install` after a
    fresh `uv` cache rebuild — first browser-driving call self-heals.
    """
    import subprocess
    from pathlib import Path

    # Playwright caches browsers under ~/Library/Caches/ms-playwright on
    # macOS. We don't introspect the cache layout — we just try the
    # noop install command, which exits 0 quickly when chromium is
    # already present.
    cache_marker = Path.home() / "Library" / "Caches" / "ms-playwright"
    if cache_marker.exists() and any(
        p.name.startswith("chromium-") for p in cache_marker.iterdir()
    ):
        return
    console.print("[yellow]Installing Playwright Chromium (one-time, ~150MB)...[/yellow]")
    subprocess.run(
        [sys.executable, "-m", "playwright", "install", "chromium"],
        check=False,
    )


def cmd_login(args: argparse.Namespace) -> int:
    handler = REGISTRY.get(args.store)
    if handler is None:
        console.print(f"[red]unknown store: {args.store}[/red]")
        return 2

    _ensure_playwright_chromium()
    from playwright.sync_api import sync_playwright

    console.print(f"[bold]Opening {handler.display_name} for interactive login.[/bold]")
    console.print("Sign in normally, then close the window. Cookies persist.")
    with sync_playwright() as pw:
        context = pw.chromium.launch_persistent_context(
            user_data_dir=str(handler.profile_path()),
            headless=False,
        )
        page = context.new_page()
        page.goto(handler.default_login_url)
        try:
            # Block until the user closes every page (and thus the window).
            while context.pages:
                page.wait_for_event("close", timeout=0)
        except Exception:
            pass
        finally:
            context.close()
    console.print(f"[green]✓ {handler.display_name} cookies saved.[/green]")
    return 0


def cmd_capture(args: argparse.Namespace) -> int:
    """Walk the user through one search + one ADD interaction in the
    persistent profile, snapshot the rendered HTML at each step, and
    emit a ranked candidates file. The output is structured so that
    `grep -E '(data-testid|aria-label).+search' candidates.txt` lands
    the search-input selector immediately.
    """
    handler = REGISTRY.get(args.store)
    if handler is None:
        console.print(f"[red]unknown store: {args.store}[/red]")
        return 2

    _ensure_playwright_chromium()
    from playwright.sync_api import sync_playwright

    capture_root = Path(
        os.environ.get("SIMMERSMITH_CAPTURE_ROOT")
        or "~/.config/simmersmith-shopping/captures"
    ).expanduser()
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = capture_root / f"{handler.slug}-{timestamp}"
    out_dir.mkdir(parents=True, exist_ok=True)

    console.print(f"[bold]Capture mode — {handler.display_name}[/bold]")
    console.print(f"Output: {out_dir}")
    console.print()
    console.print("This walks you through one search and one ADD interaction.")
    console.print("At each prompt, return to the terminal and press Enter when ready.")
    console.print()

    with sync_playwright() as pw:
        context = pw.chromium.launch_persistent_context(
            user_data_dir=str(handler.profile_path()),
            headless=False,
        )
        try:
            page = context.new_page()
            page.goto(handler.default_login_url)

            console.print("[bold]Step 1.[/bold] In the browser, search for any common item")
            console.print("(e.g. 'milk' or 'eggs'). Wait for the results grid to render.")
            console.print("Then return here and press [bold]Enter[/bold].")
            if not _wait_for_enter():
                console.print("[yellow]aborted[/yellow]")
                return 1
            _snapshot_page(_active_page(context, page), out_dir, label="search")
            console.print("[green]✓[/green] search snapshot saved")

            console.print()
            console.print("[bold]Step 2.[/bold] Click a product, then click the store's ADD button.")
            console.print("Wait for the cart confirmation (badge, drawer, etc.) to render.")
            console.print("Then return here and press [bold]Enter[/bold].")
            if not _wait_for_enter():
                console.print("[yellow]aborted — partial capture in place[/yellow]")
            else:
                _snapshot_page(_active_page(context, page), out_dir, label="product")
                console.print("[green]✓[/green] product snapshot saved")
        finally:
            context.close()

    _emit_candidates(out_dir)
    console.print()
    console.print("[bold green]Capture complete.[/bold green]")
    console.print(f"  search.html, product.html, candidates.txt → {out_dir}")
    console.print()
    console.print("Next:")
    console.print(f"  1. Open {out_dir / 'candidates.txt'}")
    console.print( "  2. Pick search_input / product_card / card_title / card_price / card_link / add_to_cart")
    console.print(f"  3. Fill in `_SELECTORS` in skills/simmersmith-shopping/src/simmersmith_shopping/stores/{handler.slug}.py")
    console.print( "  4. Re-run the skill against a small grocery list to validate.")
    return 0


def _wait_for_enter() -> bool:
    try:
        input()
        return True
    except (EOFError, KeyboardInterrupt):
        return False


def _active_page(context, fallback):
    """Return the most recently focused page in the persistent context.

    The user can navigate from the original landing page across N
    intermediate links during capture; we always want the page they're
    actually looking at, not the initial one we opened.
    """
    if context.pages:
        return context.pages[-1]
    return fallback


def _snapshot_page(page, out_dir: Path, *, label: str) -> None:
    try:
        html = page.content()
        url = page.url
    except Exception as exc:  # noqa: BLE001 — best-effort snapshot
        log = logging.getLogger(__name__)
        log.warning("snapshot for %s failed: %s", label, exc)
        return
    (out_dir / f"{label}.html").write_text(html, encoding="utf-8")
    (out_dir / f"{label}.url").write_text(url, encoding="utf-8")


# Highest-stability attributes first; the candidates file is sorted by
# this priority so `data-testid` matches surface above brittle CSS.
_CANDIDATE_ATTRS = (
    "data-testid",
    "data-automation-id",
    "data-test",
    "aria-label",
    "role",
    "name",
)


def _emit_candidates(out_dir: Path) -> None:
    """Parse each captured HTML file, walk every element with at least
    one priority attribute, and write a ranked single-file digest.

    Uses stdlib `html.parser` (no soup/lxml dep) — we don't need a
    real DOM, just attribute extraction and a short tag-excerpt.
    """
    from html.parser import HTMLParser

    rows: list[tuple[int, str, str, str, str, str]] = []  # (priority, attr, value, tag, label, excerpt)

    class _Collector(HTMLParser):
        def __init__(self, label: str) -> None:
            super().__init__(convert_charrefs=True)
            self._label = label

        def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
            attrs_dict = {k.lower(): (v or "") for k, v in attrs}
            for priority, attr in enumerate(_CANDIDATE_ATTRS):
                if attr in attrs_dict and attrs_dict[attr]:
                    pairs = " ".join(f'{k}="{v}"' for k, v in attrs[:6] if v is not None)
                    excerpt = f"<{tag} {pairs}>"[:240]
                    rows.append((priority, attr, attrs_dict[attr], tag, self._label, excerpt))
                    break

    for label in ("search", "product"):
        path = out_dir / f"{label}.html"
        if not path.exists():
            continue
        collector = _Collector(label)
        try:
            collector.feed(path.read_text(encoding="utf-8", errors="replace"))
        except Exception as exc:  # noqa: BLE001
            log = logging.getLogger(__name__)
            log.warning("parsing %s.html failed: %s", label, exc)

    seen: set[tuple[str, str, str, str]] = set()
    deduped: list[tuple[int, str, str, str, str, str]] = []
    for row in rows:
        key = (row[1], row[2], row[3], row[4])
        if key in seen:
            continue
        seen.add(key)
        deduped.append(row)
    deduped.sort(key=lambda r: (r[0], r[4], r[1], r[2]))

    lines = [
        f"# Selector candidates — {out_dir.name}",
        "# Columns: PAGE | ATTR=VALUE | TAG | EXCERPT",
        "# Priority order: " + " > ".join(_CANDIDATE_ATTRS),
        "# Grep hints:",
        "#   grep -E '(testid|aria-label).+search' candidates.txt",
        "#   grep -E '(testid|automation-id).+(add|cart)' candidates.txt",
        "#   grep -E '(testid|automation-id).+(product|item).*card' candidates.txt",
        "",
    ]
    for _priority, attr, value, tag, label, excerpt in deduped:
        lines.append(f"{label:8s} | {attr}={value!r:50s} | {tag:8s} | {excerpt}")

    (out_dir / "candidates.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def cmd_run(args: argparse.Namespace) -> int:
    try:
        rows = read_list(args.list)
    except RemindersAccessError as exc:
        console.print(f"[red]Reminders error:[/red] {exc}")
        return 1

    parsed: list[GroceryLine] = [
        parse(title, completed=completed)
        for title, completed in rows
        if title and not completed   # skip already-checked items
    ]
    if not parsed:
        console.print(f"[yellow]No unchecked items in list {args.list!r}.[/yellow]")
        return 0

    chosen_stores = _resolve_chosen_stores(args.stores)
    handlers = [REGISTRY[s] for s in chosen_stores]

    if args.dry_run:
        candidates_by_item = _dry_candidates(parsed, chosen_stores)
        result = split_items(
            candidates_by_item,
            minimums={s: _minimums()[s] for s in chosen_stores},
            max_stops=args.max_stops,
            stop_penalty=args.stop_penalty,
        )
        _print_split(parsed, result)
        return 0

    # Real run: open one persistent context per store, gather real
    # candidates, compute split, fill carts.
    _ensure_playwright_chromium()
    from playwright.sync_api import sync_playwright

    with sync_playwright() as pw:
        store_contexts = {}
        try:
            for handler in handlers:
                store_contexts[handler.slug] = pw.chromium.launch_persistent_context(
                    user_data_dir=str(handler.profile_path()),
                    headless=args.headless,
                )

            candidates_by_item = []
            for line in parsed:
                line_candidates: list[Candidate] = []
                for handler in handlers:
                    products = handler.search_products(store_contexts[handler.slug], line)
                    if products:
                        cheapest = min(products, key=lambda p: p.unit_price)
                        line_candidates.append(Candidate(
                            store=handler.slug,
                            price=cheapest.unit_price,
                            available=cheapest.available,
                            product_name=cheapest.title,
                        ))
                candidates_by_item.append(line_candidates)

            result = split_items(
                candidates_by_item,
                minimums={s: _minimums()[s] for s in chosen_stores},
                max_stops=args.max_stops,
                stop_penalty=args.stop_penalty,
            )
            _print_split(parsed, result)

            # Fill carts.
            for assignment in result.assignments:
                line = parsed[assignment.item_index]
                handler = REGISTRY[assignment.store]
                # Re-search to get the full ProductCandidate (the
                # splitter only kept price; we need product_url).
                products = handler.search_products(
                    store_contexts[assignment.store], line
                )
                if not products:
                    console.print(f"[yellow]skipped:[/yellow] {line.name} ({assignment.store}: no longer found)")
                    continue
                cheapest = min(products, key=lambda p: p.unit_price)
                try:
                    handler.add_to_cart(store_contexts[assignment.store], cheapest)
                    console.print(f"[green]✓[/green] {handler.display_name}: {cheapest.title} (${cheapest.unit_price:.2f})")
                except Exception as exc:
                    console.print(f"[red]✗[/red] {handler.display_name}: {line.name} — {exc}")

            console.print()
            console.print("[bold]Carts ready.[/bold] Each store window is open at its cart page.")
            console.print("Review the items, then click Checkout in each window.")
            console.print("Press Ctrl-C here when you're done.")
            try:
                input()
            except (EOFError, KeyboardInterrupt):
                pass
        finally:
            for context in store_contexts.values():
                context.close()
    return 0


def _resolve_chosen_stores(stores_arg: str | None) -> list[str]:
    if not stores_arg:
        return list(REGISTRY.keys())
    chosen = [s.strip() for s in stores_arg.split(",") if s.strip()]
    bad = [s for s in chosen if s not in REGISTRY]
    if bad:
        raise SystemExit(f"unknown stores: {bad}; valid: {list(REGISTRY)}")
    return chosen


def _dry_candidates(lines: list[GroceryLine], stores: list[str]) -> list[list[Candidate]]:
    """Synthesize plausible candidates without hitting any network. Used
    by `--dry-run` so the user can verify the parser + splitter shape
    before logging into stores."""
    out: list[list[Candidate]] = []
    for line in lines:
        per_item: list[Candidate] = []
        # Synthesize a price spread so the splitter has something to
        # decide between. Real prices come from the live retailer
        # query in the non-dry path.
        base = max(0.99, len(line.name) * 0.4)
        for i, store in enumerate(stores):
            per_item.append(Candidate(
                store=store,
                price=round(base * (1.0 + 0.1 * i), 2),
                available=True,
                product_name=f"(stub) {line.name}",
            ))
        out.append(per_item)
    return out


def _print_split(lines: list[GroceryLine], result: StoreSplit) -> None:
    table = Table(title="Grocery split", show_lines=False)
    table.add_column("Item")
    table.add_column("Qty")
    table.add_column("Store")
    table.add_column("Price", justify="right")
    table.add_column("Product")
    for assignment in result.assignments:
        line = lines[assignment.item_index]
        qty_str = ""
        if line.quantity is not None:
            qty_str = f"{line.quantity:g} {line.unit}".strip()
        elif line.unit:
            qty_str = line.unit
        table.add_row(
            line.name,
            qty_str,
            assignment.store,
            f"${assignment.candidate.price:.2f}",
            assignment.candidate.product_name,
        )
    console.print(table)
    if result.unassigned_indices:
        console.print()
        console.print("[yellow]Unmatched (no store could fulfil):[/yellow]")
        for idx in result.unassigned_indices:
            console.print(f"  - {lines[idx].raw_title}")
    console.print()
    for store, subtotal in sorted(result.per_store_subtotals.items()):
        console.print(f"  {store}: ${subtotal:.2f}")
    console.print(f"[bold]Total: ${result.total:.2f}[/bold]")


# ---------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    _load_env()
    parser = argparse.ArgumentParser(
        prog="simmersmith-shopping",
        description="Drive Aldi/Walmart/Sam's Club/Instacart carts from a SimmerSmith grocery list.",
    )
    parser.add_argument("--list", default=os.environ.get("SIMMERSMITH_REMINDERS_LIST", "SimmerSmith"),
                        help="Apple Reminders list to read (default: SimmerSmith).")
    parser.add_argument("--stores", default=None,
                        help="Comma-separated subset of aldi,walmart,sams_club,instacart.")
    parser.add_argument("--max-stops", type=int, default=int(os.environ.get("SIMMERSMITH_MAX_STOPS", "2")),
                        help="Cap how many stores you're willing to hit (default 2).")
    parser.add_argument("--stop-penalty", type=float, default=5.0,
                        help="Per-extra-stop dollar penalty (default $5).")
    parser.add_argument("--headless", action="store_true",
                        help="Run Playwright headless. Default is headed so you can watch carts fill.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Skip Playwright, print the proposed split with synthesized prices.")
    parser.add_argument("--verbose", "-v", action="store_true")

    sub = parser.add_subparsers(dest="cmd")
    login = sub.add_parser("login", help="Interactive login for a store.")
    login.add_argument("--store", required=True, choices=list(REGISTRY.keys()))

    capture = sub.add_parser(
        "capture",
        help="Walk through search + ADD; dump rendered HTML + ranked selector candidates.",
    )
    capture.add_argument("--store", required=True, choices=list(REGISTRY.keys()))

    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    if args.cmd == "login":
        return cmd_login(args)
    if args.cmd == "capture":
        return cmd_capture(args)
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
