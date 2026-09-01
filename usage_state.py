#!/usr/bin/env python3
"""Read the status line's usage file and decide what the watchdog should do.

Prints one JSON object:

    {"usable": bool, "limited": bool, "scope": "session"|"weekly"|null,
     "reset_epoch": int|null, "age": int, "reason": str}

`usable` is false when the file is missing, malformed, or too stale to
trust -- the watchdog then falls back to reading the console pane.

"limited" here means a window is exhausted. Claude Code drops a window from
the payload once its `resets_at` passes, so a window that is at 100% and
still present is genuinely still blocking. The 7-day window outranks the
5-hour one: resuming when the short window reset but the weekly budget is
gone would just stop again.
"""
import json
import os
import sys
import time

STATE_FILE = os.environ.get("USAGE_STATE_FILE", "/var/lib/claude-watchdog/usage.json")
# The status line runs on every assistant message and on its refreshInterval
# timer. Older than this and we can't tell whether it reflects the present.
MAX_AGE = int(os.environ.get("USAGE_STATE_MAX_AGE", "1800"))
# A window this full is treated as blocking.
FULL_PCT = float(os.environ.get("USAGE_FULL_PCT", "99.5"))


def out(**kw):
    base = {"usable": False, "limited": False, "scope": None,
            "reset_epoch": None, "age": -1, "reason": ""}
    base.update(kw)
    print(json.dumps(base))
    sys.exit(0)


def main():
    try:
        with open(STATE_FILE) as fh:
            data = json.load(fh)
    except FileNotFoundError:
        out(reason="no usage file yet")
    except (OSError, json.JSONDecodeError, ValueError):
        out(reason="usage file unreadable")

    written = data.get("written_at")
    if not isinstance(written, int):
        out(reason="usage file has no timestamp")

    age = int(time.time()) - written
    if age > MAX_AGE:
        out(age=age, reason=f"usage file stale ({age}s > {MAX_AGE}s)")

    windows = data.get("windows") or {}
    if not windows:
        # Fresh, but with nothing to say: not a Pro/Max plan, no API response
        # yet, or a Claude Code too old to report rate_limits. This is NOT
        # evidence that nothing is blocking -- treating it as such makes a
        # real limit stop invisible -- so hand over to the console parser.
        out(age=age, reason="no rate-limit windows reported")

    now = int(time.time())

    def full(name):
        w = windows.get(name) or {}
        pct = w.get("used_percentage")
        resets = w.get("resets_at")
        if not isinstance(pct, (int, float)) or pct < FULL_PCT:
            return None
        if not isinstance(resets, int) or resets <= now:
            return None
        return resets

    weekly = full("seven_day")
    if weekly:
        out(usable=True, limited=True, scope="weekly", reset_epoch=weekly,
            age=age, reason="7-day window exhausted")

    session = full("five_hour")
    if session:
        out(usable=True, limited=True, scope="session", reset_epoch=session,
            age=age, reason="5-hour window exhausted")

    out(usable=True, age=age, reason="no window exhausted")


if __name__ == "__main__":
    main()
