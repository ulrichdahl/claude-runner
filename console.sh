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

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "No console session '$SESSION'." >&2
  echo "PID 1 recreates it within ~30s; check: docker logs <container>" >&2
  exit 1
fi

exec tmux attach -t "$SESSION"
