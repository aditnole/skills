---
name: statusline
description: Install or customize a compact, width-aware Claude Code status line showing model, context usage (bar + tokens + compact warning), 5h/7d usage limits with burn-pace prediction, git branch state, PR + CI status, cost, and parallel sessions. Use when the user asks to set up, install, restore, or tweak their Claude Code status line / statusbar.
---

# Claude Code status line

Installs `statusline.sh` (bundled next to this file) as the user's Claude Code status line.

## What it shows

One line, items in priority order. When the terminal is too narrow, lower-priority items are dropped from the end, so the line never wraps.

```
Opus 5.5 · ctx ████████░░ 84% 168k ⚠compact · 5h 63%▲ ↻3h20m · main↑2↓1 ●1 ✚3 ?1 · #42✓ approved · 7d 21% · $3.41 · ⧉3(2 busy) · repo · 1h05m
```

| Item | Meaning |
|---|---|
| model | Current model display name |
| `ctx` | Context window: bar, %, tokens used. Yellow ≥60%, red ≥80%. `compact soon` at 65%, `⚠compact` at 80% |
| `5h` / `7d` | Subscription usage limits. `▲` red = on pace to run out before reset, `~` yellow = on pace for ≥85%. `↻` = time until 5h reset |
| git | Branch, `[wt]` if worktree, `↑ahead ↓behind`, `●staged ✚modified ?untracked` |
| PR | `#num` with CI `✓ ✗ ⏳` and review status. Fetched via `gh` in the background, cached 60s |
| `$` | Session cost |
| `⧉N` | Live Claude sessions on this machine (shown only if >1). Red `!name same dir` if another session shares this folder |
| repo / time | Repo name and session duration (lowest priority) |

Missing data is skipped silently: for example, the usage limits only appear on Pro/Max plans.

## Install

1. Check dependencies: `jq` is required. `gh` (authenticated) is optional and enables PR/CI status. `git` is optional.
2. Copy the script and make it executable:
   ```bash
   cp "<this skill dir>/statusline.sh" ~/.claude/statusline.sh && chmod +x ~/.claude/statusline.sh
   ```
   If `~/.claude/statusline.sh` already exists and differs, show the user the diff and confirm before overwriting.
3. Merge the setting into `~/.claude/settings.json` without clobbering other keys:
   ```bash
   tmp=$(mktemp) && jq '.statusLine = {"type":"command","command":"~/.claude/statusline.sh","padding":0}' ~/.claude/settings.json > "$tmp" && mv "$tmp" ~/.claude/settings.json
   ```
   (If settings.json does not exist, create it with `{}` first.) If a different `statusLine` is already configured, confirm with the user before replacing it.
4. Smoke-test with sample input:
   ```bash
   now=$(date +%s); echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$PWD"'"},"context_window":{"used_percentage":42,"context_window_size":200000},"cost":{"total_cost_usd":1.2,"total_duration_ms":600000},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":'$((now+9000))'}}}' | COLUMNS=140 ~/.claude/statusline.sh
   ```
5. Tell the user it appears on the next status line refresh (restart Claude Code if needed).

## Customize

All in `~/.claude/statusline.sh`:

- **Order / which items show:** edit the `for seg in ...` priority list near the bottom.
- **Thresholds:** `color_for "$p" 60 80` (context colors), the `65`/`80` compact-warning checks, and `85`/`100` in `limit()` for the pace warnings.
- **Width:** uses `$COLUMNS`, then `stty size </dev/tty`, and falls back to 120. If the line still wraps, hardcode `width=<n>`.
- **PR cache TTL:** the `-gt 60` check in the gh block. Cache files live in `~/.claude/cache/statusline/`.
