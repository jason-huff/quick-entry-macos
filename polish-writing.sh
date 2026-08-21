#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

RESOURCE_DIR="${QUICK_ENTRY_APP_RESOURCES:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SKILL_PATH="$RESOURCE_DIR/skills/write-without-bullshit/SKILL.md"

DRAFT="$(cat)"
if [[ -z "${DRAFT//[[:space:]]/}" ]]; then
  exit 0
fi

PI_BIN="$(command -v pi || true)"
if [[ -z "$PI_BIN" ]]; then
  echo "Could not find pi on PATH. Install and authenticate Pi first." >&2
  exit 127
fi

if [[ ! -f "$SKILL_PATH" ]]; then
  echo "Could not find the bundled write-without-bullshit skill." >&2
  exit 1
fi

PROMPT_FILE="$(mktemp -t quick-entry-polish-prompt.XXXXXX.md)"
trap 'rm -f "$PROMPT_FILE"' EXIT

cat > "$PROMPT_FILE" <<EOF
Rewrite the draft below into clear, direct communication that is ready to paste into Slack, email, or a team update.

- Put the point, decision, or ask first.
- Use active language and concrete nouns.
- Fix grammar, punctuation, and obvious speech-to-text errors.
- Preserve meaning. Do not invent facts, dates, names, commitments, or urgency.
- Keep it concise. Do not add a greeting, sign-off, headings, diagnosis, or explanation unless the draft clearly needs one.
- Return only the rewritten message.

Draft:
<<<DRAFT
$DRAFT
DRAFT
EOF

args=(
  --print
  --no-tools
  --no-session
  --no-prompt-templates
  --no-context-files
  --thinking "${QUICK_ENTRY_PI_THINKING:-off}"
  --skill "$SKILL_PATH"
)

# Leave model selection to the user's Pi configuration by default. Set
# QUICK_ENTRY_PI_MODEL to pin a model for this lightweight rewrite task.
if [[ -n "${QUICK_ENTRY_PI_MODEL:-}" ]]; then
  args+=(--model "$QUICK_ENTRY_PI_MODEL")
fi

"$PI_BIN" "${args[@]}" "$(cat "$PROMPT_FILE")"
