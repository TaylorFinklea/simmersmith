"""Read the household grocery list from Apple Reminders.

Two paths:
- **PyXA** (preferred when available on macOS 14+): direct EventKit
  bridge through `pyxa.Application("Reminders")`.
- **osascript fallback**: shells out to AppleScript for hosts where
  PyXA isn't installable. Slower but ubiquitous.

Either way, returns the same `[(title, completed)]` shape so callers
don't need to care which backend produced it.
"""
from __future__ import annotations

import json
import logging
import platform
import subprocess
from typing import Iterable


log = logging.getLogger(__name__)


def read_list(name: str) -> list[tuple[str, bool]]:
    """Return `[(title, completed)]` for every reminder in the named list.
    Raises `RemindersAccessError` when the host can't access Reminders.
    """
    if platform.system() != "Darwin":
        raise RemindersAccessError(
            "Apple Reminders is macOS-only. Run this skill on the user's Mac."
        )

    try:
        return _read_with_pyxa(name)
    except _PyXAUnavailable as exc:
        log.debug("PyXA unavailable, falling back to osascript: %s", exc)
        return _read_with_osascript(name)


class RemindersAccessError(RuntimeError):
    """Raised when the skill can't read Reminders — usage description
    missing, automation permission denied, list not found, etc."""


class _PyXAUnavailable(RuntimeError):
    """Internal sentinel — caller decides whether to fall back."""


def _read_with_pyxa(list_name: str) -> list[tuple[str, bool]]:
    try:
        import PyXA  # type: ignore
    except ImportError as exc:
        raise _PyXAUnavailable(str(exc)) from exc

    try:
        reminders_app = PyXA.Application("Reminders")
        target = None
        for lst in reminders_app.lists():
            if str(lst.name).strip().lower() == list_name.strip().lower():
                target = lst
                break
        if target is None:
            raise RemindersAccessError(
                f"No Reminders list named {list_name!r}. "
                f"Pick or create it in the SimmerSmith iOS Settings → Grocery."
            )
        rows: list[tuple[str, bool]] = []
        for reminder in target.reminders():
            rows.append((str(reminder.name), bool(reminder.completed)))
        return rows
    except Exception as exc:
        # Permission denial surfaces as an AEKit error here — bubble up
        # with a helpful message rather than the raw PyXA stack.
        raise RemindersAccessError(
            f"Could not read Reminders list {list_name!r}: {exc}. "
            f"Grant terminal automation access in System Settings → "
            f"Privacy & Security → Automation."
        ) from exc


def _read_with_osascript(list_name: str) -> list[tuple[str, bool]]:
    script = (
        'tell application "Reminders"\n'
        f'    set targetList to first list whose name is "{_escape(list_name)}"\n'
        '    set out to {}\n'
        '    repeat with r in (reminders of targetList)\n'
        '        set end of out to {name of r, completed of r}\n'
        '    end repeat\n'
        '    return out\n'
        'end tell\n'
    )
    proc = subprocess.run(
        ["/usr/bin/osascript", "-e", script],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.strip()
        if "User canceled" in stderr or "not authorized" in stderr.lower():
            raise RemindersAccessError(
                "Reminders access denied. Grant Terminal access via "
                "System Settings → Privacy & Security → Automation."
            )
        if "Can't get list" in stderr or "list whose name" in stderr:
            raise RemindersAccessError(
                f"No Reminders list named {list_name!r}."
            )
        raise RemindersAccessError(f"osascript failed: {stderr}")

    return list(_parse_osascript_output(proc.stdout))


def _parse_osascript_output(raw: str) -> Iterable[tuple[str, bool]]:
    """osascript returns AppleScript records as comma-separated tokens
    inside braces. We don't try to be a full AppleScript parser — we
    pair them up: every reminder produces (name, true|false).
    """
    text = raw.strip()
    if not text:
        return
    # Strip the outermost braces.
    if text.startswith("{") and text.endswith("}"):
        text = text[1:-1]
    # Split on ", " which separates the FIELDS, then re-pair.
    tokens = [tok.strip() for tok in text.split(", ")]
    if len(tokens) % 2 != 0:
        log.warning("osascript output had odd token count; trimming last token: %s", tokens[-1])
        tokens = tokens[:-1]
    for i in range(0, len(tokens), 2):
        name = tokens[i].strip()
        completed_text = tokens[i + 1].strip().lower()
        yield (name, completed_text == "true")


def _escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


# Convenience for `python -m simmersmith_shopping.reminders SimmerSmith`
def _main() -> int:
    import sys

    if len(sys.argv) < 2:
        print("usage: python -m simmersmith_shopping.reminders <list-name>")
        return 2
    rows = read_list(sys.argv[1])
    print(json.dumps([{"title": t, "completed": c} for t, c in rows], indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
