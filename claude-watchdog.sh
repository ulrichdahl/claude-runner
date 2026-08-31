#!/usr/bin/env bash
# Runs from cron (default every 10 minutes, WATCHDOG_INTERVAL_MIN).
#
# cron gives a job an almost-empty environment, so the settings that came
# from docker-compose are read back from the file the entrypoint wrote
# rather than inherited.
#
# Watches the live console. If Claude stopped because it hit a usage limit,
# work out when that window resets and, once the reset time has passed, type
# "continue" into the same console so the run picks back up.
#
# Three sources, best first:
#
#   1. /var/lib/claude-watchdog/usage.json, written by the status line on
#      every assistant message. Structured and exact: `resets_at` is an
#      epoch and the 5-hour and 7-day windows are reported separately, so
#      there is no guessing which one stopped the session. Requires a
#      Claude.ai Pro or Max plan and at least one API response.
#   2. The console pane text, parsed for a limit message.
#   3. Typing `/usage` into the console and parsing what comes back.
#
# The 7-day window outranks the 5-hour one wherever both are known: resuming
# on a session reset while the weekly budget is gone would just stop again.
set -uo pipefail

# Written by entrypoint.sh from the container environment.
[[ -f /etc/claude-watchdog.env ]] && . /etc/claude-watchdog.env

SESSION="${CLAUDE_TMUX_SESSION:-claude}"
TMUX_SOCKET="${TMUX_SOCKET:-/run/claude/tmux.sock}"
STATE_DIR=/var/lib/claude-watchdog
RESUME_AT="$STATE_DIR/resume_at"        # epoch seconds
SCOPE_FILE="$STATE_DIR/scope"           # session | weekly
LAST_USAGE="$STATE_DIR/last_usage_probe"
LAST_NUDGE="$STATE_DIR/last_nudge"
PARSER=/usr/local/lib/watchdog_parse.py
USAGE_READER=/usr/local/lib/usage_state.py
USAGE_STATE_FILE="${USAGE_STATE_FILE:-$STATE_DIR/usage.json}"
export USAGE_STATE_FILE

USAGE_PROBE_MIN_INTERVAL="${USAGE_PROBE_MIN_INTERVAL:-3600}"  # /usage at most hourly
NUDGE_MIN_INTERVAL="${NUDGE_MIN_INTERVAL:-900}"               # 15 min between nudges
USAGE_PROBE_WAIT="${USAGE_PROBE_WAIT:-8}"                     # seconds to let /usage render
PANE_LINES="${PANE_LINES:-300}"                               # scrollback to inspect
CONTINUE_TEXT="${CONTINUE_TEXT:-continue}"

mkdir -p "$STATE_DIR"
log() { echo "$(date -Iseconds) $*"; }
now() { date +%s; }
stamp_age() { local f=$1; [[ -f $f ]] && echo $(( $(now) - $(cat "$f") )) || echo 999999; }

if ! tmux -S "$TMUX_SOCKET" has-session -t "$SESSION" 2>/dev/null; then
  log "no tmux session '$SESSION' -- nothing to watch"
  exit 0
fi

capture() { tmux -S "$TMUX_SOCKET" capture-pane -p -S "-$PANE_LINES" -t "$SESSION"; }

send_line() {
  tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION" -l "$1"
  sleep 1
  tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION" Enter
}

# --- source 1: the status line's usage file --------------------------------
usage_file_state="$(python3 "$USAGE_READER" 2>/dev/null || echo '{}')"
if [[ "$(jq -r '.usable // false' <<<"$usage_file_state")" == "true" ]]; then
  file_limited="$(jq -r .limited <<<"$usage_file_state")"
  file_reason="$(jq -r .reason <<<"$usage_file_state")"

  if [[ "$file_limited" != "true" ]]; then
    rm -f "$RESUME_AT" "$SCOPE_FILE"
    exit 0
  fi

  scope="$(jq -r .scope <<<"$usage_file_state")"
  reset_epoch="$(jq -r '.reset_epoch // empty' <<<"$usage_file_state")"
  echo "$reset_epoch" > "$RESUME_AT"
  echo "$scope" > "$SCOPE_FILE"

  if (( reset_epoch > $(now) )); then
    log "limited (${scope}, from usage file: ${file_reason}) until $(date -d "@$reset_epoch" -Iseconds), waiting"
    exit 0
  fi

  if (( $(stamp_age "$LAST_NUDGE") < NUDGE_MIN_INTERVAL )); then
    log "already nudged $(stamp_age "$LAST_NUDGE")s ago, holding off"
    exit 0
  fi

  log "${scope} window reset (usage file) -- telling the console to continue"
  send_line "$CONTINUE_TEXT"
  date +%s > "$LAST_NUDGE"
  rm -f "$RESUME_AT" "$SCOPE_FILE"
  exit 0
fi

log "usage file not usable ($(jq -r '.reason // "unknown"' <<<"$usage_file_state")) -- falling back to reading the console"

# --- source 2: the console pane --------------------------------------------
state="$(capture | python3 "$PARSER" pane)"
limited="$(jq -r .limited <<<"$state")"
scope="$(jq -r .scope <<<"$state")"
reset_epoch="$(jq -r '.reset_epoch // empty' <<<"$state")"

if [[ "$limited" != "true" ]]; then
  # Console is not sitting on a limit message. Any pending resume is moot.
  rm -f "$RESUME_AT" "$SCOPE_FILE"
  exit 0
fi

# A previously recorded resume time still in the future: just wait it out,
# no /usage probe needed.
if [[ -f "$RESUME_AT" ]]; then
  saved="$(cat "$RESUME_AT")"
  if [[ "$saved" =~ ^[0-9]+$ ]] && (( saved > $(now) )); then
    log "limited (${scope}), waiting until $(date -d "@$saved" -Iseconds)"
    exit 0
  fi
fi

# --- source 3: type /usage into the console --------------------------------
# Console didn't tell us enough: ask /usage. Also do this when the console
# only said "session" -- the message alone can't rule out the weekly window
# being the real blocker.
if [[ -z "$reset_epoch" || "$scope" != "weekly" ]]; then
  if (( $(stamp_age "$LAST_USAGE") >= USAGE_PROBE_MIN_INTERVAL )); then
    log "probing /usage in the console (pane said scope=$scope reset=${reset_epoch:-none})"
    date +%s > "$LAST_USAGE"
    send_line "/usage"
    sleep "$USAGE_PROBE_WAIT"
    usage_state="$(capture | python3 "$PARSER" usage)"
    tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION" Escape 2>/dev/null || true
    log "usage says: $usage_state"
    u_reset="$(jq -r '.reset_epoch // empty' <<<"$usage_state")"
    u_scope="$(jq -r .scope <<<"$usage_state")"
    u_limited="$(jq -r .limited <<<"$usage_state")"
    if [[ -n "$u_reset" ]] && [[ "$u_limited" == "true" || -z "$reset_epoch" ]]; then
      reset_epoch="$u_reset"
      scope="$u_scope"
    fi
  fi
fi

if [[ -z "$reset_epoch" ]]; then
  log "limited but no reset time from console or /usage -- rechecking in 10 minutes"
  exit 0
fi

echo "$reset_epoch" > "$RESUME_AT"
echo "$scope" > "$SCOPE_FILE"

if (( reset_epoch > $(now) )); then
  log "limited (${scope}) until $(date -d "@$reset_epoch" -Iseconds), waiting"
  exit 0
fi

if (( $(stamp_age "$LAST_NUDGE") < NUDGE_MIN_INTERVAL )); then
  log "already nudged $(stamp_age "$LAST_NUDGE")s ago, holding off"
  exit 0
fi

log "${scope} limit window reset -- telling the console to continue"
send_line "$CONTINUE_TEXT"
date +%s > "$LAST_NUDGE"
rm -f "$RESUME_AT" "$SCOPE_FILE"
