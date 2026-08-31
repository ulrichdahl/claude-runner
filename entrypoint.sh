#!/usr/bin/env bash
# Container PID 1.
#
#   - starts cron (the 10-minute rate-limit watchdog)
#   - starts/keeps a live `claude` console in tmux, attachable at any time
#   - stays in the foreground so the container lives as long as the console
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
SESSION="${CLAUDE_TMUX_SESSION:-claude}"
CLAUDE_ARGS="${CLAUDE_ARGS:-}"

mkdir -p "$WORKSPACE" /root/.claude /var/lib/claude-watchdog

# Idempotent: covers the case where ~/.claude is an empty named volume that
# shadowed the plugin state baked in at build time.
if ! claude plugin list 2>/dev/null | grep -q caveman; then
  claude plugin marketplace add JuliusBrussee/caveman >/dev/null 2>&1 || true
  claude plugin install caveman@caveman --yes >/dev/null 2>&1 \
    || echo "WARN: caveman plugin install failed (network or auth?)"
fi

# cron jobs get an almost-empty environment, so hand the watchdog the
# compose-supplied settings through a file it sources, and rebuild its
# schedule from WATCHDOG_INTERVAL_MIN.
cat > /etc/claude-watchdog.env <<ENVFILE
CLAUDE_TMUX_SESSION="${SESSION}"
CONTINUE_TEXT="${CONTINUE_TEXT:-continue}"
USAGE_PROBE_MIN_INTERVAL="${USAGE_PROBE_MIN_INTERVAL:-3600}"
NUDGE_MIN_INTERVAL="${NUDGE_MIN_INTERVAL:-900}"
USAGE_PROBE_WAIT="${USAGE_PROBE_WAIT:-8}"
PANE_LINES="${PANE_LINES:-300}"
TZ="${TZ:-UTC}"
ENVFILE
chmod 0644 /etc/claude-watchdog.env

interval="${WATCHDOG_INTERVAL_MIN:-10}"
if [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 && interval <= 59 )); then
  schedule="*/$interval * * * *"
else
  echo "WARN: WATCHDOG_INTERVAL_MIN='$interval' not 1-59, using 10"
  schedule="*/10 * * * *"
fi

if [[ "${WATCHDOG_ENABLED:-true}" == "true" ]]; then
  printf '%s root /usr/local/bin/claude-watchdog >> /var/log/claude-watchdog.log 2>&1\n' \
    "$schedule" > /etc/cron.d/claude-watchdog
  chmod 0644 /etc/cron.d/claude-watchdog
  service cron start >/dev/null 2>&1 || cron
else
  rm -f /etc/cron.d/claude-watchdog
  echo "Watchdog disabled (WATCHDOG_ENABLED=false)"
fi

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$WORKSPACE" \
    "claude ${CLAUDE_ARGS}"
fi

cat <<MSG
Container ready. Workspace: $WORKSPACE
  Live console:       docker exec -it <container> tmux attach -t $SESSION   (detach: Ctrl-b d)
  Maintenance shell:  docker exec -it <container> bash
  Watchdog log:       docker exec <container> tail -f /var/log/claude-watchdog.log
  Watchdog schedule:  ${WATCHDOG_ENABLED:-true} @ every ${WATCHDOG_INTERVAL_MIN:-10} min
MSG

# Keep PID 1 alive, and resurrect the console if it ever exits.
while true; do
  sleep 30
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "$(date -Iseconds) console gone, restarting"
    tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "$WORKSPACE" \
      "claude ${CLAUDE_ARGS}"
  fi
done
