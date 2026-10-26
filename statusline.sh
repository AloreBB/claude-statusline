#!/usr/bin/env bash
# Claude Code status line — shapes and color from the alore.dev palette (replaces ccstatusline).
# Line 1: window lights · alore. · cwd · git branch · git changes · worktree
# Line 2: model + effort meter · context gauge + used/size · total tokens
# Line 3: 5h limit reset timer · session usage gauge  (only when rate_limits present)
# Line 4: news / history / command tip / trending fact, refreshed per prompt by statusline-fact.sh
# Shapes are plain Unicode (▰▱●✦◷), not powerline glyphs, so any font renders them.

input=$(cat)
j() { jq -r "$1 // empty" <<<"$input"; }

# alore.dev palette (truecolor "r;g;b")
SLATE="139;155;176"     # #8b9bb0
PAPER="244;246;248"     # #f4f6f8
GRAPHITE="74;85;99"     # #4a5563
SIGNAL="43;212;138"     # #2bd48a
RED="255;95;87"         # #ff5f57
YELLOW="254;188;46"     # #febc2e
GREEN="40;200;64"       # #28c840
HN_ORANGE="255;102;0"   # #ff6600
GAUGE_WIDTH=12

fg() { printf '\033[38;2;%sm' "$1"; }
RESET=$'\033[0m'

SEP=" $(fg "$GRAPHITE")/$RESET "

# Colored text segment
paint() { printf '%s%s%s' "$(fg "$1")" "$2" "$RESET"; }
bold() { printf '\033[1m%s%s%s' "$(fg "$1")" "$2" "$RESET"; }

# ▰▰▰▱▱▱ gauge; filled cells fade signal → yellow → red along the bar
gauge() {
  awk -v p="$1" -v w="$GAUGE_WIDTH" -v empty="$GRAPHITE" 'BEGIN {
    split("43 212 138", a); split("254 188 46", b); split("255 95 87", c)
    f = int(p * w / 100 + 0.5); if (f > w) f = w; if (f < 0) f = 0
    if (p > 0 && f == 0) f = 1
    for (i = 0; i < w; i++) {
      if (i >= f) { printf "\033[38;2;%sm▱", empty; continue }
      t = i / (w - 1)
      if (t < 0.5) { s = t * 2;       for (k = 1; k <= 3; k++) rgb[k] = int(a[k] + (b[k] - a[k]) * s) }
      else         { s = (t - 0.5) * 2; for (k = 1; k <= 3; k++) rgb[k] = int(b[k] + (c[k] - b[k]) * s) }
      printf "\033[38;2;%d;%d;%dm▰", rgb[1], rgb[2], rgb[3]
    }
    printf "\033[0m"
  }'
}

# 82000 -> 82k, 1000000 -> 1.0M, 482000 -> 482.0k
fmt_tokens() {
  awk -v n="$1" -v d="$2" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n / 1000000
    else if (n >= 1000) printf (d ? "%.1fk" : "%.0fk"), n / 1000
    else printf "%d", n
  }'
}

# low ●○○○○ … max ●●●●●
effort_meter() {
  local n
  case $1 in
    low) n=1 ;; medium) n=2 ;; high) n=3 ;; xhigh) n=4 ;; max) n=5 ;; *) return ;;
  esac
  local dots="" i
  for ((i = 1; i <= 5; i++)); do ((i <= n)) && dots+="●" || dots+="○"; done
  printf '%s %s' "$1" "$dots"
}

# --- Line 1: location ---------------------------------------------------------
cwd=$(j '.workspace.current_dir // .cwd')
line1="$(paint "$RED" ●)$(paint "$YELLOW" ●)$(paint "$GREEN" ●)  $(bold "$PAPER" alore)$(bold "$SIGNAL" .)  $(paint "$SLATE" "${cwd/#$HOME/\~}")"

if branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null); then
  line1+="$SEP$(paint "$SIGNAL" "⎇ $branch")"
  changes=$(git -C "$cwd" --no-optional-locks diff HEAD --shortstat 2>/dev/null |
    awk '{ for (i = 1; i <= NF; i++) { if ($(i+1) ~ /^insertion/) a = $i; if ($(i+1) ~ /^deletion/) d = $i } }
         END { if (a || d) printf "%d %d", a, d }')
  if [ -n "$changes" ]; then
    read -r added deleted <<<"$changes"
    line1+=" $(paint "$SIGNAL" "+$added") $(paint "$RED" "-$deleted")"
  fi
fi

worktree=$(j '.worktree.name')
[ -n "$worktree" ] && line1+="$SEP$(paint "$YELLOW" "◇ $worktree")"

# --- Line 2: model + context --------------------------------------------------
model=$(j '.model.display_name')
model=${model#Claude }
effort=$(effort_meter "$(j '.effort.level')")
line2="$(bold "$SIGNAL" "✦ $model")"
[ -n "$effort" ] && line2+="  $(paint "$SLATE" "$effort")"

size=$(j '.context_window.context_window_size')
used_pct=$(j '.context_window.used_percentage')
if [ -n "$size" ] && [ -n "$used_pct" ]; then
  used=$(awk -v p="$used_pct" -v s="$size" 'BEGIN { printf "%d", p * s / 100 }')
  pct_label=$(awk -v p="$used_pct" 'BEGIN { printf "%.0f", p }')
  line2+="$SEP$(gauge "$used_pct") $(paint "$PAPER" "$(fmt_tokens "$used" 0)")$(paint "$SLATE" "/$(fmt_tokens "$size" 1)  ${pct_label}%")"
fi

total_in=$(j '.context_window.total_input_tokens')
total_out=$(j '.context_window.total_output_tokens')
if [ -n "$total_in" ] && [ -n "$total_out" ]; then
  line2+="$SEP$(paint "$SLATE" Σ) $(paint "$PAPER" "$(fmt_tokens $((total_in + total_out)) 1)")"
fi

printf '%s\n%s\n' "$line1" "$line2"

# --- Line 3: 5h usage limit (subscription only) -------------------------------
session_pct=$(j '.rate_limits.five_hour.used_percentage')
resets_at=$(j '.rate_limits.five_hour.resets_at')
if [ -n "$session_pct" ]; then
  reset_label="—"
  if [ -n "$resets_at" ]; then
    left=$(( resets_at - $(date +%s) ))
    (( left < 0 )) && left=0
    reset_label="$((left / 3600))h $((left % 3600 / 60))m"
  fi
  printf '%s %s%s%s %s %s\n' "$(paint "$SLATE" "◷ reset")" "$(paint "$PAPER" "$reset_label")" "$SEP" \
    "$(paint "$SLATE" 5h)" "$(gauge "$session_pct")" "$(paint "$PAPER" "$(awk -v p="$session_pct" 'BEGIN { printf "%.1f%%", p }')")"
fi

# --- Line 4: fact of the moment (written by statusline-fact.sh on each prompt) ---
fact_file="$HOME/.cache/claude-statusline/fact"
[ -s "$fact_file" ] || exit 0
IFS=$'\t' read -r tag text <"$fact_file"
case $tag in
  mundo*)       icon="◉"; color=$RED ;;
  hoy\ en*)     icon="◆"; color=$YELLOW ;;
  tip*)         icon="❯"; color=$SIGNAL ;;
  tendencia*)   icon="↗"; color=$SLATE ;;
  hacker\ news) icon="▲"; color=$HN_ORANGE ;;
  *)            icon="✧"; color=$SLATE ;;
esac
printf '%s %s\n' "$(bold "$color" "$icon $tag")" "$(paint "$PAPER" "$text")"
