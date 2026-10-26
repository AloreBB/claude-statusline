#!/usr/bin/env bash
# Picks a fresh "did you know" line for the status line from live sources.
# Run by a UserPromptSubmit hook (in background) on every message; writes
# "<tag>\t<text>" to $CACHE/fact, which statusline.sh renders.
#
# Sources (cached so most runs are a local pick, not a request):
#   history  — Wikipedia ES "on this day" events (refreshed daily, ~60 items/day)
#   trending — Wikipedia ES most-read articles (refreshed daily)
#   tip      — tldr-pages ES examples for commands installed here (refreshed weekly)
#   hn       — Hacker News top stories         (refreshed hourly)
#   news     — BBC Mundo / DW / France 24 top headlines (refreshed every 30 min)

set -o pipefail
CACHE="$HOME/.cache/claude-statusline"
LOG="$CACHE/fact.log"
UA="claude-statusline/1.0 (personal status line)"
MAX_LEN=90
mkdir -p "$CACHE"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"; }

# Random line from stdin (portable stand-in for `shuf -n1`, which macOS lacks)
pick() { awk -v seed="$RANDOM" 'BEGIN { srand(seed) } { a[NR] = $0 } END { if (NR) print a[int(rand() * NR) + 1] }'; }

# Daily feeds are cached per date; drop the stale ones
find "$CACHE" \( -name 'onthisday-*' -o -name 'featured-*' \) -mtime +2 -delete 2>/dev/null

# Download $1 into $2 unless $2 is younger than $3 minutes. Keeps the old copy on failure.
fetch() {
  local url=$1 dest=$2 max_age=$3
  [ -s "$dest" ] && [ -z "$(find "$dest" -mmin "+$max_age" 2>/dev/null)" ] && return 0
  if curl -sfL -m 8 -A "$UA" "$url" -o "$dest.tmp"; then
    mv "$dest.tmp" "$dest"
  else
    rm -f "$dest.tmp"
    log "fetch failed: $url"
    [ -s "$dest" ]
  fi
}

# Feed text is untrusted: drop C0 and C1 control chars (UTF-8 U+0080–U+009F) so it cannot
# carry terminal escape sequences
strip_controls() { LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C sed $'s/\xc2[\x80-\x9f]//g'; }

# Trim to MAX_LEN at a word boundary
shorten() {
  awk -v max="$MAX_LEN" '{
    gsub(/[\001-\037\177]/, ""); gsub(/[ ]+/, " "); gsub(/ \([^)]*\)/, "")
    if (length($0) <= max) { print; exit }
    s = substr($0, 1, max); sub(/ [^ ]*$/, "", s); print s "…"; exit
  }'
}

fact_history() {
  local f="$CACHE/onthisday-$(date +%m%d).json"
  fetch "https://api.wikimedia.org/feed/v1/wikipedia/es/onthisday/all/$(date +%m/%d)" "$f" 1440 || return 1
  jq -r '((.selected // []) + (.events // []))[] | "\(.year)\t\(.text)"' "$f" |
    pick | awk -F'\t' '{ printf "hoy en %s\t%s\n", $1, $2 }'
}

fact_trending() {
  local f="$CACHE/featured-$(date +%Y%m%d).json"
  fetch "https://api.wikimedia.org/feed/v1/wikipedia/es/featured/$(date +%Y/%m/%d)" "$f" 1440 || return 1
  jq -r '(.mostread.articles // [])[] | select(.description) | "tendencia\t\(.titles.normalized) — \(.description)"' "$f" | pick
}

fact_tip() {
  local zip="$CACHE/tldr-es.zip" dir="$CACHE/tldr-es"
  fetch "https://github.com/tldr-pages/tldr/releases/latest/download/tldr-pages.es.zip" "$zip" 10080 || return 1
  if [ ! -d "$dir" ] || [ "$zip" -nt "$dir" ]; then
    rm -rf "$dir" && unzip -qo "$zip" -d "$dir" || { log "unzip failed"; return 1; }
    # Index pages for tools installed on this machine ("# git commit" -> git), skipping alias
    # pages that only say "see `tldr <other>`". One awk pass over all pages keeps this fast.
    local platform=linux
    [ "$(uname)" = Darwin ] && platform=osx
    find "$dir" \( -path '*/common/*.md' -o -path "*/$platform/*.md" \) -print0 |
      xargs -0 awk 'FNR == 1 { if (f && !alias) print tool "\t" f; f = FILENAME; tool = $2; alias = 0 }
                    /^`tldr / { alias = 1 }
                    END { if (f && !alias) print tool "\t" f }' |
      while IFS=$'\t' read -r tool page; do
        command -v "$tool" >/dev/null 2>&1 && echo "$page"
      done >"$dir/installed.txt"
  fi
  local page
  page=$(pick <"$dir/installed.txt")
  [ -n "$page" ] || return 1
  # Pair each "- description:" with its `command`, pick one example
  awk -v name="$(head -1 "$page" | sed 's/^# //')" '
    /^- / { d = substr($0, 3); sub(/:$/, "", d); next }
    /^`/  { c = $0; gsub(/`/, "", c); gsub(/\{\{|\}\}/, "", c); print "tip " name "\t" d ": " c }
  ' "$page" | pick
}

fact_hn() {
  local f="$CACHE/hn-top.json" id title
  fetch "https://hacker-news.firebaseio.com/v0/topstories.json" "$f" 60 || return 1
  id=$(jq -r '.[:30][]' "$f" | pick)
  title=$(curl -sf -m 5 "https://hacker-news.firebaseio.com/v0/item/$id.json" | jq -r '.title // empty') || return 1
  [ -n "$title" ] && printf 'hacker news\t%s\n' "$title"
}

fact_news() {
  local feeds=(bbc-mundo:https://feeds.bbci.co.uk/mundo/rss.xml
               dw:https://rss.dw.com/rdf/rss-sp-top
               france24:https://www.france24.com/es/rss)
  local pick=${feeds[RANDOM % ${#feeds[@]}]}
  local name=${pick%%:*} url=${pick#*:} f
  f="$CACHE/news-$name.xml"
  fetch "$url" "$f" 30 || return 1
  # Item titles only (skip the channel title), top 8 = the lead stories
  tr -d '\n' <"$f" | grep -oE '<item[ >].*' | grep -oE '<title>[^<]*(<!\[CDATA\[[^]]*\]\]>)?' |
    sed -E 's/<title>(<!\[CDATA\[)?//; s/\]\]>$//; s/&quot;/"/g; s/&#39;|&apos;/'"'"'/g; s/&amp;/\&/g' |
    grep -v '^[[:space:]]*$' | head -8 | pick | awk -v n="$name" '{ print "mundo · " n "\t" $0 }'
}

# Weighted pick: news 30%, history 25%, tip 20%, trending 15%, hn 10%; fall back through the rest
roll=$((RANDOM % 100))
if   ((roll < 30)); then order=(news history tip trending hn)
elif ((roll < 55)); then order=(history news tip trending hn)
elif ((roll < 75)); then order=(tip news history trending hn)
elif ((roll < 90)); then order=(trending news history tip hn)
else                     order=(hn news history tip trending)
fi

for source in "${order[@]}"; do
  line=$("fact_$source" 2>>"$LOG") || continue
  [ -n "$line" ] || continue
  tag=${line%%$'\t'*}
  text=$(printf '%s' "${line#*$'\t'}" | strip_controls | shorten)
  tag=$(printf '%s' "$tag" | strip_controls)
  printf '%s\t%s\n' "$tag" "$text" >"$CACHE/fact.tmp" && mv "$CACHE/fact.tmp" "$CACHE/fact"
  exit 0
done

log "all sources failed; keeping previous fact"
exit 1
