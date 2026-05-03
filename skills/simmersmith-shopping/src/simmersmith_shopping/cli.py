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

def cmd_login(args: argparse.Namespace) -> int:
    handler = REGISTRY.get(args.store)
    if handler is None:
        console.print(f"[red]unknown store: {args.store}[/red]")
        return 2

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

    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    if args.cmd == "login":
        return cmd_login(args)
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
