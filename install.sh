#!/usr/bin/env bash
# Installs (or removes, with --uninstall) the alore status line for Claude Code.
#   - copies statusline.sh + statusline-fact.sh into ~/.claude/
#   - points settings.json "statusLine" at it
#   - adds a UserPromptSubmit hook that refreshes the fact line on every prompt
# Safe to re-run: it updates the scripts and never duplicates the hook.
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CACHE="$HOME/.cache/claude-statusline"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_CMD='bash ~/.claude/statusline-fact.sh >/dev/null 2>&1 &'

say() { printf '\033[38;2;43;212;138m●\033[0m %s\n' "$*"; }
die() { printf '\033[38;2;255;95;87m●\033[0m %s\n' "$*" >&2; exit 1; }

missing=()
for cmd in jq curl awk unzip git; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
[ ${#missing[@]} -eq 0 ] || die "Faltan dependencias: ${missing[*]} (instálalas y vuelve a correr)"

mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS no es JSON válido; arréglalo antes de instalar"

backup="$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$backup"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if [ "${1:-}" = "--uninstall" ]; then
  jq --arg cmd "$HOOK_CMD" '
    del(.statusLine)
    | if .hooks.UserPromptSubmit then
        .hooks.UserPromptSubmit |= map(select(all(.hooks[]?; .command != $cmd)))
      else . end
  ' "$SETTINGS" >"$tmp"
  mv "$tmp" "$SETTINGS"
  rm -f "$CLAUDE_DIR/statusline.sh" "$CLAUDE_DIR/statusline-fact.sh"
  rm -rf "$CACHE"
  say "Status line desinstalado (backup del settings: $backup)"
  exit 0
fi

install -m 755 "$SRC/statusline.sh" "$CLAUDE_DIR/statusline.sh"
install -m 755 "$SRC/statusline-fact.sh" "$CLAUDE_DIR/statusline-fact.sh"

jq --arg cmd "$HOOK_CMD" '
  .statusLine = {type: "command", command: "bash ~/.claude/statusline.sh", padding: 0, refreshInterval: 30}
  | .hooks.UserPromptSubmit = (
      (.hooks.UserPromptSubmit // [])
      | if any(.[]; any(.hooks[]?; .command == $cmd)) then .
        else . + [{matcher: "", hooks: [{type: "command", command: $cmd}]}] end
    )
' "$SETTINGS" >"$tmp"
mv "$tmp" "$SETTINGS"

# First fact right away so line 4 is not empty until the next prompt
bash "$CLAUDE_DIR/statusline-fact.sh" || say "No se pudo traer el primer dato (¿sin internet?); se reintenta en cada mensaje"

say "Instalado en $CLAUDE_DIR (backup del settings: $backup)"
say "Se ve en el próximo refresh del status line o al reiniciar Claude Code"
