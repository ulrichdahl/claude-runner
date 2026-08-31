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

The whole of `/root` is a named volume, so the login and settings survive
rebuilds — see [What persists](#what-persists).

> **Set `TZ` to your real timezone.** The reset times Claude prints are
> local, and the watchdog compares them against the container clock. Getting
> this wrong means resuming at the wrong hour.

## Using it

**Attach to the live console:**

```bash
docker exec -it claude-console console
```

(`console` is a small wrapper for `tmux attach -t claude`; the long form
works too.)

Detach with `Ctrl-b d`. The session keeps running — detaching sends it no
signal — so reattach as often as you like and it's the same ongoing
conversation.

### Web terminals (Coolify, Portainer, …)

Web admin panels give you `docker exec`, not `docker attach` — Coolify's
terminal runs:

```
docker exec -it <container> sh -c 'if [ -n "$SHELL" ] && [ -x "$SHELL" ]; then exec $SHELL; else sh; fi'
```

This is a good reason the session lives in tmux rather than being PID 1's
own stdio: `exec` starts a *new* process and cannot join PID 1's streams, so
a `docker attach`-style design would be unreachable from those panels
entirely. Through tmux it's just:

```
console
```

in the web terminal.

#### Controlling which shell Coolify opens

That `$SHELL` test is the only lever, and it reads the **container's
environment** — so set it in compose:

```yaml
environment:
  SHELL: /bin/bash
```

The image already does this, which is why you land in bash rather than `sh`.
Point it anywhere executable and Coolify will exec that instead.

Two caveats:

- `$SHELL` is not Coolify-specific. Claude Code's own shell tool reads it
  too, so don't point it at something that isn't a real shell — attaching
  the console this way would break Claude's ability to run commands.
- Coolify's terminal arrives as **root**, since the image has no `USER`
  directive (PID 1 must be root). Use `console` to attach to the session as
  `claude`, or `runuser -u claude -- bash` for an ordinary unprivileged
  shell. Root's `.bashrc` prints both as a reminder.

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

`tmux.conf` (installed to `/etc/tmux.conf`) keeps the console looking right:
**truecolor** via `tmux-256color` + `RGB`, **mouse off** so your terminal's
own click-drag selection works, and `aggressive-resize` so the pane follows
the client actually attached.

One thing it deliberately does **not** do is disable the alternate screen.
v0.1.1 did that so the terminal's native scrollback would capture the
session; that is fine for a shell printing lines and wrong for a full-screen
TUI, because Claude's repaints land in the scrollback buffer and the display
smears. v0.5.1 reverted it. Scroll back with tmux copy-mode (`Ctrl-b [`,
`q` to leave).

**Get a maintenance shell** that doesn't disturb the console:

```bash
docker exec -it claude-console bash
```

The shell is bash throughout, not `sh`: it's root's login shell, it's what
`$SHELL` points at (so anything that spawns a shell, Claude Code's shell
tool included, gets bash), and it's tmux's `default-shell` for any new
window or pane you open in the console.

**Watch the watchdog:**

```bash
docker exec claude-console tail -f /var/log/claude-watchdog.log
```

## Usage reporting

Claude Code hands a configured **status line** command the full session JSON
on stdin — including `rate_limits`, with the 5-hour and 7-day windows
reported separately, each with a `used_percentage` and an exact `resets_at`
epoch. The image wires up a status line that does two things with it:

**1. Shows it.** Always visible at the bottom of the console:

```
Opus 5 | ctx 73% | session 24% →3h12m | week 91% →3d5h | $1.23
```

Percentages turn yellow past 70% and red past 90%.

**2. Publishes it** to `/var/lib/claude-watchdog/usage.json`, written
atomically so cron can read it at any moment:

```json
{
  "written_at": 1788199883,
  "windows": {
    "five_hour": {"used_percentage": 23.5, "resets_at": 1788211403},
    "seven_day": {"used_percentage": 91.2, "resets_at": 1788479883}
  },
  "model": "Opus 5"
}
```

This is a much better watchdog input than reading the console: `resets_at`
is exact rather than parsed out of prose, and session vs. weekly is stated
rather than inferred.

The status line runs on every assistant message, and on a timer
(`STATUSLINE_REFRESH_SECONDS`, default 60) so the file keeps up while the
session sits idle. It's installed by merging into
`~/.claude/settings.json` — anything else in that file is preserved, and
`STATUSLINE_ENABLED=false` removes it again.

> `rate_limits` is only present for Claude.ai **Pro and Max** plans, and only
> after the first API response in a session. Each window can be absent
> independently, and Claude Code drops a window once its `resets_at` passes.
> On other plans the status line shows `usage n/a` and the watchdog falls
> back to reading the console.

## How the rate-limit watchdog works

`/usr/local/bin/claude-watchdog` runs from cron every 10 minutes and logs to
`/var/log/claude-watchdog.log`. It has three sources, and uses the best one
available:

**1. `usage.json` from the status line.** Structured and exact. A window
counts as blocking when it's at 100% *and* still present — Claude Code drops
a window once its `resets_at` passes, so a full window that's still there is
genuinely still blocking. Ignored if the file is missing, malformed, or
older than `USAGE_STATE_MAX_AGE` (default 30 min), in which case:

**2. The console pane.** Parsed for a limit message. Recognised formats
include `Claude AI usage limit reached|<epoch>`, ISO 8601 timestamps,
`resets 3:00am (Europe/Copenhagen)` and `Resets Mon at 9am`. Warnings like
*"approaching your weekly limit"* are explicitly not treated as a stop.

**3. Typing `/usage` into the console**, when the pane text has no reset time
or doesn't distinguish session from weekly. Rate-limited to once an hour.

In all three, **the 7-day window outranks the 5-hour one.** Resuming when
the short window reset but the weekly budget is gone would just stop again.

Once a reset time is known it's stored, so every tick until then is a cheap
no-op. When it passes, the watchdog types `continue` into the console
(override with `CONTINUE_TEXT`) and then holds off at least 15 minutes
before nudging again.

State lives in `/var/lib/claude-watchdog/`.

### Unattended runs

For a session that should keep working with nobody there to answer
permission prompts, set `CLAUDE_ARGS=--permission-mode acceptEdits` in
`.env` and scope what gets auto-approved with a `.claude/settings.json` in
the mounted workspace.

## What persists

Claude Code splits its state across **two** locations:

| Path | Holds |
|---|---|
| `~/.claude/` | Credentials, plugins, session transcripts, `settings.json` |
| `~/.claude.json` | Onboarding state, user id, per-project settings, marketplace/plugin flags |

`~/.claude.json` is a sibling of the directory, not inside it. Mounting only
`~/.claude` therefore loses it on every rebuild — the login token survives,
but onboarding, trust prompts and plugin state reset, which reads as
"it didn't save my settings".

So the volume covers the whole home directory of the runtime user:

```yaml
volumes:
  - claude-home:/home/claude
```

Docker seeds a fresh named volume from the image's directory contents, so
the caveman plugin installed at build time still lands in it on first start.

### Upgrading from an older volume

Before v0.3.0 the volume was `claude-config` mounted at `/root/.claude`;
v0.3.0 used `claude-home` at `/root`. From v0.4.0 it is `claude-home` at
`/home/claude`, because the session no longer runs as root.

Coming from v0.3.0 the volume name is unchanged and the contents are the
right shape, so it just works. Coming from `claude-config`, its contents are
`~/.claude`'s at the volume root, so copy them into place:

```bash
docker run --rm \
  -v claude-runner_claude-config:/from \
  -v claude-runner_claude-home:/to \
  alpine sh -c 'mkdir -p /to/.claude && cp -a /from/. /to/.claude/ && chown -R 1000:1000 /to'
```

Adjust the `claude-runner_` prefix to your compose project name
(`docker volume ls` to check). `~/.claude.json` never existed in the old
volume, so onboarding still runs once.

## Running unprivileged

Claude runs as an unprivileged `claude` user, not root.

The reason that matters in practice is **file ownership on your bind
mount**: a root-run Claude writing into `/workspace` leaves root-owned files
in your project directory on the host. Set `PUID`/`PGID` to your own ids
(`id -u` / `id -g`, usually 1000) and everything it writes is owned by you.

The secondary reason is blast radius. No Docker socket is mounted, so
there's no trivial escalation path, but container root is still uid 0 to the
kernel, and with `--permission-mode acceptEdits` a root-run Claude could
rewrite the very scripts supervising it.

**PID 1 stays root** — it needs to be, to remap the user to `PUID`/`PGID`,
chown the workspace and start cron. It drops to `claude` for the session
itself. cron also stays root, but the watchdog does not: `/etc/cron.d`
entries have a user column, so the job runs as `claude`.

### Workspace ownership

On every start, the entrypoint makes sure `PUID` can write to `/workspace`:

| `CHOWN_WORKSPACE` | Behavior |
|---|---|
| `auto` (default) | `chown -R` only when the workspace's top-level owner isn't `PUID`. A recursive chown of a large project every start is expensive, so this skips it once it's correct. |
| `always` | Force it on every start. |
| `never` | Skip entirely — for read-only or NFS-backed mounts. |

If the user still can't write there afterwards, the entrypoint says so
rather than letting Claude fail confusingly later.

### The tmux socket

Because the session belongs to `claude` while health checks and `docker
exec` arrive as root, tmux uses an explicit socket at `/run/claude/tmux.sock`
rather than the per-uid default under `/tmp`. Every script agrees on it via
`TMUX_SOCKET`.

## Health check

The container reports health via `/usr/local/bin/claude-healthcheck`, which
checks three things:

1. The tmux console session exists. `claude` is that session's command, so
   if Claude died the session goes with it.
2. The session still has a live (non-dead) pane.
3. `cron` is running and the watchdog cron entry is in place — otherwise the
   auto-resume would never fire again. Skipped when `WATCHDOG_ENABLED=false`.

**A session parked on a rate limit stays healthy on purpose.** That is the
state the watchdog exists to recover from, not a fault. The probe reports it
in the status output rather than failing:

```
$ docker inspect --format '{{.State.Health.Status}}' claude-console
healthy

$ docker inspect --format '{{(index .State.Health.Log 0).Output}}' claude-console
OK (rate-limited, resuming 2026-09-01T03:00:00+02:00)
```

`start_period` is 60s because the entrypoint restarts a dead console within
about 30 seconds; the probe shouldn't fail the container while that's
happening.

Note that `restart: unless-stopped` does **not** react to health status —
Docker restarts on process exit, not on an unhealthy probe. The health
status is there for you, for `docker ps`, and for orchestrators that do act
on it.

## Configuration

Everything is set from `.env` / `docker-compose.yml`. Runtime settings take
effect on `docker compose up -d` — **no rebuild** except for the tool
versions.

| Variable | Default | Meaning |
|---|---|---|
| `CONTAINER_NAME` | `claude-console` | Container name |
| `WORKSPACE_DIR` | `./workspace` | Host directory mounted at `/workspace` |
| `TZ` | `UTC` | Container timezone; must match the times Claude prints |
| `PUID` | `1000` | uid Claude runs as — match `id -u` so workspace files are yours |
| `PGID` | `1000` | gid Claude runs as — match `id -g` |
| `CHOWN_WORKSPACE` | `auto` | `auto` \| `always` \| `never` — see [Workspace ownership](#workspace-ownership) |
| `CLAUDE_ARGS` | *(empty)* | Extra flags for the console's `claude` process |
| `CLAUDE_TMUX_SESSION` | `claude` | tmux session name |
| `WATCHDOG_ENABLED` | `true` | `false` removes the cron job entirely |
| `WATCHDOG_INTERVAL_MIN` | `10` | Watchdog cron interval, 1–59 minutes |
| `STATUSLINE_ENABLED` | `true` | `false` removes the status line from settings.json |
| `STATUSLINE_REFRESH_SECONDS` | `60` | Also re-run the status line on this timer |
| `USAGE_STATE_FILE` | `/var/lib/claude-watchdog/usage.json` | Where usage is published |
| `USAGE_STATE_MAX_AGE` | `1800` | Seconds before that file is considered stale |
| `CONTINUE_TEXT` | `continue` | What the watchdog types on resume |
| `USAGE_PROBE_MIN_INTERVAL` | `3600` | Seconds between two `/usage` probes |
| `NUDGE_MIN_INTERVAL` | `900` | Seconds between two resume nudges |
| `USAGE_PROBE_WAIT` | `8` | Seconds to let `/usage` render before reading it |
| `PANE_LINES` | `300` | Lines of scrollback the watchdog inspects |
| `HEALTHCHECK_INTERVAL` | `60s` | Time between health probes |
| `HEALTHCHECK_TIMEOUT` | `10s` | Per-probe timeout |
| `HEALTHCHECK_START_PERIOD` | `60s` | Grace window before failures count |
| `HEALTHCHECK_RETRIES` | `3` | Consecutive failures before unhealthy |
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
| `statusline.py` | Status line; renders usage and publishes `usage.json`. Installed as `/usr/local/bin/claude-statusline` |
| `usage_state.py` | Reads `usage.json` for the watchdog, with staleness handling |
| `watchdog_parse.py` | Parses pane and `/usage` text into `{limited, scope, reset_epoch}` |
| `console.sh` | One-word attach; installed as `/usr/local/bin/console` |
| `healthcheck.sh` | Health probe; installed as `/usr/local/bin/claude-healthcheck` |
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

### If settings still reset under Coolify

Coolify names volumes after the compose project. If a redeploy changes that
name, you get a *new, empty* volume and everything looks reset. Check with:

```bash
docker volume ls | grep claude
```

Two of them means the name moved. Also confirm the resource isn't set to
wipe volumes on redeploy in Coolify's storage settings.
