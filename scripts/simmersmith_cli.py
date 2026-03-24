#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any
from urllib import error as urllib_error
from urllib import request as urllib_request


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASE_URL = os.environ.get("SIMMERSMITH_BASE_URL", "http://localhost:8080")


def dump_output(payload: Any, pretty: bool) -> None:
    if pretty:
        print(json.dumps(payload, indent=2, sort_keys=True, default=str))
        return
    print(json.dumps(payload, default=str))


def load_payload(path: str) -> Any:
    return json.loads(Path(path).read_text())


def request(method: str, path: str, base_url: str, payload: Any | None = None) -> Any:
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    url = f"{base_url.rstrip('/')}{path}"
    req = urllib_request.Request(
        url,
        data=body,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib_request.urlopen(req, timeout=120.0) as response:
            content = response.read()
            status = response.status
    except urllib_error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            detail = json.loads(raw)
        except Exception:
            detail = raw
        raise SystemExit(f"{exc.code} {path}: {detail}") from exc

    if status >= 400:
        raise SystemExit(f"{status} {path}: request failed")
    if not content:
        return {}
    return json.loads(content.decode("utf-8"))


def wait_for_health(base_url: str, attempts: int = 30, delay: float = 2.0) -> None:
    for _ in range(attempts):
        try:
            payload = request("GET", "/api/health", base_url)
        except SystemExit:
            payload = None
        if payload and payload.get("status") == "ok":
            return
        time.sleep(delay)
    raise SystemExit("App did not become healthy in time.")


def command_start(args: argparse.Namespace) -> Any:
    command = ["docker", "compose", "up", "-d"]
    if args.build:
        command.append("--build")
    subprocess.run(command, cwd=REPO_ROOT, check=True)
    wait_for_health(args.base_url)
    return {"status": "started", "base_url": args.base_url}


def command_check(args: argparse.Namespace) -> Any:
    return request("GET", "/api/health", args.base_url)


def command_current_week(args: argparse.Namespace) -> Any:
    return request("GET", "/api/weeks/current", args.base_url)


def command_create_week(args: argparse.Namespace) -> Any:
    return request(
        "POST",
        "/api/weeks",
        args.base_url,
        payload={"week_start": args.week_start, "notes": args.notes},
    )


def command_apply_draft(args: argparse.Namespace) -> Any:
    payload = load_payload(args.payload)
    return request("POST", f"/api/weeks/{args.week_id}/draft-from-ai", args.base_url, payload=payload)


def command_update_meals(args: argparse.Namespace) -> Any:
    payload = load_payload(args.payload)
    return request("PUT", f"/api/weeks/{args.week_id}/meals", args.base_url, payload=payload)


def command_approve_week(args: argparse.Namespace) -> Any:
    return request("POST", f"/api/weeks/{args.week_id}/approve", args.base_url, payload={})


def command_ready_week(args: argparse.Namespace) -> Any:
    return request("POST", f"/api/weeks/{args.week_id}/ready-for-ai", args.base_url, payload={})


def command_regenerate_grocery(args: argparse.Namespace) -> Any:
    return request("POST", f"/api/weeks/{args.week_id}/grocery/regenerate", args.base_url, payload={})


def command_import_pricing(args: argparse.Namespace) -> Any:
    payload = load_payload(args.payload)
    return request("POST", f"/api/weeks/{args.week_id}/pricing/import", args.base_url, payload=payload)


def command_profile(args: argparse.Namespace) -> Any:
    return request("GET", "/api/profile", args.base_url)


def command_recipes(args: argparse.Namespace) -> Any:
    return request("GET", "/api/recipes", args.base_url)


def command_preferences(args: argparse.Namespace) -> Any:
    return request("GET", "/api/preferences", args.base_url)


def command_week_changes(args: argparse.Namespace) -> Any:
    return request("GET", f"/api/weeks/{args.week_id}/changes", args.base_url)


def command_week_feedback(args: argparse.Namespace) -> Any:
    return request("GET", f"/api/weeks/{args.week_id}/feedback", args.base_url)


def command_save_week_feedback(args: argparse.Namespace) -> Any:
    payload = load_payload(args.payload)
    return request("POST", f"/api/weeks/{args.week_id}/feedback", args.base_url, payload=payload)


def command_week_exports(args: argparse.Namespace) -> Any:
    return request("GET", f"/api/weeks/{args.week_id}/exports", args.base_url)


def command_create_export(args: argparse.Namespace) -> Any:
    return request(
        "POST",
        f"/api/weeks/{args.week_id}/exports",
        args.base_url,
        payload={"destination": args.destination, "export_type": args.export_type},
    )


def command_export_detail(args: argparse.Namespace) -> Any:
    return request("GET", f"/api/exports/{args.export_id}", args.base_url)


def command_complete_export(args: argparse.Namespace) -> Any:
    return request(
        "POST",
        f"/api/exports/{args.export_id}/complete",
        args.base_url,
        payload={"status": args.status, "external_ref": args.external_ref, "error": args.error},
    )


def command_save_preferences(args: argparse.Namespace) -> Any:
    payload = load_payload(args.payload)
    return request("POST", "/api/preferences", args.base_url, payload=payload)


def command_score_meal(args: argparse.Namespace) -> Any:
    payload = load_payload(args.payload)
    return request("POST", "/api/preferences/score-meal", args.base_url, payload=payload)


def applescript_string(value: str) -> str:
    normalized = value.replace("\r\n", "\n").replace("\r", "\n")
    parts = normalized.split("\n")
    rendered_parts = []
    for part in parts:
        escaped = part.replace("\\", "\\\\").replace('"', '\\"')
        rendered_parts.append(f'"{escaped}"')
    return " & linefeed & ".join(rendered_parts) if rendered_parts else '""'


def run_osascript(script: str) -> str:
    completed = subprocess.run(
        ["osascript"],
        input=script,
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or completed.stdout.strip() or "osascript failed")
    return completed.stdout.strip()


def build_reminders_script(payload: dict[str, Any], *, replace_lists: bool) -> str:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for item in sorted(payload.get("items", []), key=lambda row: (row.get("list_name", ""), row.get("sort_order", 0))):
        list_name = str(item.get("list_name") or "Reminders")
        grouped.setdefault(list_name, []).append(item)

    lines = ['tell application "Reminders"']
    for list_name, items in grouped.items():
        list_expr = applescript_string(list_name)
        lines.extend(
            [
                f"if not (exists list {list_expr}) then",
                f"  make new list with properties {{name:{list_expr}}}",
                "end if",
                f"set targetList to list {list_expr}",
            ]
        )
        if replace_lists:
            lines.append("delete every reminder of targetList")
        for item in items:
            title_expr = applescript_string(str(item.get("title") or ""))
            notes_expr = applescript_string(str(item.get("notes") or ""))
            lines.append(
                "make new reminder at end of reminders of targetList "
                f"with properties {{name:{title_expr}, body:{notes_expr}}}"
            )
    lines.append('end tell')
    return "\n".join(lines)


def command_run_reminders_export(args: argparse.Namespace) -> Any:
    payload = request("GET", f"/api/exports/{args.export_id}/apple-reminders", args.base_url)
    try:
        run_osascript(build_reminders_script(payload, replace_lists=args.replace_lists))
        external_ref = ", ".join(sorted({str(item.get('list_name') or 'Reminders') for item in payload.get("items", [])}))
        return request(
            "POST",
            f"/api/exports/{args.export_id}/complete",
            args.base_url,
            payload={"status": "completed", "external_ref": external_ref, "error": ""},
        )
    except RuntimeError as exc:
        if not args.skip_failure_callback:
            request(
                "POST",
                f"/api/exports/{args.export_id}/complete",
                args.base_url,
                payload={"status": "failed", "external_ref": "", "error": str(exc)},
            )
        raise SystemExit(str(exc))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Operator CLI for the local simmersmith app.")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="SimmerSmith base URL")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    subparsers = parser.add_subparsers(dest="command", required=True)

    start = subparsers.add_parser("start", help="Start the local Dockerized app")
    start.add_argument("--build", action="store_true", help="Rebuild the image before starting")
    start.set_defaults(func=command_start)

    check = subparsers.add_parser("check", help="Check app health")
    check.set_defaults(func=command_check)

    current_week = subparsers.add_parser("current-week", help="Read the current week")
    current_week.set_defaults(func=command_current_week)

    create_week = subparsers.add_parser("create-week", help="Create or fetch a planning week")
    create_week.add_argument("--week-start", required=True, help="Week start date (YYYY-MM-DD)")
    create_week.add_argument("--notes", default="", help="Optional week notes")
    create_week.set_defaults(func=command_create_week)

    apply_draft = subparsers.add_parser("apply-draft", help="Apply an AI-generated draft payload")
    apply_draft.add_argument("--week-id", required=True, help="Week identifier")
    apply_draft.add_argument("--payload", required=True, help="Path to JSON draft payload")
    apply_draft.set_defaults(func=command_apply_draft)

    update_meals = subparsers.add_parser("update-meals", help="Apply scoped meal updates")
    update_meals.add_argument("--week-id", required=True, help="Week identifier")
    update_meals.add_argument("--payload", required=True, help="Path to JSON meal update payload")
    update_meals.set_defaults(func=command_update_meals)

    approve_week = subparsers.add_parser("approve-week", help="Finalize the current meal plan")
    approve_week.add_argument("--week-id", required=True, help="Week identifier")
    approve_week.set_defaults(func=command_approve_week)

    ready_week = subparsers.add_parser("ready-week", help="Mark a week ready for chat/AI finalization")
    ready_week.add_argument("--week-id", required=True, help="Week identifier")
    ready_week.set_defaults(func=command_ready_week)

    regenerate = subparsers.add_parser("regenerate-grocery", help="Rebuild the grocery list")
    regenerate.add_argument("--week-id", required=True, help="Week identifier")
    regenerate.set_defaults(func=command_regenerate_grocery)

    import_pricing = subparsers.add_parser("import-pricing", help="Import externally scraped pricing results")
    import_pricing.add_argument("--week-id", required=True, help="Week identifier")
    import_pricing.add_argument("--payload", required=True, help="Path to JSON pricing payload")
    import_pricing.set_defaults(func=command_import_pricing)

    profile = subparsers.add_parser("profile", help="Read profile settings and staples")
    profile.set_defaults(func=command_profile)

    recipes = subparsers.add_parser("recipes", help="Read the saved recipe library")
    recipes.set_defaults(func=command_recipes)

    preferences = subparsers.add_parser("preferences", help="Read stored taste preferences and planning rules")
    preferences.set_defaults(func=command_preferences)

    week_changes = subparsers.add_parser("week-changes", help="Read recorded week change history")
    week_changes.add_argument("--week-id", required=True, help="Week identifier")
    week_changes.set_defaults(func=command_week_changes)

    week_feedback = subparsers.add_parser("week-feedback", help="Read structured week feedback entries")
    week_feedback.add_argument("--week-id", required=True, help="Week identifier")
    week_feedback.set_defaults(func=command_week_feedback)

    save_week_feedback = subparsers.add_parser("save-week-feedback", help="Upsert week feedback entries from JSON")
    save_week_feedback.add_argument("--week-id", required=True, help="Week identifier")
    save_week_feedback.add_argument("--payload", required=True, help="Path to JSON feedback payload")
    save_week_feedback.set_defaults(func=command_save_week_feedback)

    week_exports = subparsers.add_parser("week-exports", help="Read queued export runs for a week")
    week_exports.add_argument("--week-id", required=True, help="Week identifier")
    week_exports.set_defaults(func=command_week_exports)

    create_export = subparsers.add_parser("create-export", help="Queue an export run for a week")
    create_export.add_argument("--week-id", required=True, help="Week identifier")
    create_export.add_argument("--export-type", choices=["meal_plan", "shopping_split"], required=True)
    create_export.add_argument("--destination", choices=["apple_reminders"], default="apple_reminders")
    create_export.set_defaults(func=command_create_export)

    export_detail = subparsers.add_parser("export-detail", help="Read a single export run")
    export_detail.add_argument("--export-id", required=True, help="Export run identifier")
    export_detail.set_defaults(func=command_export_detail)

    complete_export = subparsers.add_parser("complete-export", help="Mark an export run completed or failed")
    complete_export.add_argument("--export-id", required=True, help="Export run identifier")
    complete_export.add_argument("--status", choices=["completed", "failed"], default="completed")
    complete_export.add_argument("--external-ref", default="", help="External list or system reference")
    complete_export.add_argument("--error", default="", help="Failure detail when marking an export failed")
    complete_export.set_defaults(func=command_complete_export)

    run_reminders_export = subparsers.add_parser(
        "run-reminders-export",
        help="Execute a queued Apple Reminders export on the host and mark it complete",
    )
    run_reminders_export.add_argument("--export-id", required=True, help="Export run identifier")
    run_reminders_export.add_argument(
        "--replace-lists",
        action="store_true",
        help="Clear the target Reminders lists before writing the exported items",
    )
    run_reminders_export.add_argument(
        "--skip-failure-callback",
        action="store_true",
        help="Do not mark the export failed if local Reminders automation errors",
    )
    run_reminders_export.set_defaults(func=command_run_reminders_export)

    save_preferences = subparsers.add_parser("save-preferences", help="Upsert taste preference signals from JSON")
    save_preferences.add_argument("--payload", required=True, help="Path to JSON preference payload")
    save_preferences.set_defaults(func=command_save_preferences)

    score_meal = subparsers.add_parser("score-meal", help="Score a meal candidate against stored preferences")
    score_meal.add_argument("--payload", required=True, help="Path to JSON score request payload")
    score_meal.set_defaults(func=command_score_meal)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    result = args.func(args)
    dump_output(result, args.pretty)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
