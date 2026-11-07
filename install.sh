#!/usr/bin/env bash
# Installs (or removes, with --uninstall) the alore status line for Claude Code.
#   - copies statusline.sh + statusline-fact.sh into the Claude config dir
#     ($CLAUDE_CONFIG_DIR, or ~/.claude by default), backing up scripts it would overwrite
#   - points settings.json "statusLine" at it, remembering any previous status line
#   - adds a UserPromptSubmit hook that refreshes the fact line on every prompt
# Safe to re-run: it updates the scripts and never duplicates the hook.
# Works from a clone or piped from curl (then it downloads the scripts from $REPO_RAW):
#   curl -fsSL https://raw.githubusercontent.com/AloreBB/claude-statusline/main/install.sh | bash
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_DIR="${CLAUDE_DIR%/}"
SETTINGS="$CLAUDE_DIR/settings.json"
PREVIOUS="$CLAUDE_DIR/statusline.previous.json"
CACHE="$HOME/.cache/claude-statusline"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/AloreBB/claude-statusline/main}"
STAMP="$(date +%Y%m%d%H%M%S)"

# The default commands stay literal so existing installs keep matching them
if [ "$CLAUDE_DIR" = "$HOME/.claude" ]; then
  STATUS_CMD='bash ~/.claude/statusline.sh'
  HOOK_CMD='bash ~/.claude/statusline-fact.sh >/dev/null 2>&1 &'
else
  STATUS_CMD="bash $(printf '%q' "$CLAUDE_DIR/statusline.sh")"
  HOOK_CMD="bash $(printf '%q' "$CLAUDE_DIR/statusline-fact.sh") >/dev/null 2>&1 &"
fi

say() { printf '\033[38;2;43;212;138m●\033[0m %s\n' "$*"; }
die() { printf '\033[38;2;255;95;87m●\033[0m %s\n' "$*" >&2; exit 1; }

# Both scripts mention the project's cache dir; anything else at these paths belongs to the user
is_ours() { grep -q 'claude-statusline' "$1"; }

# Writes through a symlink (dotfiles setups) instead of replacing it
save_settings() {
  if [ -L "$SETTINGS" ]; then
    cat "$tmp" >"$SETTINGS"
  else
    mv "$tmp" "$SETTINGS"
  fi
}

uninstalling=false
[ "${1:-}" = "--uninstall" ] && uninstalling=true

required=(jq curl awk unzip git)
$uninstalling && required=(jq)
missing=()
for cmd in "${required[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
[ ${#missing[@]} -eq 0 ] || die "Faltan dependencias: ${missing[*]} (instálalas y vuelve a correr)"

mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS no es JSON válido; arréglalo antes de instalar"

backup="$SETTINGS.bak-$STAMP"
cp "$SETTINGS" "$backup"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cp -p "$SETTINGS" "$tmp" # the temp file inherits the settings' permissions

if $uninstalling; then
  previous_line=null
  previous_script=""
  if [ -f "$PREVIOUS" ]; then
    previous_line=$(jq -c '.statusLine' "$PREVIOUS")
    previous_script=$(jq -r '.script // empty' "$PREVIOUS")
  fi

  if [ "$(jq -r '.statusLine.command // empty' "$SETTINGS")" != "$STATUS_CMD" ] && [ "$(jq 'has("statusLine")' "$SETTINGS")" = true ]; then
    say "El statusLine actual es de otra herramienta; no lo toqué"
  fi

  jq --arg status "$STATUS_CMD" --arg hook "$HOOK_CMD" --argjson previous "$previous_line" '
    if .statusLine.command == $status then
      (if $previous == null then del(.statusLine) else .statusLine = $previous end)
    else . end
    | if .hooks.UserPromptSubmit then
        .hooks.UserPromptSubmit |= map(
          if any(.hooks[]?; .command == $hook) then
            (.hooks |= map(select(.command != $hook))) | select(.hooks | length > 0)
          else . end
        )
        | if .hooks.UserPromptSubmit == [] then del(.hooks.UserPromptSubmit) else . end
        | if .hooks == {} then del(.hooks) else . end
      else . end
  ' "$SETTINGS" >"$tmp"
  save_settings

  for name in statusline.sh statusline-fact.sh; do
    script="$CLAUDE_DIR/$name"
    [ -f "$script" ] || continue
    if is_ours "$script"; then
      rm -f "$script"
    else
      say "$script no es de claude-statusline; no lo toqué"
    fi
  done
  if [ -n "$previous_script" ] && [ -f "$previous_script" ] && [ ! -e "$CLAUDE_DIR/statusline.sh" ]; then
    cp -p "$previous_script" "$CLAUDE_DIR/statusline.sh"
    say "Restaurado tu statusline.sh anterior"
  fi
  rm -f "$PREVIOUS"
  rm -rf "$CACHE"
  say "Status line desinstalado (backup del settings: $backup)"
  exit 0
fi

# From a clone use the scripts next to this file; piped from curl there is no file, so download them
src=""
[ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] && src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$src" ] || [ ! -f "$src/statusline.sh" ]; then
  src=$(mktemp -d)
  trap 'rm -f "$tmp"; rm -rf "$src"' EXIT
  for f in statusline.sh statusline-fact.sh; do
    curl -fsSL -m 20 "$REPO_RAW/$f" -o "$src/$f" || die "No se pudo descargar $f de $REPO_RAW"
  done
fi

# Never overwrite a script without a copy: it may be the user's own or carry their edits
foreign_script=""
for name in statusline.sh statusline-fact.sh; do
  dest="$CLAUDE_DIR/$name"
  if [ -f "$dest" ] && ! cmp -s "$src/$name" "$dest"; then
    cp -p "$dest" "$dest.bak-$STAMP"
    say "Tu $name anterior quedó en $dest.bak-$STAMP"
    if [ "$name" = statusline.sh ] && ! is_ours "$dest"; then
      foreign_script="$dest.bak-$STAMP"
    fi
  fi
done

# Remember what --uninstall has to put back
if [ -n "$foreign_script" ] || jq -e --arg status "$STATUS_CMD" 'has("statusLine") and .statusLine.command != $status' "$SETTINGS" >/dev/null; then
  jq --arg script "$foreign_script" '{statusLine: .statusLine, script: $script}' "$SETTINGS" >"$PREVIOUS"
fi

install -m 755 "$src/statusline.sh" "$CLAUDE_DIR/statusline.sh"
install -m 755 "$src/statusline-fact.sh" "$CLAUDE_DIR/statusline-fact.sh"

jq --arg status "$STATUS_CMD" --arg hook "$HOOK_CMD" '
  .statusLine = {type: "command", command: $status, padding: 0, refreshInterval: 30}
  | .hooks.UserPromptSubmit = (
      (.hooks.UserPromptSubmit // [])
      | if any(.[]; any(.hooks[]?; .command == $hook)) then .
        else . + [{matcher: "", hooks: [{type: "command", command: $hook}]}] end
    )
' "$SETTINGS" >"$tmp"
save_settings

# First fact right away so line 4 is not empty until the next prompt
bash "$CLAUDE_DIR/statusline-fact.sh" || say "No se pudo traer el primer dato (¿sin internet?); se reintenta en cada mensaje"

say "Instalado en $CLAUDE_DIR (backup del settings: $backup)"
say "Se ve en el próximo refresh del status line o al reiniciar Claude Code"
