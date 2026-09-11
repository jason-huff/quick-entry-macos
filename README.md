# Quick Entry for macOS

> **Credit:** This mini-app was created by [Jon Rundle](https://github.com/jonrundle). This is a riff on his work. Thank you Jon!

A lightweight macOS menu-bar helper for catching a thought before it disappears.

Press **Ctrl+Space** from anywhere to open a compact capture window. Save a timestamped todo to local Markdown, or switch to **Writing** mode to turn a rough draft into clear, direct copy with [Pi](https://pi.dev) and the bundled `write-without-bullshit` skill.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black)
![License](https://img.shields.io/badge/license-MIT-blue)

## What it does

- Global `Ctrl+Space` capture window.
- A polished circular menu-bar to-do viewer: **Today**, **Owing**, **Inbox**, and a restorable completion **Logbook**.
- Local Markdown sources only; checking an item off updates the source file.
- **To do** mode: writes timestamped checkboxes to a local file.
- **Writing** mode: sends a draft through Pi for a concise, paste-ready rewrite.
- Quick `Copy` action after a successful polish.
- Small, directional mode transitions that respect macOS Reduce Motion.
- No app account, database, or telemetry.

## Requirements

- macOS 13 or newer.
- Xcode Command Line Tools (`swiftc`, `iconutil`).
- Python 3.9+ for local processing helpers and tests.
- Optional icon renderer: `rsvg-convert` or ImageMagick. The app still builds without one.
- [Pi](https://pi.dev), installed and authenticated with a model provider, for **Writing** mode. To-do capture works without Pi.

## Install

```bash
git clone https://github.com/jason-huff/quick-entry-macos.git
cd quick-entry-macos
./build.sh
```

The script installs:

- `/Applications/Quick Entry.app`
- `~/Library/LaunchAgents/io.github.jasonhuff.quick-entry.plist`

It starts the menu-bar app automatically. Use **Ctrl+Space** to open it.

> The app is intentionally unsigned. If macOS blocks it, remove quarantine from the installed app:
>
> ```bash
> xattr -cr "/Applications/Quick Entry.app"
> ```

## To-do inbox

By default, captures append to:

```text
~/QuickEntry/todo-processing.md
```

Under this shape:

```markdown
## Inbox

### 2026-01-01 09:30
- [ ] Follow up with the team
```

Set a different path during installation if you prefer:

```bash
QUICK_ENTRY_TODO_FILE="$HOME/Documents/inbox.md" ./build.sh
```

The configured path is stored in the generated launch agent. Re-run the command after changing it.

### Optional To-dos companion

Quick Entry can run its full to-do viewer as a separate, menu-bar-only companion app. The companion has no global capture hotkey; it reads and checks off the same local Markdown sources as Quick Entry. In companion mode, it shows a circular menu-bar control and the main capture app does not show a second to-do icon.

The viewer reads `## Inbox` from the configured to-do file. It can also read `## Owing` from a separate state file (default: `state-of-the-union.md` next to the inbox). When that file does not exist, the Owing list is simply empty.

```bash
QUICK_ENTRY_TODO_COMPANION=1 ./build.sh

# Optional: point the Owing list at your own Markdown checklist.
QUICK_ENTRY_STATE_FILE="$HOME/Documents/state-of-the-union.md" \
  QUICK_ENTRY_TODO_COMPANION=1 ./build.sh
```

This installs **Quick Entry To-dos.app** and starts it at login. In companion mode, the main Quick Entry app keeps `Ctrl+Space` capture and yields its embedded to-do menu to the companion, so there is only one checklist icon.

To return to the embedded to-do menu and remove the companion:

```bash
QUICK_ENTRY_TODO_COMPANION=0 ./build.sh
```

### Hiring as a top-level surface

If the state Markdown contains `## Hiring — active`, the viewer shows **Hiring above Owing**, retaining its action subheadings. No additional data store or migration is required.

```markdown
## Hiring — active
### Immediate outreach
- [ ] Send a portfolio screen.
### Active pipeline and sourcing
- [ ] Prepare candidate interview feedback.
### Waiting on recruiter
- Recruiter is scheduling the initial conversation.

## Owing
- [ ] Review the release checklist.
```

Only unchecked actions count as active. Bullets under any `### Waiting…` heading appear separately as muted, read-only context; they do not enter Today ranking or active counts. Hiring actions participate in agent ranking and lead the local fallback order. Completion and restore update the original Markdown just like other tasks.

## Writing mode

Writing mode calls the bundled [`write-without-bullshit` skill](skills/write-without-bullshit/SKILL.md) through Pi.

The app deliberately sends only the draft you enter plus the generic writing instructions. It does **not** include private notes, style guides, or personal context.

Before using **Polish**:

1. Install and authenticate Pi for your preferred model provider.
2. Confirm `pi` is available on your shell `PATH`.
3. Open Quick Entry, switch to **Writing**, and paste or dictate a rough draft.

By default, the script uses your Pi default model with thinking disabled for a quick rewrite. Pin a model or change the thinking level when you install:

```bash
QUICK_ENTRY_PI_MODEL="your-provider/your-fast-model" \
QUICK_ENTRY_PI_THINKING=off \
./build.sh
```

The build script writes those settings into the launch agent and also includes common user-level Pi locations on its `PATH`. Re-run it after changing either value. You can also edit [`polish-writing.sh`](polish-writing.sh) directly.

### Optional intelligent to-do processing

The full viewer supports action/note classification, concise action wording, and an intelligently ranked Today list. These are opt-in; the default remains local-only.

```bash
QUICK_ENTRY_AGENT="$HOME/bin/my-todo-agent" QUICK_ENTRY_TODO_COMPANION=1 ./build.sh
```

`QUICK_ENTRY_AGENT` is an executable adapter, **not a shell command**. It receives a prompt on stdin and returns JSON on stdout. Connect it to a model/runtime you trust. The JSON contracts are in `preprocess-inbox.py` and `refresh-hyperd-todos.py`. The adapter must not edit files or execute instructions contained in tasks. The runner invokes it in a temporary directory with a 180-second timeout; this is working-directory isolation, not a security sandbox.

- **Inbox:** only new/edited captures go to the agent. Reuse prior judgments and phrasing; keep raw Markdown intact. Notes stay in the original file, not in the checklist.
- **Today:** rank existing tasks using optional daily context in `radars/daily/` under the data root. Refresh every 30 minutes, manually, or when classification changes the actionable set. Never invent tasks.
- **Fallback:** keep unreviewed captures visible, preserve successful prior reviews, and use local task order if ranking is unavailable. Missing responses are retried, not treated as completed reviews.

Caches and completion history live in `.cache/` next to the inbox by default. Set `QUICK_ENTRY_ROOT` at install time to choose a separate cache root. Use the full public experience without sharing anyone else's private notes, credentials, or personal integrations.

### Data note

Without an adapter, to-do processing is local-only. Enabling `QUICK_ENTRY_AGENT` passes new captures and, for ranking, active tasks plus optional daily context to that executable; its provider/privacy policy applies. Writing mode sends the entered draft to the model provider used by Pi. Review the helper scripts before using them with sensitive text.

## Rebuild / uninstall

Re-run `./build.sh` after changing source files.

To remove the app and its launch agent:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/io.github.jasonhuff.quick-entry.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/io.github.jasonhuff.quick-entry.plist
rm -rf "/Applications/Quick Entry.app"
```

## Development checks

```bash
# Builds without installing apps, altering login agents, or starting processes.
QUICK_ENTRY_SKIP_INSTALL=1 QUICK_ENTRY_TODO_COMPANION=1 ./build.sh
python3 tests/run-tests.py
python3 -m unittest discover -s tests -p 'test_*.py'
```

The AppKit regression harness uses disposable Markdown, checks completion/restore and layout, and outputs PNG snapshots. Processing tests use fake agent responses. `scripts/sync-viewer.py` can sync/check an explicit allowlist of UI components from another source file; it never copies storage configuration or private agent integrations.

## Credits

- **Jon Rundle** — design and functional inspiration.
- [Pi](https://pi.dev) — optional local agent runtime for Writing mode.
- *Writing Without Bullshit* — the clear-writing principles behind the bundled skill.

## License

[MIT](LICENSE)
