#!/usr/bin/env bash
# Container health probe.
#
# Healthy means "the console is alive and the watchdog can still fire" --
# deliberately NOT "Claude is currently working". A session parked on a rate
# limit is a normal, expected state that the watchdog exists to recover from,
# so it must not be reported as unhealthy.
set -uo pipefail

[[ -f /etc/claude-watchdog.env ]] && . /etc/claude-watchdog.env
SESSION="${CLAUDE_TMUX_SESSION:-claude}"
TMUX_SOCKET="${TMUX_SOCKET:-/run/claude/tmux.sock}"

fail() { echo "UNHEALTHY: $*"; exit 1; }

# 1. The console session exists. `claude` is the tmux session's command, so
#    if Claude died the session goes with it (the entrypoint restarts it
#    within ~30s, which is what start_period and retries absorb).
tmux -u -S "$TMUX_SOCKET" has-session -t "$SESSION" 2>/dev/null \
  || fail "no tmux session '$SESSION'"

# 2. The pane still has a live process attached.
panes="$(tmux -u -S "$TMUX_SOCKET" list-panes -t "$SESSION" -F '#{pane_dead}' 2>/dev/null)"
[[ -n "$panes" ]] || fail "session '$SESSION' has no panes"
grep -qv '^1$' <<<"$panes" || fail "all panes in '$SESSION' are dead"

# 3. cron is up, or the watchdog would never fire again.
if [[ "${WATCHDOG_ENABLED:-true}" == "true" ]]; then
  pgrep -x cron >/dev/null 2>&1 || fail "cron is not running"
  [[ -f /etc/cron.d/claude-watchdog ]] || fail "watchdog cron entry missing"
fi

# Informational only -- never a failure.
if [[ -f /var/lib/claude-watchdog/resume_at ]]; then
  until_epoch="$(cat /var/lib/claude-watchdog/resume_at 2>/dev/null || echo)"
  if [[ "$until_epoch" =~ ^[0-9]+$ ]]; then
    echo "OK (rate-limited, resuming $(date -d "@$until_epoch" -Iseconds))"
    exit 0
  fi
fi

echo "OK"
