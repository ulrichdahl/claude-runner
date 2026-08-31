#!/usr/bin/env bash
# Attach to the live Claude console.
#
# Exists mainly for web terminals (Coolify's, Portainer's, etc.), which run
# `docker exec` and drop you in a plain shell -- `docker attach` is not
# reachable there, so joining the session means going through tmux. Type
# `console` instead of remembering the tmux invocation.
#
# Detach with Ctrl-b d. The session keeps running.
set -euo pipefail
SESSION="${CLAUDE_TMUX_SESSION:-claude}"
TMUX_SOCKET="${TMUX_SOCKET:-/run/claude/tmux.sock}"
CLAUDE_USER="${CLAUDE_USER:-claude}"

# `docker exec` lands you here as root; the session belongs to the
# unprivileged user, so drop to it rather than attaching as root.
if [[ "$(id -un)" != "$CLAUDE_USER" ]] && [[ "$(id -u)" == "0" ]]; then
  exec runuser -u "$CLAUDE_USER" -- env HOME="/home/$CLAUDE_USER" \
    USER="$CLAUDE_USER" SHELL=/bin/bash TERM="${TERM:-xterm-256color}" \
    LANG="${LANG:-C.UTF-8}" LC_ALL="${LC_ALL:-C.UTF-8}" \
    "$0" "$@"
fi

if ! tmux -u -S "$TMUX_SOCKET" has-session -t "$SESSION" 2>/dev/null; then
  echo "No console session '$SESSION'." >&2
  echo "PID 1 recreates it within ~30s; check: docker logs <container>" >&2
  exit 1
fi

exec tmux -u -S "$TMUX_SOCKET" attach -t "$SESSION"
