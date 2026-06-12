# CodexBar

CodexBar is a tiny native macOS menu bar app for Apple Silicon. It reads the
local Codex login at `~/.codex/auth.json`, then fetches Codex profile and quota
data from ChatGPT's Codex backend.

## Features

- Menu bar icon with an anchored macOS 26 liquid-glass panel.
- Profile header with avatar, username, and subscription tier.
- Segmented remaining-quota bars for the 5-hour and 7-day Codex windows.
- Background refresh every 5 minutes, plus a refresh when opening the panel.
- Token refresh support using the same ChatGPT OAuth client ID embedded in
  Codex CLI.

The menu bar mark uses the OpenAI brand icon SVG path from Bootstrap Icons.

## Build

```bash
scripts/build-app.sh
```

The packaged app is written to:

```text
dist/CodexBar.app
```

Run it with:

```bash
open dist/CodexBar.app
```

Build a release DMG with:

```bash
scripts/build-dmg.sh 1.0
```

The DMG is written to:

```text
release/CodexBar-1.0-arm64.dmg
```

If the panel reports an auth error, run `codex login` and open the app again.
