#!/usr/bin/env python3
"""Refresh the Quick Entry HyperD Top 3 cache.

The menu-bar app starts this helper when its cache is older than 30 minutes.
It sends the current active Quick Entry tasks plus the latest local daily radar to
Mana for a read-only priority pass, then writes a small local cache for the
native app to render. If Mana is unavailable, it writes a transparent,
deterministic fallback rather than inventing recommendations.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any

HOME = Path.home()
QUICK_ENTRY_ROOT = Path(os.environ.get("QUICK_ENTRY_ROOT", Path(os.environ.get("QUICK_ENTRY_TODO_FILE", str(HOME / "QuickEntry" / "todo-processing.md"))).parent))
TODO_PROCESSING = QUICK_ENTRY_ROOT / "todo-processing.md"
STATE_OF_THE_UNION = QUICK_ENTRY_ROOT / "state-of-the-union.md"
RADAR_DIR = QUICK_ENTRY_ROOT / "radars" / "daily"
CACHE_PATH = QUICK_ENTRY_ROOT / ".cache" / "quick-entry-hyperd.json"
INBOX_REVIEW_PATH = QUICK_ENTRY_ROOT / ".cache" / "quick-entry-inbox-review.json"


class Source:
    OWING = "owing"
    INBOX = "inbox"


def normalize(text: str) -> str:
    return " ".join(text.split())


def todo_id(source: str, text: str) -> str:
    digest = hashlib.sha256(f"{source}|{normalize(text)}".encode("utf-8")).hexdigest()[:16]
    return f"{source}:{digest}"


def task_from_line(source: str, line: str) -> dict[str, str] | None:
    match = re.match(r"^\s*- \[([ xX])\]\s+(.*)$", line)
    if not match or match.group(1).lower() == "x":
        return None
    text = normalize(match.group(2))
    if not text:
        return None
    return {"id": todo_id(source, text), "source": source, "text": text}


def section_tasks(path: Path, source: str, start_heading: str, stop_heading: str | None = None) -> list[dict[str, str]]:
    if not path.is_file():
        return []

    lines = path.read_text(encoding="utf-8").splitlines()
    in_section = False
    tasks: list[dict[str, str]] = []
    for line in lines:
        stripped = line.strip()
        if stripped == start_heading:
            in_section = True
            continue
        if not in_section:
            continue
        if stop_heading and stripped == stop_heading:
            break
        if stripped.startswith("## "):
            break
        task = task_from_line(source, line)
        if task:
            tasks.append(task)
    return tasks


def reviewed_inbox_tasks(inbox: list[dict[str, str]]) -> list[dict[str, str]]:
    if not INBOX_REVIEW_PATH.is_file():
        return inbox
    try:
        review = json.loads(INBOX_REVIEW_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return inbox
    if review.get("mode") != "agent":
        return inbox

    reviewed_by_id = {item.get("id"): item for item in review.get("items", []) if isinstance(item, dict)}
    actionable: list[dict[str, str]] = []
    for task in inbox:
        reviewed = reviewed_by_id.get(task["id"])
        if reviewed is None:
            # A partial review must never hide a possible action.
            actionable.append(task)
            continue
        if reviewed.get("classification") != "todo":
            continue
        cleaned = normalize(str(reviewed.get("text") or task["text"]))
        actionable.append({**task, "text": cleaned or task["text"]})
    return actionable


def candidates() -> list[dict[str, str]]:
    owing = section_tasks(STATE_OF_THE_UNION, Source.OWING, "## Owing")
    inbox = section_tasks(TODO_PROCESSING, Source.INBOX, "## Inbox", "## Processed")
    return owing + reviewed_inbox_tasks(inbox)


def latest_radar() -> tuple[str, str | None]:
    if not RADAR_DIR.is_dir():
        return "", None
    reports = sorted(RADAR_DIR.glob("*.md"), key=lambda path: path.stat().st_mtime, reverse=True)
    if not reports:
        return "", None
    report = reports[0]
    try:
        return report.read_text(encoding="utf-8"), report.name
    except OSError:
        return "", report.name


def prompt_for(candidates_payload: list[dict[str, str]], radar_text: str) -> str:
    task_lines = "\n".join(
        f'- id: "{item["id"]}" | source: {item["source"]} | task: {item["text"]}'
        for item in candidates_payload
    )
    radar_excerpt = radar_text[-12_000:] if radar_text else "No current Retail Daily Radar was found."
    return f"""You are the read-only Quick Entry planner. Choose the three most consequential actions for Jason to make progress on today.

Use only the candidate tasks below and the supplied latest radar. Do not invent a task, create a task, send a message, or modify any file.

Prioritize time-sensitive commitments, the top strategic bet, direct-report/hiring responsibilities, and decisions that unblock others. Avoid duplicate tasks that describe the same action. Keep every reason short and concrete; do not repeat a project/category label from the task.

Return ONLY valid JSON, with no markdown fence or prose, in this exact shape:
{{
  "summary": "one short sentence",
  "items": [
    {{"id": "candidate id exactly as supplied", "why": "6 words or fewer; no tag"}}
  ]
}}

Return between zero and three items. Every id must exactly match a supplied candidate id.

CANDIDATES:
{task_lines or "(No active candidates.)"}

LATEST RADAR:
{radar_excerpt}
"""


def extract_json(output: str) -> dict[str, Any] | None:
    start = output.find("{")
    end = output.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        parsed = json.loads(output[start : end + 1])
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def agent_recommendations(candidates_payload: list[dict[str, str]], radar_text: str) -> tuple[list[dict[str, str]], str] | None:
    """Reserved extension point for optional local AI ranking.

    The open-source app deliberately ships local-only and uses the transparent
    ordering in fallback_recommendations.
    """
    return None


def fallback_recommendations(candidates_payload: list[dict[str, str]]) -> tuple[list[dict[str, str]], str]:
    owing = [item for item in candidates_payload if item["source"] == Source.OWING]
    inbox = [item for item in candidates_payload if item["source"] == Source.INBOX]
    selected: list[dict[str, str]] = []
    for item in (owing + inbox)[:3]:
        why = "Active Owing item" if item["source"] == Source.OWING else "Unprocessed inbox capture"
        selected.append({"id": item["id"], "why": why})
    return selected, "Local priority fallback — agent refresh unavailable."


def write_cache(payload: dict[str, Any]) -> None:
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=CACHE_PATH.parent, delete=False) as temp:
        json.dump(payload, temp, indent=2, ensure_ascii=False)
        temp.write("\n")
        temporary_path = Path(temp.name)
    temporary_path.replace(CACHE_PATH)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fallback", action="store_true", help="Skip Mana and write deterministic priorities.")
    args = parser.parse_args()

    active_candidates = candidates()
    radar_text, radar_name = latest_radar()
    selected: list[dict[str, str]]
    summary: str
    mode = "fallback"

    if not args.fallback:
        agent_result = agent_recommendations(active_candidates, radar_text)
    else:
        agent_result = None

    if agent_result:
        selected, summary = agent_result
        mode = "agent"
    else:
        selected, summary = fallback_recommendations(active_candidates)

    now = dt.datetime.now().astimezone().replace(microsecond=0).isoformat()
    payload = {
        "version": 1,
        "generated_at": now,
        "mode": mode,
        "summary": summary,
        "radar_report": radar_name,
        "items": selected,
    }
    write_cache(payload)
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
