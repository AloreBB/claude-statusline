#!/usr/bin/env bash
# Picks a fresh "did you know" line for the status line from live sources.
# Run by a UserPromptSubmit hook (in background) on every message; writes
# "<tag>\t<text>\t<url>" to $CACHE/fact, which statusline.sh renders (url = full article).
#
# Sources (cached so most runs are a local pick, not a request):
#   history  — Wikipedia ES "on this day" events (refreshed daily, ~60 items/day)
#   trending — Wikipedia ES most-read articles (refreshed daily)
#   tip      — tldr-pages ES examples for commands installed here (refreshed weekly)
#   hn       — Hacker News top stories         (refreshed hourly)
#   news     — BBC Mundo / DW / France 24 top headlines (refreshed every 30 min)
#   issue    — open GitHub issues assigned to you, via gh (refreshed every 30 min; skipped without gh)

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

# Feed text is untrusted: drop C0 control chars and neutralize C1 (UTF-8 U+0080–U+009F) so it
# cannot carry terminal escapes. C1 is replaced rather than deleted: deleting could splice the
# surrounding bytes into a new sequence (\xc2\xc2\x9b\x9b -> \xc2\x9b).
strip_controls() { LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C sed $'s/\xc2[\x80-\x9f]/?/g'; }

# Percent-encode non-ASCII bytes and spaces in a URL (some feeds ship raw UTF-8 in links)
encode_url() {
  LC_ALL=C awk 'BEGIN { for (i = 128; i < 256; i++) hex[sprintf("%c", i)] = sprintf("%%%02X", i) }
    { out = ""; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); out = out (c in hex ? hex[c] : c == " " ? "%20" : c) } print out }'
}

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
  # pages[0] is the event's main subject
  jq -r '((.selected // []) + (.events // []))[]
         | "hoy en \(.year)\t\(.text)\t\(.pages[0].content_urls.desktop.page // "")"' "$f" | pick
}

fact_trending() {
  local f="$CACHE/featured-$(date +%Y%m%d).json"
  fetch "https://api.wikimedia.org/feed/v1/wikipedia/es/featured/$(date +%Y/%m/%d)" "$f" 1440 || return 1
  jq -r '(.mostread.articles // [])[] | select(.description) | "tendencia\t\(.titles.normalized) — \(.description)\t\(.content_urls.desktop.page // "")"' "$f" | pick
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
  local url
  url="https://github.com/tldr-pages/tldr/blob/main/pages.es/$(basename "$(dirname "$page")")/$(basename "$page")"
  # Pair each "- description:" with its `command`, pick one example
  awk -v name="$(head -1 "$page" | sed 's/^# //')" -v url="$url" '
    /^- / { d = substr($0, 3); sub(/:$/, "", d); next }
    /^`/  { c = $0; gsub(/`/, "", c); gsub(/\{\{|\}\}/, "", c); print "tip " name "\t" d ": " c "\t" url }
  ' "$page" | pick
}

fact_hn() {
  local f="$CACHE/hn-top.json" id
  fetch "https://hacker-news.firebaseio.com/v0/topstories.json" "$f" 60 || return 1
  id=$(jq -r '.[:30][]' "$f" | pick)
  # Link the article itself; Ask/Show HN posts have no url, so fall back to the discussion
  curl -sf -m 5 "https://hacker-news.firebaseio.com/v0/item/$id.json" |
    jq -r 'select(.title) | "hacker news\t\(.title)\t\(.url // "https://news.ycombinator.com/item?id=\(.id)")"'
}

fact_news() {
  local feeds=(bbc-mundo:https://feeds.bbci.co.uk/mundo/rss.xml
               dw:https://rss.dw.com/rdf/rss-sp-top
               france24:https://www.france24.com/es/rss)
  local pick=${feeds[RANDOM % ${#feeds[@]}]}
  local name=${pick%%:*} url=${pick#*:} f
  f="$CACHE/news-$name.xml"
  fetch "$url" "$f" 30 || return 1
  # One item per line, then its <title> and <link>; top 8 items = the lead stories
  tr -d '\n' <"$f" | awk '{ gsub(/<item[ >]/, "\n&"); print }' | tail -n +2 | head -8 |
    awk -v n="$name" '
      function tag(s, t,   v) {
        if (!match(s, "<" t ">[^<]*(<!\\[CDATA\\[[^]]*)?")) return ""
        v = substr(s, RSTART + length(t) + 2, RLENGTH - length(t) - 2); sub(/^<!\[CDATA\[/, "", v)
        gsub(/&quot;/, "\"", v); gsub(/&#39;|&apos;/, "'"'"'", v); gsub(/&amp;/, "\\&", v)
        return v
      }
      { title = tag($0, "title"); if (title ~ /[^[:space:]]/) print "mundo · " n "\t" title "\t" tag($0, "link") }' |
    pick
}

fact_issue() {
  local f="$CACHE/issues.json"
  command -v gh >/dev/null 2>&1 || return 1
  if [ ! -s "$f" ] || [ -n "$(find "$f" -mmin +30 2>/dev/null)" ]; then
    if gh search issues --assignee=@me --state=open --limit 30 \
         --json number,title,url,repository >"$f.tmp" 2>>"$LOG"; then
      mv "$f.tmp" "$f"
    else
      rm -f "$f.tmp"; log "gh search issues failed"
    fi
  fi
  [ -s "$f" ] || return 1
  jq -r '.[] | "issue · \(.repository.name)#\(.number)\t\(.title)\t\(.url)"' "$f" | pick
}

# Weighted pick: news 25%, issue 20%, history 20%, tip 15%, trending 12%, hn 8%; fall back through the rest
roll=$((RANDOM % 100))
if   ((roll < 25)); then order=(news history tip trending hn issue)
elif ((roll < 45)); then order=(issue news history tip trending hn)
elif ((roll < 65)); then order=(history news tip trending hn issue)
elif ((roll < 80)); then order=(tip news history trending hn issue)
elif ((roll < 92)); then order=(trending news history tip hn issue)
else                     order=(hn news history tip trending issue)
fi

for source in "${order[@]}"; do
  line=$("fact_$source" 2>>"$LOG") || continue
  [ -n "$line" ] || continue
  IFS=$'\t' read -r tag text url <<<"$line"
  tag=$(printf '%s' "$tag" | strip_controls)
  text=$(printf '%s' "$text" | strip_controls | shorten)
  url=$(printf '%s\n' "$url" | strip_controls | encode_url)
  printf '%s\t%s\t%s\n' "$tag" "$text" "$url" >"$CACHE/fact.tmp" && mv "$CACHE/fact.tmp" "$CACHE/fact"
  exit 0
done

log "all sources failed; keeping previous fact"
exit 1
