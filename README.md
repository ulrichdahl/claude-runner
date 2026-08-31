# claude-runner

A self-contained Docker image that keeps a **Claude Code session running
continuously** — including across usage-limit stops.

Two things make it different from running `claude` in a terminal:

1. **The session is the container.** PID 1 keeps a `claude` process alive
   inside tmux. Attach to it, detach, close your laptop, come back a day
   later and attach again — it's the same session, exactly where you left it.
2. **It resumes itself after a rate limit.** A cron job checks every 10
   minutes whether the session stopped on a usage limit. If it did, it works
   out when that limit window resets — reading `/usage` in the session when
   the stop message alone doesn't say — and types `continue` once the window
   has actually reset.

Nothing in the image is tied to a particular project. Mount whatever you
want at `/workspace`, or mount nothing at all and it still runs.

## What's inside

- **Claude Code** (`@anthropic-ai/claude-code`, installed from npm at build)
- **The [caveman](https://github.com/JuliusBrussee/caveman) plugin**,
  preinstalled and activated
- **CLI tooling:** `git`, `gh` (GitHub), `glab` (GitLab), `sentry-cli`,
  `diff`, `patch`, `python`/`python3`, `curl`, `jq`, `rg`, `wget`, `unzip`,
  `ssh`
- `tmux`, `cron`, `tzdata`

Base image is `node:20-slim`. `gh` and `glab` are pinned and installed
arch-aware (amd64 and arm64 both work).

## Quick start

```bash
git clone https://github.com/ulrichdahl/claude-runner.git
cd claude-runner
cp .env.example .env
$EDITOR .env                 # set WORKSPACE_DIR and TZ
docker compose up -d --build
```

Then log in once:

```bash
docker exec -it claude-console claude
```

`~/.claude` is a named volume, so the login survives rebuilds.

> **Set `TZ` to your real timezone.** The reset times Claude prints are
> local, and the watchdog compares them against the container clock. Getting
> this wrong means resuming at the wrong hour.

## Using it

**Attach to the live console:**

```bash
docker exec -it claude-console tmux attach -t claude
```

Detach with `Ctrl-b d`. The session keeps running — detaching sends it no
signal — so reattach as often as you like and it's the same ongoing
conversation.

### Why tmux at all?

Not for persistence: a bare `claude` as PID 1 with `docker attach` would
survive a `Ctrl-P Ctrl-Q` detach just as well. tmux is there because the
**watchdog** needs to read and drive the session:

- `tmux capture-pane -p` renders the current screen as plain text, which is
  what the limit parser reads. The alternative, `docker logs`, is an
  append-only stream of ANSI cursor movements — Claude Code redraws in
  place, so reconstructing the current screen from it isn't practical.
- `tmux send-keys` injects `/usage` and `continue` from cron without
  fighting an interactive session for the container's stdin.

A side benefit: with `claude` as PID 1, a reflexive `Ctrl-C` while attached
kills PID 1 and takes the container down. Inside tmux it just interrupts
Claude.

The usual tmux annoyances are configured away in `tmux.conf` (installed to
`/etc/tmux.conf`): **mouse mode is off**, so your terminal's own click-drag
selection and copy work normally, and the **alternate screen is disabled**,
so your terminal's native scrollback and scroll wheel work instead of
tmux copy-mode.

**Get a maintenance shell** that doesn't disturb the console:

```bash
docker exec -it claude-console bash
```

**Watch the watchdog:**

```bash
docker exec claude-console tail -f /var/log/claude-watchdog.log
```

## How the rate-limit watchdog works

`/usr/local/bin/claude-watchdog` runs from cron every 10 minutes and logs to
`/var/log/claude-watchdog.log`. Each tick:

1. **Capture the console pane.** If the tail doesn't show a usage-limit
   stop, do nothing. Warnings like *"approaching your weekly limit"* or
   *"12% remaining"* are explicitly not treated as a stop.
2. **Find the reset time in the message.** Recognised formats include
   `Claude AI usage limit reached|<epoch>`, ISO 8601 timestamps,
   `resets 3:00am (Europe/Copenhagen)`, and `Resets Mon at 9am`.
3. **Fall back to `/usage`** when the message has no reset time, or when it
   doesn't say whether the limit was the 5-hour session window or the weekly
   one. The watchdog types `/usage` into the console, waits for it to
   render, and parses the result. This probe is rate-limited to once an
   hour.

   A weekly exhaustion outranks a session one. Resuming when the 5-hour
   window reset but the weekly budget is gone would just stop again
   immediately, so the watchdog waits for the weekly reset instead.
4. **Store the reset time.** While it's still in the future, every tick is a
   cheap no-op — no pane parsing beyond step 1, no `/usage` probe.
5. **Resume.** Once the reset time has passed, type `continue` into the
   console (override with `CONTINUE_TEXT`), then hold off at least 15
   minutes before ever nudging again.

State lives in `/var/lib/claude-watchdog/`.

### Unattended runs

For a session that should keep working with nobody there to answer
permission prompts, set `CLAUDE_ARGS=--permission-mode acceptEdits` in
`.env` and scope what gets auto-approved with a `.claude/settings.json` in
the mounted workspace.

## Configuration

Everything is set from `.env` / `docker-compose.yml`. Runtime settings take
effect on `docker compose up -d` — **no rebuild** except for the tool
versions.

| Variable | Default | Meaning |
|---|---|---|
| `CONTAINER_NAME` | `claude-console` | Container name |
| `WORKSPACE_DIR` | `./workspace` | Host directory mounted at `/workspace` |
| `TZ` | `UTC` | Container timezone; must match the times Claude prints |
| `CLAUDE_ARGS` | *(empty)* | Extra flags for the console's `claude` process |
| `CLAUDE_TMUX_SESSION` | `claude` | tmux session name |
| `WATCHDOG_ENABLED` | `true` | `false` removes the cron job entirely |
| `WATCHDOG_INTERVAL_MIN` | `10` | Watchdog cron interval, 1–59 minutes |
| `CONTINUE_TEXT` | `continue` | What the watchdog types on resume |
| `USAGE_PROBE_MIN_INTERVAL` | `3600` | Seconds between two `/usage` probes |
| `NUDGE_MIN_INTERVAL` | `900` | Seconds between two resume nudges |
| `USAGE_PROBE_WAIT` | `8` | Seconds to let `/usage` render before reading it |
| `PANE_LINES` | `300` | Lines of scrollback the watchdog inspects |
| `GH_VERSION` | `2.63.2` | build arg — rebuild to change |
| `GLAB_VERSION` | `1.52.0` | build arg — rebuild to change |

Cron jobs run with an almost-empty environment, so these don't reach the
watchdog by inheritance. `entrypoint.sh` writes them to
`/etc/claude-watchdog.env` on every start and the watchdog sources that
file; it also regenerates `/etc/cron.d/claude-watchdog` from
`WATCHDOG_INTERVAL_MIN`, and deletes it when `WATCHDOG_ENABLED=false`.

## Files

| File | Role |
|---|---|
| `Dockerfile` | Image: tools, Claude Code, caveman plugin, default cron entry |
| `entrypoint.sh` | PID 1 — starts cron, starts/keeps the tmux console, writes watchdog config |
| `claude-watchdog.sh` | The 10-minute check; installed as `/usr/local/bin/claude-watchdog` |
| `watchdog_parse.py` | Parses pane and `/usage` text into `{limited, scope, reset_epoch}` |
| `tmux.conf` | Console ergonomics — mouse off, no alternate screen |
| `docker-compose.yml` | All configuration |

`watchdog_parse.py` is a standalone script you can test by hand:

```bash
echo "You've hit your session limit - resets 3:00am (Europe/Copenhagen)" \
  | python3 watchdog_parse.py pane
# {"limited": true, "scope": "session", "reset_epoch": 1788224400}
```

## Caveats

**The image is not build-verified.** It was written and syntax-checked, but
`docker build` needs network access for the `gh`, `glab`, `sentry-cli` and
npm downloads, and the plugin install needs to reach GitHub. Build it once
and watch the output before trusting it unattended.

**The limit-message wording is not authoritative.** The exact text Claude
Code prints when it stops on a usage limit isn't something this repo can pin
down for every version, so the parser matches several known phrasings and
falls back to the `/usage` probe. If the log says `limited but no reset
time`, or says nothing while the console is plainly stopped, add the real
text to the pattern lists in `watchdog_parse.py` — `LIMIT_MARKERS` for
detection, `parse_reset` for the time. Pull requests with real-world
phrasings are welcome.

**The watchdog types into your live session.** It sends `/usage` and
`continue` to the same tmux pane you attach to. If you're typing there when
a tick fires, your input and the watchdog's can interleave.

## License

MIT — see [LICENSE](LICENSE).
