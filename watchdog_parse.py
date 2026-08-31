#!/usr/bin/env python3
"""Parse a Claude Code tmux pane for a rate-limit stop and its reset time.

Reads pane text on stdin, prints one JSON object on stdout:

    {"limited": bool, "scope": "session"|"weekly"|"unknown", "reset_epoch": int|null}

Two modes:
  pane   -- ordinary console text; decide whether the session is stopped on a
            limit, and pull a reset time out of it if one was printed.
  usage  -- output of the `/usage` command; used as the fallback when the
            pane text says "limited" but carries no reset time, and as the
            only reliable way to tell a weekly limit from a 5-hour one.

Time formats seen in the wild, all handled:
  "Claude AI usage limit reached|1756654800"   (epoch, print mode)
  "resets 3:00am (Europe/Copenhagen)"
  "resets at 10pm"
  "Resets Mon Sep 1 at 9am"
  ISO 8601 timestamps
"""
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

LIMIT_MARKERS = [
    r"usage limit reached",
    r"session limit reached",
    r"you'?ve hit your (session|usage|weekly) limit",
    r"\b5-hour limit\b.*\breached\b",
    r"weekly limit reached",
    r"out of (session|weekly) (usage|capacity)",
    r"rate[- ]limit(ed)?\b.*\bresets\b",
    r"limit reached[^\n]*\bresets\b",
]

# "approaching"/"remaining" warnings are NOT a stop.
NEGATIVE_MARKERS = [
    r"approaching",
    r"remaining",
    r"you have used",
]

WEEKLY_MARKERS = [r"\bweekly\b", r"\bper week\b", r"\bthis week\b"]

DAYS = {
    "mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6,
}


def tz_from(text, default="UTC"):
    m = re.search(r"\(([A-Za-z]+(?:/[A-Za-z_+\-0-9]+)?)\)", text)
    name = m.group(1) if m else default
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("UTC")


def parse_reset(text, now):
    """Return epoch seconds for the next reset mentioned in text, or None."""
    # 1. bare epoch, e.g. "usage limit reached|1756654800"
    m = re.search(r"limit reached\|(\d{10,13})", text, re.I)
    if m:
        v = int(m.group(1))
        return v // 1000 if v > 10**11 else v

    # 2. ISO 8601
    m = re.search(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:?\d{2})?", text)
    if m:
        raw = m.group(0).replace("Z", "+00:00").replace(" ", "T")
        try:
            dt = datetime.fromisoformat(raw)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return int(dt.timestamp())
        except ValueError:
            pass

    # 3. clock time near the word "reset", optionally with a weekday
    m = re.search(
        r"reset[a-z]*\s*(?:at\s+)?"
        r"(?:(?P<day>mon|tue|wed|thu|fri|sat|sun)[a-z]*\s*"
        r"(?:[A-Za-z]{3,9}\s*\d{1,2})?\s*(?:at\s+)?)?"
        r"(?P<h>\d{1,2})(?::(?P<m>\d{2}))?\s*(?P<ap>am|pm)?",
        text, re.I)
    if not m:
        return None

    tz = tz_from(text)
    local_now = now.astimezone(tz)
    hour = int(m.group("h"))
    minute = int(m.group("m") or 0)
    ap = (m.group("ap") or "").lower()
    if ap == "pm" and hour < 12:
        hour += 12
    elif ap == "am" and hour == 12:
        hour = 0
    if hour > 23 or minute > 59:
        return None

    target = local_now.replace(hour=hour, minute=minute, second=0, microsecond=0)

    day = (m.group("day") or "").lower()[:3]
    if day in DAYS:
        delta = (DAYS[day] - target.weekday()) % 7
        target += timedelta(days=delta)
        if target <= local_now:
            target += timedelta(days=7)
    elif target <= local_now:
        target += timedelta(days=1)

    return int(target.timestamp())


def scope_of(text):
    return "weekly" if any(re.search(p, text, re.I) for p in WEEKLY_MARKERS) else "session"


def limit_lines(text):
    out = []
    for line in text.splitlines():
        if any(re.search(p, line, re.I) for p in LIMIT_MARKERS) and \
           not any(re.search(n, line, re.I) for n in NEGATIVE_MARKERS):
            out.append(line)
    return out


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "pane"
    text = sys.stdin.read()
    now = datetime.now(timezone.utc)
    result = {"limited": False, "scope": "unknown", "reset_epoch": None}

    if mode == "usage":
        # /usage prints both windows. Take the one that is actually exhausted;
        # a weekly exhaustion outranks a session one, since resuming after the
        # 5-hour window will just stop again.
        blocks = re.split(r"\n(?=\s*\S[^\n]*(?:limit|session|week))", text, flags=re.I)
        weekly, session = None, None
        for b in blocks:
            if not re.search(r"reset", b, re.I):
                continue
            epoch = parse_reset(b, now)
            if epoch is None:
                continue
            if any(re.search(p, b, re.I) for p in WEEKLY_MARKERS):
                weekly = weekly or (epoch, bool(limit_lines(b)) or "100%" in b)
            else:
                session = session or (epoch, bool(limit_lines(b)) or "100%" in b)
        exhausted_weekly = weekly and weekly[1]
        if exhausted_weekly:
            result.update(limited=True, scope="weekly", reset_epoch=weekly[0])
        elif session:
            result.update(limited=bool(session[1]), scope="session",
                          reset_epoch=session[0])
        elif weekly:
            result.update(scope="weekly", reset_epoch=weekly[0])
        print(json.dumps(result))
        return

    hits = limit_lines(text)
    if not hits:
        print(json.dumps(result))
        return

    # Only the tail matters: an old limit message further up the scrollback is
    # history, not the current state.
    blob = "\n".join(hits[-3:])
    result["limited"] = True
    result["scope"] = scope_of(blob)
    result["reset_epoch"] = parse_reset(blob, now)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
