#!/usr/bin/env python3
"""Conservatively classify Quick Entry captures before they reach the todo UI.

Raw captures stay untouched in the configured Markdown inbox. This helper
writes a local review cache used by the native menu.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any

HOME = Path.home()
TODO_PATH = Path(os.environ.get("QUICK_ENTRY_TODO_FILE", str(HOME / "QuickEntry" / "todo-processing.md")))
QUICK_ENTRY_ROOT = Path(os.environ.get("QUICK_ENTRY_ROOT", str(TODO_PATH.parent)))
CACHE_PATH = QUICK_ENTRY_ROOT / ".cache" / "quick-entry-inbox-review.json"
MAX_CAPTURES = 160


def normalize(text: str) -> str:
    return " ".join(text.split())


def todo_id(text: str) -> str:
    digest = hashlib.sha256(f"inbox|{normalize(text)}".encode("utf-8")).hexdigest()[:16]
    return f"inbox:{digest}"


def inbox_captures() -> list[dict[str, str | None]]:
    if not TODO_PATH.is_file():
        return []

    captures: list[dict[str, str | None]] = []
    in_inbox = False
    timestamp: str | None = None
    for line in TODO_PATH.read_text(encoding="utf-8").splitlines():
        trimmed = line.strip()
        if trimmed == "## Inbox":
            in_inbox = True
            continue
        if trimmed == "## Processed":
            break
        if not in_inbox:
            continue
        if line.startswith("### "):
            timestamp = line[4:].strip()
            continue
        match = re.match(r"^- \[ \] (.+)$", trimmed)
        if not match:
            continue
        text = match.group(1).strip()
        if text:
            captures.append({"id": todo_id(text), "timestamp": timestamp, "text": text})
    return captures


def extract_json(output: str) -> dict[str, Any] | None:
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", output, flags=re.DOTALL)
    candidates = [fenced.group(1)] if fenced else []
    first, last = output.find("{"), output.rfind("}")
    if first >= 0 and last > first:
        candidates.append(output[first : last + 1])
    for candidate in candidates:
        try:
            decoded = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(decoded, dict):
            return decoded
    return None


def agent_review(captures: list[dict[str, str | None]]) -> list[dict[str, str]] | None:
    """Reserved extension point for optional local AI triage.

    The open-source app deliberately ships local-only and returns None, which
    keeps every capture visible in the Inbox.
    """
    return None


def fallback_review(captures: list[dict[str, str | None]]) -> list[dict[str, str]]:
    return [{"id": str(capture["id"]), "classification": "todo", "text": str(capture["text"])} for capture in captures]


def preserve_previous_agent_review(captures: list[dict[str, str | None]]) -> dict[str, Any] | None:
    """Keep a successful prior cleanup visible through a transient agent failure."""
    if not CACHE_PATH.is_file():
        return None
    try:
        previous = json.loads(CACHE_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if previous.get("mode") != "agent" or not isinstance(previous.get("items"), list):
        return None

    valid_ids = {str(capture["id"]) for capture in captures}
    items = [
        item for item in previous["items"]
        if isinstance(item, dict) and item.get("id") in valid_ids
    ]
    if not items and captures:
        return None

    previous["generated_at"] = dt.datetime.now().astimezone().replace(microsecond=0).isoformat()
    previous["raw_count"] = len(captures)
    previous["non_actionable_count"] = sum(1 for item in items if item.get("classification") == "note")
    previous["items"] = items
    return previous


def write_cache(payload: dict[str, Any]) -> None:
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=CACHE_PATH.parent, delete=False) as temp:
        json.dump(payload, temp, ensure_ascii=False, indent=2)
        temp.write("\n")
        temporary = Path(temp.name)
    temporary.replace(CACHE_PATH)


def main() -> int:
    captures = inbox_captures()
    reviewed = agent_review(captures)
    if reviewed is None:
        previous = preserve_previous_agent_review(captures)
        if previous is not None:
            write_cache(previous)
            print(json.dumps(previous, ensure_ascii=False))
            return 0

    mode = "agent" if reviewed is not None else "fallback"
    items = reviewed if reviewed is not None else fallback_review(captures)
    non_actionable = sum(1 for item in items if item["classification"] == "note")
    payload = {
        "version": 1,
        "generated_at": dt.datetime.now().astimezone().replace(microsecond=0).isoformat(),
        "mode": mode,
        "raw_count": len(captures),
        "non_actionable_count": non_actionable,
        "items": items,
    }
    write_cache(payload)
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
