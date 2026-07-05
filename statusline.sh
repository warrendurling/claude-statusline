#!/usr/bin/env bash
# Claude Code status line — git-aware
# Receives JSON via stdin

input=$(cat)

# --- Extract fields ---
cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // ""')
# Live context tokens (current window contents, not cumulative). Gauge against a
# custom 200k denominator for an early-warning bar — independent of the model's
# real 1M window and auto-compaction, which are left untouched.
used_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
gauge_denom=200000

# --- Directory: shorten home to ~ ---
display_dir="${cwd/#$HOME/~}"

# --- Git branch (skip optional lock, suppress errors) ---
git_branch=""
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi

# --- Terminal width for right-alignment (fall back if no tty) ---
# Safety margin of 6: renderer draws inside a padded frame, so the detected
# width overstates usable columns — right edge otherwise clips off-screen.
term_width=$( (stty size </dev/tty) 2>/dev/null | awk '{print $2}')
[ -z "$term_width" ] && term_width=${COLUMNS:-100}
term_width=$((term_width - 3))

# --- Context progress bar (against custom gauge_denom) ---
context_str=""
ctx_vis=0
if [ -n "$used_tokens" ]; then
  used_int=$((used_tokens * 100 / gauge_denom))
  # Bar fills to 100% of the gauge, but can read >100% if context exceeds it.
  if [ "$used_int" -ge 80 ]; then
    ctx_color="\033[31m"   # red
  elif [ "$used_int" -ge 50 ]; then
    ctx_color="\033[33m"   # yellow
  else
    ctx_color="\033[32m"   # green
  fi
  filled=$((used_int / 10))
  [ "$filled" -gt 10 ] && filled=10
  empty=$((10 - filled))
  bar=""
  for ((i=0; i<filled; i++)); do bar="${bar}█"; done
  for ((i=0; i<empty; i++)); do bar="${bar}░"; done
  used_k=$((used_tokens / 1000))
  denom_k=$((gauge_denom / 1000))
  # Fixed fields (label 6, bar 10, nums 9, pct 4) — visible width computed by
  # parts because bar glyphs are multibyte (${#} would miscount them).
  # Mirror model-line field widths (nums 11, pct 4, blank 6 where cost sits)
  # so the ctx bar lands in the same column as the model bars.
  ctx_nums=$(printf '%11s' "${used_k}k/${denom_k}k")
  ctx_pct=$(printf '%4s' "${used_int}%")
  context_str=$(printf "${ctx_color}%-6s %s %s %s %6s\033[0m" "ctx" "$bar" "$ctx_nums" "$ctx_pct" "")
  ctx_vis=$((6 + 1 + 10 + 1 + 11 + 1 + 4 + 1 + 6))
fi

# --- Per-model output tokens this session ---
# cost_str below is actual $ spend: input + output + cache read (0.1x) +
# cache write (1.25x for 5m TTL, 2x for 1h TTL).
transcript=$(echo "$input" | jq -r '.transcript_path // empty')
model_lines=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # Subagent usage logs to separate task files under the session scratchpad.
  # Task dir uuid differs from the transcript filename, so derive paths from
  # output_file refs embedded in the transcript's tool-result JSON instead of globbing.
  # macOS bash 3.2 has no mapfile; paths contain no spaces, so word-split is safe
  task_files=($(grep -ho 'output_file: [^"[:space:]\\]*\.output' "$transcript" 2>/dev/null | sed 's/^output_file: //' | sort -u))
  # Recurse: nested subagents write output_file refs inside first-level task
  # files, never scanned by a single grep pass. Loop until no new files found.
  for _ in 1 2 3 4 5; do
    [ "${#task_files[@]}" -eq 0 ] && break
    new_files=($(grep -ho 'output_file: [^"[:space:]\\]*\.output' "${task_files[@]}" 2>/dev/null | sed 's/^output_file: //' | sort -u))
    combined=($(printf '%s\n' "${task_files[@]}" "${new_files[@]}" | sort -u))
    [ "${#combined[@]}" -eq "${#task_files[@]}" ] && break
    task_files=("${combined[@]}")
  done
  model_data=$(cat "$transcript" "${task_files[@]}" 2>/dev/null | jq -rs '
    [ .[] | .message? // empty
      | select((.model // "" | startswith("claude")) and .usage.output_tokens?)
      | {id: .id, m: .model, o: .usage.output_tokens, i: (.usage.input_tokens // 0), cr: (.usage.cache_read_input_tokens // 0), cw5: (.usage.cache_creation.ephemeral_5m_input_tokens // (.usage.cache_creation_input_tokens // 0)), cw1h: (.usage.cache_creation.ephemeral_1h_input_tokens // 0)} ]
    | group_by(.id) | map(max_by(.o))
    | group_by(.m) | map({m: .[0].m, o: (map(.o) | add), i: (map(.i) | add), cr: (map(.cr) | add), cw5: (map(.cw5) | add), cw1h: (map(.cw1h) | add)})
    | sort_by(-.o)
    | .[] | (.m | sub("^claude-"; "") | sub("-[0-9].*$"; "")) + "\t" + (.o | tostring) + "\t" + (.i | tostring) + "\t" + (.cr | tostring) + "\t" + (.cw5 | tostring) + "\t" + (.cw1h | tostring)' 2>/dev/null)
  if [ -n "$model_data" ]; then
    # First pass: per-model cost in integer micro-dollars (bash has no floats),
    # summed for the bar-length percentage below — bars must track $ spend,
    # not raw output tokens (a model can cost far more/less per output token).
    total_cost=0
    while IFS=$'\t' read -r name t intok cr cw5 cw1h; do
      case "$name" in
        fable)  in_rate=10; out_rate=50 ;;
        opus)   in_rate=5;  out_rate=25 ;;
        sonnet) in_rate=3;  out_rate=15 ;;
        haiku)  in_rate=1;  out_rate=5  ;;
        *)      in_rate=5;  out_rate=25 ;;
      esac
      cost_micro=$(awk -v i="$intok" -v o="$t" -v cr="$cr" -v cw5="$cw5" -v cw1h="$cw1h" -v ir="$in_rate" -v orr="$out_rate" 'BEGIN{printf "%.0f", i*ir + o*orr + cr*ir*0.1 + cw5*ir*1.25 + cw1h*ir*2.0}')
      total_cost=$((total_cost + cost_micro))
    done <<< "$model_data"
    while IFS=$'\t' read -r name t intok cr cw5 cw1h; do
      # Per-model $/M token rates (input, output); unknown models fall back to opus-ish rates
      case "$name" in
        fable)  in_rate=10; out_rate=50 ;;
        opus)   in_rate=5;  out_rate=25 ;;
        sonnet) in_rate=3;  out_rate=15 ;;
        haiku)  in_rate=1;  out_rate=5  ;;
        *)      in_rate=5;  out_rate=25 ;;
      esac
      read -r cost_micro cost_str <<< "$(awk -v i="$intok" -v o="$t" -v cr="$cr" -v cw5="$cw5" -v cw1h="$cw1h" -v ir="$in_rate" -v orr="$out_rate" 'BEGIN{
        micro = i*ir + o*orr + cr*ir*0.1 + cw5*ir*1.25 + cw1h*ir*2.0
        cost = micro / 1000000
        if (cost < 10) s = sprintf("$%.2f", cost)
        else if (cost < 100) s = sprintf("$%.1f", cost)
        else s = sprintf("$%d", cost)
        printf "%.0f %s", micro, s
      }')"
      pct=$(( total_cost > 0 ? cost_micro * 100 / total_cost : 0 ))
      filled=$((pct / 10)); [ "$filled" -gt 10 ] && filled=10
      empty=$((10 - filled))
      bar=""
      for ((i=0; i<filled; i++)); do bar="${bar}█"; done
      for ((i=0; i<empty; i++)); do bar="${bar}░"; done
      if [ "$t" -ge 1000 ]; then tok_str="$((t / 1000))k"; else tok_str="$t"; fi
      # Total input sent = fresh input + cache reads + cache writes (what the
      # model actually ingested, not what was billed at full rate)
      tin=$((intok + cr + cw5 + cw1h))
      if [ "$tin" -ge 1000000 ]; then in_str=$(awk -v v="$tin" 'BEGIN{printf "%.1fM", v/1000000}')
      elif [ "$tin" -ge 1000 ]; then in_str="$((tin / 1000))k"
      else in_str="$tin"; fi
      # Per-model color: fable magenta, opus red, sonnet blue, haiku green
      case "$name" in
        fable)  mcolor="\033[35m" ;;
        opus)   mcolor="\033[31m" ;;
        sonnet) mcolor="\033[34m" ;;
        haiku)  mcolor="\033[32m" ;;
        *)      mcolor="\033[37m" ;;
      esac
      # Fixed field widths (name 6, out/in 11, pct 4, cost 6) so every line is the same
      # visible length — bars stack cleanly and right edges stay flush.
      # Computed by parts: bar glyphs are multibyte, so ${#whole_line} would
      # overcount under a C locale.
      vis=$((6 + 1 + 10 + 1 + 11 + 1 + 4 + 1 + 6))
      lpad=$((term_width - vis)); [ "$lpad" -lt 0 ] && lpad=0
      # Braille blanks (U+2800): render as blank but survive the renderer's
      # leading-whitespace trim, so the right-alignment actually sticks
      pad=$(printf '%*s' "$lpad" '' | sed 's/ /⠀/g')
      model_lines="${model_lines}\n${pad}${mcolor}$(printf '%-6s' "$name") ${bar} $(printf '%11s %4s %6s' "${tok_str}:${in_str}" "${pct}%" "$cost_str")\033[0m"
    done <<< "$model_data"
  fi
fi

# --- Assemble line 1 ---
# Format: ~/path/to/dir  |  branch          ctx ██████████ 305k/200k 152%
# Left block, then mid-line space padding (mid-line whitespace survives the
# renderer; only leading whitespace needs braille blanks), ctx bar flush right.

line=$(printf '\033[37m%s\033[0m' "$display_dir")
left_vis=${#display_dir}

# Git branch (cyan)
if [ -n "$git_branch" ]; then
  line="$line  \033[2m|\033[0m  $(printf '\033[36m%s\033[0m' "$git_branch")"
  left_vis=$((left_vis + 5 + ${#git_branch}))
fi

# Context bar, right-aligned to the same column as the model bars
if [ -n "$context_str" ]; then
  midpad=$((term_width - left_vis - ctx_vis))
  [ "$midpad" -lt 2 ] && midpad=2
  line="$line$(printf '%*s' "$midpad" '')$context_str"
fi

printf '%b' "$line$model_lines"
