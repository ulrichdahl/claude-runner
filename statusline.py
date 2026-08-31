#!/usr/bin/env python3
"""Claude Code status line: render usage, and publish it for the watchdog.

Claude Code runs this on every assistant message (and on a refreshInterval
timer), handing it the session JSON on stdin. Two jobs:

  1. Write the rate-limit windows to a state file the cron watchdog reads.
     This is a far better source than scraping the console: `resets_at` is
     an exact epoch, and the 5-hour and 7-day windows are reported
     separately, so the watchdog never has to guess which one stopped it.

  2. Print the status line itself.

`rate_limits` is only present for Claude.ai Pro and Max subscribers, and
only after the first API response in a session. Each window can be absent
independently, and Claude Code drops a window once its `resets_at` passes.
So every read here is defensive, and the state file records when it was
written so the watchdog can judge staleness.
"""
import json
import os
import sys
import time

STATE_FILE = os.environ.get("USAGE_STATE_FILE", "/var/lib/claude-watchdog/usage.json")

RESET = "\033[0m"
DIM = "\033[2m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
CYAN = "\033[36m"


def publish(data):
    """Write the rate-limit windows where the watchdog can find them."""
    limits = data.get("rate_limits") or {}
    out = {"written_at": int(time.time()), "windows": {}}

    for name in ("five_hour", "seven_day", "spend_limit"):
        w = limits.get(name)
        if not isinstance(w, dict):
            continue
        pct = w.get("used_percentage")
        resets = w.get("resets_at")
        if pct is None and resets is None:
            continue
        out["windows"][name] = {"used_percentage": pct, "resets_at": resets}

    model = data.get("model") or {}
    out["model"] = model.get("display_name")
    out["session_id"] = data.get("session_id")

    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        # Atomic: the watchdog may read this at any moment from cron.
        tmp = f"{STATE_FILE}.{os.getpid()}.tmp"
        with open(tmp, "w") as fh:
            json.dump(out, fh)
        os.replace(tmp, STATE_FILE)
    except OSError:
        pass  # A broken status line must never take the session down.


def color_for(pct):
    if pct is None:
        return DIM
    if pct >= 90:
        return RED
    if pct >= 70:
        return YELLOW
    return GREEN


def fmt_reset(epoch):
    """Compact 'time until reset': 3h12m, 45m, or a weekday for far-off ones."""
    if not epoch:
        return None
    delta = int(epoch) - int(time.time())
    if delta <= 0:
        return "now"
    d, rem = divmod(delta, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d}d{h}h"
    if h:
        return f"{h}h{m:02d}m"
    return f"{m}m"


def window_segment(label, w):
    if not w:
        return None
    pct = w.get("used_percentage")
    resets = fmt_reset(w.get("resets_at"))
    if pct is None and resets is None:
        return None
    body = f"{pct:.0f}%" if isinstance(pct, (int, float)) else "?"
    if resets:
        body += f" {DIM}→{resets}{RESET}{color_for(pct)}"
    return f"{color_for(pct)}{label} {body}{RESET}"


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        print("claude-runner")
        return

    publish(data)

    parts = []

    model = (data.get("model") or {}).get("display_name")
    if model:
        parts.append(f"{CYAN}{model}{RESET}")

    ctx = data.get("context_window") or {}
    used = ctx.get("used_percentage")
    if isinstance(used, (int, float)):
        parts.append(f"{color_for(used)}ctx {used:.0f}%{RESET}")

    limits = data.get("rate_limits") or {}
    for label, key in (("session", "five_hour"), ("week", "seven_day"),
                       ("spend", "spend_limit")):
        seg = window_segment(label, limits.get(key))
        if seg:
            parts.append(seg)

    if not limits:
        # Pro/Max only, and only after the first API response of a session.
        parts.append(f"{DIM}usage n/a{RESET}")

    cost = (data.get("cost") or {}).get("total_cost_usd")
    if isinstance(cost, (int, float)) and cost > 0:
        parts.append(f"{DIM}${cost:.2f}{RESET}")

    print(f" {DIM}|{RESET} ".join(parts))


if __name__ == "__main__":
    main()
