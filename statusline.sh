#!/usr/bin/env bash
# Claude Code status line — shapes and color from the alore.dev palette (replaces ccstatusline).
# Line 1: window lights · alore. · cwd · git branch · worktree
# Line 2: model + effort meter · context gauge + used/size · total tokens
# Line 3: 5h limit reset timer · session usage gauge  (only when rate_limits present)
# Line 4: news / history / command tip / trending fact, refreshed per prompt by statusline-fact.sh;
#         cmd/ctrl+click opens the full article
# Shapes are plain Unicode (▰▱●✦◷), not powerline glyphs, so any font renders them.
# Line 1 ends with a greeting for the hour; a mascot line before the fact reacts to the session
# (rate limit, compaction, PR review, context, diff size, cold cache, fast mode, late night, vim).

input=$(cat)
j() { jq -r "$1 // empty" <<<"$input"; }

# alore.dev palette (truecolor "r;g;b")
SLATE="139;155;176"     # #8b9bb0
TEXT=""                 # terminal default fg: readable on light and dark themes
GRAPHITE="74;85;99"     # #4a5563
SIGNAL="43;212;138"     # #2bd48a
RED="255;95;87"         # #ff5f57
YELLOW="254;188;46"     # #febc2e
GREEN="40;200;64"       # #28c840
HN_ORANGE="255;102;0"   # #ff6600
AMBER="214;158;30"      # #d69e1e, yellow that still reads on light backgrounds
GAUGE_WIDTH=12

fg() { if [ -n "$1" ]; then printf '\033[38;2;%sm' "$1"; else printf '\033[39m'; fi; }
RESET=$'\033[0m'

SEP=" $(fg "$GRAPHITE")/$RESET "

# Colored text segment
paint() { printf '%s%s%s' "$(fg "$1")" "$2" "$RESET"; }
bold() { printf '\033[1m%s%s%s' "$(fg "$1")" "$2" "$RESET"; }

# OSC 8 hyperlink: cmd/ctrl+click opens $1 in terminals that support it, plain text elsewhere
link() { printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$2"; }

# Web URL for the repo's origin (or its branch on GitHub/GitLab). The remote comes from the
# repo's own config, so only a plain https URL with an allowlisted charset gets through.
repo_web_url() {
  local url branch=$1
  url=$(git -C "$cwd" config --get remote.origin.url 2>/dev/null) || return 1
  url=$(printf '%s' "$url" | sed -E \
    -e 's#^git@([^:/]+):#https://\1/#' \
    -e 's#^ssh://([^@/]+@)?([^:/]+)(:[0-9]+)?/#https://\2/#' \
    -e 's#^https?://[^@/]+@#https://#' \
    -e 's#^http://#https://#' \
    -e 's#(\.git)?/?$##')
  [[ $url =~ ^https://[A-Za-z0-9._-]+/[A-Za-z0-9._~/%+-]+$ ]] || return 1
  case $url in
    https://github.com/* | https://gitlab.com/*)
      [ "$branch" != HEAD ] && [[ $branch =~ ^[A-Za-z0-9._/+-]+$ ]] && url+="/tree/$branch" ;;
  esac
  printf '%s' "$url"
}

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

# Mascot face + a joke for the most pressing session state. Jokes rotate every 30 s (the
# refreshInterval) and the idle face blinks on alternate ticks.
mascot() {
  local now tick color face texts=()
  now=$(date +%s); tick=$((now / 30))
  local rate ctx usage tokens review added removed expires fast vim hour
  rate=$(j '.rate_limits.five_hour.used_percentage'); rate=${rate%.*}
  ctx=$(j '.context_window.used_percentage'); ctx=${ctx%.*}
  usage=$(jq -r '.context_window.current_usage | type' <<<"$input")
  tokens=$(j '.context_window.total_input_tokens')
  review=$(j '.pr.review_state')
  added=$(j '.cost.total_lines_added'); removed=$(j '.cost.total_lines_removed')
  expires=$(j '.prompt_cache.expires_at')
  fast=$(j '.fast_mode')
  vim=$(j '.vim.mode')
  hour=$((10#$(date +%H)))

  if ((${rate:-0} >= 90)); then
    face="(ﾟДﾟ;)"; color=$RED
    texts=("¡se acaba la gasolina!" "racionando tokens como en guerra" "modo ahorro: ON")
  elif [ "$usage" = null ] && ((${tokens:-0} > 0)); then
    face="(⊙_⊙)?"; color=$AMBER
    texts=("¿de qué hablábamos?" "memoria de pez activada" "acabo de despertar de un /compact")
  elif [ "$review" = changes_requested ]; then
    face="(._.)"; color=$RED
    texts=("piden cambios… respira hondo" "el reviewer no perdona" "nada que un commit no arregle")
  elif [ "$review" = approved ]; then
    face="\\(^o^)/"; color=$SIGNAL
    texts=("¡PR aprobado, a mergear!" "luz verde, capitán" "el reviewer te ama")
  elif ((${ctx:-0} >= 80)); then
    face="(×_×)"; color=$RED
    texts=("ya no me cabe nada" "cabeza llena, corazón contento" "necesito un /compact y un café")
  elif ((${added:-0} + ${removed:-0} > 500)); then
    face="(°_°;)"; color=$AMBER
    texts=("eso es mucho diff…" "el reviewer va a llorar" "¿y si lo partimos en PRs?")
  elif [ -n "$expires" ] && ((expires < now)); then
    face="(-_-) zzz"; color=$SLATE
    texts=("el caché se durmió" "el próximo mensaje sale más caro" "despiértame con un prompt")
  elif [ "$fast" = true ]; then
    face="ε=ε=(ノ≧∇≦)ノ"; color=$SIGNAL
    texts=("¡modo turbo!" "a toda máquina" "agárrate que hay curvas")
  elif ((hour < 5)); then
    face="(￣o￣) zzZ"; color=$SLATE
    texts=("¿no deberías dormir?" "el código de las 3am nunca falla… ¿verdad?" "mañana nadie entiende esto")
  elif [ "$vim" = INSERT ]; then
    face="(•̀ᴗ•́)✎"; color=$SIGNAL
    texts=("escribiendo como poeta" "i de inspiración")
  elif [ -n "$vim" ]; then
    face="(•_•)"; color=$SLATE
    texts=("modo vim: modo zen" ":wq y a casa")
  elif ((${ctx:-0} >= 50)); then
    face="(°_°)"; color=$AMBER
    texts=("se va llenando la cabeza" "medio tanque, medio camino" "aún aguanto, creo")
  else
    face="(•‿•)"; color=$SIGNAL
    ((tick % 2)) && face="(-‿-)"
    texts=("todo fluye" "listo para codear" "cero bugs (por ahora)" "hoy sale a la primera")
  fi
  printf '%s %s' "$(bold "$color" "$face")" "$(paint "$SLATE" "${texts[tick % ${#texts[@]}]}")"
}

# --- Line 1: location ---------------------------------------------------------
cwd=$(j '.workspace.current_dir // .cwd')
line1="$(paint "$RED" ●)$(paint "$YELLOW" ●)$(paint "$GREEN" ●)  $(bold "$TEXT" alore)$(bold "$SIGNAL" .)  $(paint "$SLATE" "${cwd/#$HOME/\~}")"

# cwd may be an untrusted checkout. Only read the branch name: rev-parse reads refs and never
# runs filters or hooks (fsmonitor disabled too). Change counts are deliberately not shown,
# since diffing the worktree runs clean filters defined by the repo's own config.
if branch=$(git -C "$cwd" -c core.fsmonitor=false --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null); then
  branch_label=$(paint "$SIGNAL" "⎇ $branch")
  url=$(repo_web_url "$branch") && branch_label=$(link "$url" "$branch_label")
  line1+="$SEP$branch_label"
fi

worktree=$(j '.worktree.name')
[ -n "$worktree" ] && line1+="$SEP$(paint "$YELLOW" "◇ $worktree")"

hour=$((10#$(date +%H)))
if   ((hour < 5));  then greeting=$(paint "$SLATE" "✶ trasnochando")
elif ((hour < 12)); then greeting=$(paint "$AMBER" "☀ buenos días")
elif ((hour < 19)); then greeting=$(paint "$AMBER" "◐ buenas tardes")
else                     greeting=$(paint "$SLATE" "☾ buenas noches")
fi
line1+="$SEP$greeting"

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
  line2+="$SEP$(gauge "$used_pct") $(paint "$TEXT" "$(fmt_tokens "$used" 0)")$(paint "$SLATE" "/$(fmt_tokens "$size" 1)  ${pct_label}%")"
fi

total_in=$(j '.context_window.total_input_tokens')
total_out=$(j '.context_window.total_output_tokens')
if [ -n "$total_in" ] && [ -n "$total_out" ]; then
  line2+="$SEP$(paint "$SLATE" Σ) $(paint "$TEXT" "$(fmt_tokens $((total_in + total_out)) 1)")"
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
  printf '%s %s%s%s %s %s\n' "$(paint "$SLATE" "◷ reset")" "$(paint "$TEXT" "$reset_label")" "$SEP" \
    "$(paint "$SLATE" 5h)" "$(gauge "$session_pct")" "$(paint "$TEXT" "$(awk -v p="$session_pct" 'BEGIN { printf "%.1f%%", p }')")"
fi

# --- Mascot ------------------------------------------------------------------
printf '%s\n' "$(mascot)"

# --- Line 4: fact of the moment (written by statusline-fact.sh on each prompt) ---
fact_file="$HOME/.cache/claude-statusline/fact"
[ -s "$fact_file" ] || exit 0
# Fact text comes from external feeds: strip C0/C1 control chars (keeping the tab separator)
# so it cannot inject terminal escapes
# (C1 is replaced, not deleted, so removal can never splice bytes into a new sequence)
IFS=$'\t' read -r tag text url < <(LC_ALL=C tr -d '\000-\010\013-\037\177' <"$fact_file" | LC_ALL=C sed $'s/\xc2[\x80-\x9f]/?/g')
case $tag in
  mundo*)       icon="◉"; color=$RED ;;
  hoy\ en*)     icon="◆"; color=$AMBER ;;
  tip*)         icon="❯"; color=$SIGNAL ;;
  tendencia*)   icon="↗"; color=$SLATE ;;
  hacker\ news) icon="▲"; color=$HN_ORANGE ;;
  *)            icon="✧"; color=$SLATE ;;
esac
fact="$(bold "$color" "$icon $tag") $(paint "$TEXT" "$text")"
# cmd/ctrl+click opens the full article; the URL is only trusted if it is plain https
safe_url='^https://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$'
[[ ${url:-} =~ $safe_url ]] && fact=$(link "$url" "$fact")
printf '%s\n' "$fact"
