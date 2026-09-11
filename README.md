# Quick Entry for macOS

> **Credit:** This mini-app was created by [Jon Rundle](https://github.com/jonrundle). This is a riff on his work. Thank you Jon!

A lightweight macOS menu-bar helper for catching a thought before it disappears.

Press **Ctrl+Space** from anywhere to open a compact capture window. Save a timestamped todo to local Markdown, or switch to **Writing** mode to turn a rough draft into clear, direct copy with [Pi](https://pi.dev) and the bundled `write-without-bullshit` skill.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black)
![License](https://img.shields.io/badge/license-MIT-blue)

## What it does

- Global `Ctrl+Space` capture window.
- Local Markdown todo inbox with a menu-bar view of open items.
- **To do** mode: writes timestamped checkboxes to a local file.
- **Writing** mode: sends a draft through Pi for a concise, paste-ready rewrite.
- Quick `Copy` action after a successful polish.
- Small, directional mode transitions that respect macOS Reduce Motion.
- No app account, database, or telemetry.

## Requirements

- macOS 13 or newer.
- Xcode Command Line Tools (`swiftc`, `iconutil`).
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

Quick Entry can run its to-do surface as a separate, menu-bar-only companion app. The companion has no global capture hotkey; it reads and checks off the same local Markdown file as Quick Entry.

```bash
QUICK_ENTRY_TODO_COMPANION=1 ./build.sh
```

This installs **Quick Entry To-dos.app** and starts it at login. In companion mode, the main Quick Entry app keeps `Ctrl+Space` capture and yields its embedded to-do menu to the companion, so there is only one checklist icon.

To return to the embedded to-do menu and remove the companion:

```bash
QUICK_ENTRY_TODO_COMPANION=0 ./build.sh
```

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

### Data note

To-do mode is local-only. Writing mode sends the entered draft to whichever model provider your Pi installation uses. Read and edit [`polish-writing.sh`](polish-writing.sh) before using it with sensitive text.

## Rebuild / uninstall

Re-run `./build.sh` after changing source files.

To remove the app and its launch agent:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/io.github.jasonhuff.quick-entry.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/io.github.jasonhuff.quick-entry.plist
rm -rf "/Applications/Quick Entry.app"
```

## Credits

- **Jon Rundle** — design and functional inspiration.
- [Pi](https://pi.dev) — optional local agent runtime for Writing mode.
- *Writing Without Bullshit* — the clear-writing principles behind the bundled skill.

## License

[MIT](LICENSE)
