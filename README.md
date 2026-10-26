# claude-statusline

Status line para Claude Code con la paleta de [alore.dev](https://alore.dev) y un dato que cambia en cada mensaje: noticias, hoy en la historia, tips de comandos que tienes instalados, tendencias de Wikipedia, Hacker News y tus issues asignados.

![preview](preview.png)

## Instalar

```bash
curl -fsSL https://raw.githubusercontent.com/AloreBB/claude-statusline/main/install.sh | bash
```

Requiere `bash`, `jq`, `curl`, `awk`, `unzip` y `git` (Linux o macOS). Respalda `~/.claude/settings.json` antes de tocarlo y no modifica tus otros hooks. Para actualizar, vuelve a correrlo. Se ve en el próximo refresh o al reiniciar Claude Code.

Desinstalar:

```bash
curl -fsSL https://raw.githubusercontent.com/AloreBB/claude-statusline/main/install.sh | bash -s -- --uninstall
```

## Qué muestra

| Línea | Contenido |
|---|---|
| 1 | `●●●` · `alore.` · directorio · `⎇ rama` (click abre el repo) · worktree |
| 2 | `✦ modelo` · effort `●●●○○` · contexto `▰▰▰▱▱` usados/total % (`⚠ compacta pronto` desde el 80 %, ajustable en `COMPACT_WARN_PCT`) · `Σ` tokens totales · líneas cambiadas en la sesión `+156 −23` |
| 3 | `◷ reset` del límite de 5h · barra de uso (solo con suscripción) |
| 4 | Dato del momento; click abre el artículo |

Las barras pasan de verde a amarillo a rojo según se llenan.

### Saludo y mascota

La línea 1 termina con un saludo según la hora. Antes del dato, una mascota reacciona a la sesión con una frase que cambia cada 30 s:

| Cara | Cuándo |
|---|---|
| `(ﾟДﾟ;)` | límite de 5h por encima del 90 % |
| `(⊙_⊙)?` | justo después de un `/compact` |
| `(._.)` / `\(^o^)/` | el PR de la rama tiene cambios pedidos / está aprobado |
| `(×_×)` | contexto por encima del 80 % |
| `(°_°;)` | más de 500 líneas cambiadas en la sesión |
| `(-_-) zzz` | el caché del prompt expiró (el próximo mensaje cuesta más) |
| `ε=ε=(ノ≧∇≦)ノ` | fast mode |
| `(￣o￣) zzZ` | entre las 0 y las 5h |
| `(•̀ᴗ•́)✎` / `(•_•)` | vim en INSERT / otro modo |
| `(°_°)` | contexto por encima del 50 % |
| `(•‿•)` | todo bien |

### Fuentes del dato

| Icono | Fuente | Se refresca |
|---|---|---|
| `◉ mundo` | Titulares de BBC Mundo, DW y France 24 | cada 30 min |
| `◆ hoy en AAAA` | Wikipedia ES, "un día como hoy" | diario |
| `❯ tip` | [tldr-pages](https://github.com/tldr-pages/tldr) de comandos instalados en tu máquina | semanal |
| `↗ tendencia` | Más leídos hoy en Wikipedia ES | diario |
| `▲ hacker news` | Top 30 de Hacker News | cada hora |
| `◎ issue` | Issues abiertos asignados a ti en GitHub; click abre el issue. Requiere [`gh`](https://cli.github.com) con sesión iniciada (sin él se omite) | cada 30 min |

En repos de GitHub o GitLab, la línea 1 muestra `+ issue`: click abre el formulario para crear un issue nuevo.

Si una fuente falla se usa otra; los errores quedan en `~/.cache/claude-statusline/fact.log`.

## Notas

- Iconos Unicode estándar: no hace falta Nerd Font.
- Los enlaces se abren con cmd/ctrl+click (iTerm2, Ghostty, WezTerm, Kitty, VS Code, Terminal.app). En tmux ≥ 3.4 agrega `set -as terminal-features ',*:hyperlinks'` a `~/.tmux.conf` y vuelve a hacer attach.
- Colores truecolor; la paleta está al inicio de `statusline.sh`.
