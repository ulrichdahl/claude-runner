#!/usr/bin/env bash
# Container PID 1.
#
# Runs as root, but only to do the things that need it: remap the runtime
# user to PUID/PGID, make the workspace writable by that user, and start
# cron. The Claude session itself runs unprivileged.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
SESSION="${CLAUDE_TMUX_SESSION:-claude}"
CLAUDE_ARGS="${CLAUDE_ARGS:-}"
CLAUDE_USER="${CLAUDE_USER:-claude}"
CLAUDE_HOME="/home/${CLAUDE_USER}"
TMUX_SOCKET="${TMUX_SOCKET:-/run/claude/tmux.sock}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# --- remap the runtime user, if the host wants different ids ---------------
cur_uid="$(id -u "$CLAUDE_USER")"
cur_gid="$(id -g "$CLAUDE_USER")"

if [[ "$PGID" != "$cur_gid" ]]; then
  echo "Remapping ${CLAUDE_USER} gid ${cur_gid} -> ${PGID}"
  groupmod -o -g "$PGID" "$CLAUDE_USER"
fi
if [[ "$PUID" != "$cur_uid" ]]; then
  echo "Remapping ${CLAUDE_USER} uid ${cur_uid} -> ${PUID}"
  usermod -o -u "$PUID" "$CLAUDE_USER"
fi

as_claude() { runuser -u "$CLAUDE_USER" -- env HOME="$CLAUDE_HOME" \
                USER="$CLAUDE_USER" SHELL=/bin/bash "$@"; }

# --- directories the unprivileged user must own ----------------------------
mkdir -p "$WORKSPACE" "$CLAUDE_HOME/.claude" /var/lib/claude-watchdog \
         "$(dirname "$TMUX_SOCKET")"
touch /var/log/claude-watchdog.log

chown -R "$PUID:$PGID" "$CLAUDE_HOME" /var/lib/claude-watchdog \
        "$(dirname "$TMUX_SOCKET")" /var/log/claude-watchdog.log

# The workspace is usually a bind mount owned by whoever owns it on the host.
# A recursive chown of a large project on every start is expensive, so only
# do it when the top-level owner is actually wrong. CHOWN_WORKSPACE=always
# forces it; =never skips it entirely for read-only or NFS-backed mounts.
chown_mode="${CHOWN_WORKSPACE:-auto}"
ws_uid="$(stat -c '%u' "$WORKSPACE")"
case "$chown_mode" in
  never)
    echo "Workspace chown skipped (CHOWN_WORKSPACE=never)"
    ;;
  always)
    echo "Chowning $WORKSPACE to ${PUID}:${PGID} (forced)"
    chown -R "$PUID:$PGID" "$WORKSPACE"
    ;;
  *)
    if [[ "$ws_uid" != "$PUID" ]]; then
      echo "Workspace owned by uid ${ws_uid}, chowning to ${PUID}:${PGID}..."
      chown -R "$PUID:$PGID" "$WORKSPACE"
    fi
    ;;
esac

if ! as_claude test -w "$WORKSPACE"; then
  echo "WARN: ${CLAUDE_USER} cannot write to $WORKSPACE -- Claude will fail to edit files there"
fi

# --- status line -----------------------------------------------------------
# The status line is what publishes usage to the watchdog, so it is installed
# into settings.json rather than left to the user. Merged, not overwritten:
# anything else already in that file is preserved. STATUSLINE_ENABLED=false
# removes it again.
settings_file="$CLAUDE_HOME/.claude/settings.json"
STATUSLINE_ENABLED="${STATUSLINE_ENABLED:-true}"
STATUSLINE_REFRESH_SECONDS="${STATUSLINE_REFRESH_SECONDS:-60}"

python3 - "$settings_file" "$STATUSLINE_ENABLED" "$STATUSLINE_REFRESH_SECONDS" <<'PYSETTINGS'
import json, os, sys

path, enabled, refresh = sys.argv[1], sys.argv[2] == "true", sys.argv[3]

try:
    with open(path) as fh:
        settings = json.load(fh)
    if not isinstance(settings, dict):
        settings = {}
except (OSError, json.JSONDecodeError, ValueError):
    settings = {}

if enabled:
    entry = {"type": "command", "command": "/usr/local/bin/claude-statusline"}
    try:
        n = int(refresh)
        if n >= 1:
            # Rate-limit windows change while the session sits idle, so don't
            # rely on assistant messages alone to keep the file fresh.
            entry["refreshInterval"] = n
    except ValueError:
        pass
    settings["statusLine"] = entry
else:
    settings.pop("statusLine", None)

os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PYSETTINGS
chown "$PUID:$PGID" "$settings_file"
echo "Status line: ${STATUSLINE_ENABLED} (refresh ${STATUSLINE_REFRESH_SECONDS}s) -> ${USAGE_STATE_FILE:-/var/lib/claude-watchdog/usage.json}"

# --- caveman plugin --------------------------------------------------------
# Idempotent: covers a fresh home volume that shadowed the build-time install.
if ! as_claude claude plugin list 2>/dev/null | grep -q caveman; then
  as_claude claude plugin marketplace add JuliusBrussee/caveman >/dev/null 2>&1 || true
  as_claude claude plugin install caveman@caveman --yes >/dev/null 2>&1 \
    || echo "WARN: caveman plugin install failed (network or auth?)"
fi

# --- watchdog config -------------------------------------------------------
# cron jobs get an almost-empty environment, so hand the watchdog the
# compose-supplied settings through a file it sources, and rebuild its
# schedule from WATCHDOG_INTERVAL_MIN.
cat > /etc/claude-watchdog.env <<ENVFILE
CLAUDE_TMUX_SESSION="${SESSION}"
TMUX_SOCKET="${TMUX_SOCKET}"
CONTINUE_TEXT="${CONTINUE_TEXT:-continue}"
USAGE_PROBE_MIN_INTERVAL="${USAGE_PROBE_MIN_INTERVAL:-3600}"
NUDGE_MIN_INTERVAL="${NUDGE_MIN_INTERVAL:-900}"
USAGE_PROBE_WAIT="${USAGE_PROBE_WAIT:-8}"
PANE_LINES="${PANE_LINES:-300}"
USAGE_STATE_FILE="${USAGE_STATE_FILE:-/var/lib/claude-watchdog/usage.json}"
USAGE_STATE_MAX_AGE="${USAGE_STATE_MAX_AGE:-1800}"
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
  printf '%s %s /usr/local/bin/claude-watchdog >> /var/log/claude-watchdog.log 2>&1\n' \
    "$schedule" "$CLAUDE_USER" > /etc/cron.d/claude-watchdog
  chmod 0644 /etc/cron.d/claude-watchdog
  service cron start >/dev/null 2>&1 || cron
else
  rm -f /etc/cron.d/claude-watchdog
  echo "Watchdog disabled (WATCHDOG_ENABLED=false)"
fi

# --- the console ------------------------------------------------------------
start_console() {
  as_claude tmux -S "$TMUX_SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 \
    -c "$WORKSPACE" "claude ${CLAUDE_ARGS}"
  # Root (health check, `console` via docker exec) needs to reach the socket.
  chmod 0660 "$TMUX_SOCKET" 2>/dev/null || true
}

console_alive() {
  as_claude tmux -S "$TMUX_SOCKET" has-session -t "$SESSION" 2>/dev/null
}

console_alive || start_console

cat <<MSG
Container ready. Workspace: $WORKSPACE
  Running as:         ${CLAUDE_USER} (${PUID}:${PGID}), PID 1 is root
  Live console:       docker exec -it <container> console        (detach: Ctrl-b d)
  Maintenance shell:  docker exec -it <container> bash
  Watchdog log:       docker exec <container> tail -f /var/log/claude-watchdog.log
  Watchdog schedule:  ${WATCHDOG_ENABLED:-true} @ every ${WATCHDOG_INTERVAL_MIN:-10} min
MSG

# Keep PID 1 alive, and resurrect the console if it ever exits.
while true; do
  sleep 30
  if ! console_alive; then
    echo "$(date -Iseconds) console gone, restarting"
    start_console
  fi
done
