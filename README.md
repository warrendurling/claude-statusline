# claude-statusline

A cost-aware status line for [Claude Code](https://claude.com/claude-code). Shows live context usage plus per-model token counts and real dollar spend for the session — including everything spent by subagents.

```
~/my/project  |  main          ctx ████████░░   165k/200k  82%
                            sonnet ████░░░░░░    98k:12.4M  44%  $9.64
                            fable  █████░░░░░    60k:8.8M   55%  $12.3
```

- **ctx** — tokens currently in the context window, gauged against a 200k early-warning threshold (green → yellow → red). Independent of the model's real window and auto-compaction.
- **Model lines** — one per model used this session, `out:in` (tokens written : total tokens read, including cache). Bars and percentages track **dollar share**, not tokens, so an expensive model with few tokens still shows as the big spender.
- **$** — actual cost: input + output + cache reads (0.1×) + cache writes (1.25× 5m / 2× 1h), at per-model rates.
- **Subagent-aware** — follows task output files referenced in the transcript (recursively, for nested subagents) so delegated work is counted too.

## Install

Requires `jq` and bash.

```bash
curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/warrendurling/claude-statusline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"$HOME/.claude/statusline.sh\""
  }
}
```

## Tweaks

- `gauge_denom` — the context early-warning threshold (default 200000).
- Per-model `$/M` rates live in the `model_rates()` function — one place to edit when pricing changes.

## Notes

- Works on macOS's stock bash 3.2 (no `mapfile`, no associative arrays).
- Right-alignment uses braille blank characters (U+2800) because the renderer trims leading whitespace.
- Costs are estimates computed from transcript usage data at hardcoded rates — close, not billing-grade.
