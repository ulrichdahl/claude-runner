# Self-contained Claude Code container.
#
# Nothing in here is specific to any one project: the workspace is whatever
# you mount at /workspace (or nothing at all -- the image works empty).
#
#   - PID 1 keeps a live `claude` console alive in tmux, attachable at any
#     time, surviving detach/reattach.
#   - A cron job every 10 minutes watches that console for a rate-limit stop
#     and nudges it to continue once the limit window has reset.
#   - The usual coding CLI tools are baked in.
FROM node:20-slim

ENV DEBIAN_FRONTEND=noninteractive \
    WORKSPACE=/workspace \
    TZ=UTC \
    SHELL=/bin/bash

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      cron \
      curl \
      diffutils \
      patch \
      git \
      gnupg \
      jq \
      less \
      openssh-client \
      procps \
      python3 \
      python3-pip \
      python3-venv \
      ripgrep \
      bash \
      tmux \
      tzdata \
      unzip \
      wget \
    && rm -rf /var/lib/apt/lists/*

# bash for everything: root's login shell, $SHELL for anything that spawns
# one (Claude Code's shell tool included), and tmux's default-shell below.
RUN chsh -s /bin/bash root

# python -> python3 (many tools assume the bare name exists)
RUN ln -sf /usr/bin/python3 /usr/local/bin/python

# gh (GitHub CLI) + glab (GitLab CLI), pinned, arch-aware.
ARG GH_VERSION=2.63.2
ARG GLAB_VERSION=1.52.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) gh_arch=amd64; glab_arch=x86_64 ;; \
      arm64) gh_arch=arm64; glab_arch=arm64 ;; \
      *) echo "unsupported arch $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_arch}.tar.gz" \
      | tar -xz -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${gh_arch}/bin/gh" /usr/local/bin/gh; \
    rm -rf "/tmp/gh_${GH_VERSION}_linux_${gh_arch}"; \
    curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${glab_arch}.tar.gz" \
      -o /tmp/glab.tar.gz; \
    mkdir -p /tmp/glab && tar -xzf /tmp/glab.tar.gz -C /tmp/glab; \
    install -m 0755 "$(find /tmp/glab -type f -name glab | head -1)" /usr/local/bin/glab; \
    rm -rf /tmp/glab /tmp/glab.tar.gz; \
    gh --version; glab --version

# sentry-cli
RUN curl -fsSL https://sentry.io/get-cli/ | INSTALL_DIR=/usr/local/bin bash \
    && sentry-cli --version

# Claude Code
RUN npm install -g @anthropic-ai/claude-code && claude --version

# Caveman plugin: baked into the image so a fresh container starts with it
# already installed. Marketplace/plugin state lives in ~/.claude; the
# entrypoint re-runs this idempotently in case ~/.claude is a fresh volume.
RUN claude plugin marketplace add JuliusBrussee/caveman \
    && claude plugin install caveman@caveman --yes \
    || echo "caveman install deferred to entrypoint"

# Mouse off + no alternate screen, so an attached console keeps the
# terminal's own selection/copy and scrollback. See tmux.conf.
COPY tmux.conf /etc/tmux.conf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY claude-watchdog.sh /usr/local/bin/claude-watchdog
COPY healthcheck.sh /usr/local/bin/claude-healthcheck
# One-word attach, for web terminals that only give you `docker exec`.
COPY console.sh /usr/local/bin/console
COPY watchdog_parse.py /usr/local/lib/watchdog_parse.py
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/claude-watchdog \
      /usr/local/bin/claude-healthcheck /usr/local/bin/console

# Default watchdog schedule. entrypoint.sh rewrites this file on every start
# from WATCHDOG_INTERVAL_MIN (and deletes it when WATCHDOG_ENABLED=false), so
# the interval is a compose setting, not a rebuild.
RUN echo '*/10 * * * * root /usr/local/bin/claude-watchdog >> /var/log/claude-watchdog.log 2>&1' \
      > /etc/cron.d/claude-watchdog \
    && chmod 0644 /etc/cron.d/claude-watchdog \
    && touch /var/log/claude-watchdog.log

RUN mkdir -p /workspace /var/lib/claude-watchdog
WORKDIR /workspace

# Compose overrides this with its own healthcheck block; this is the default
# for anyone running the image with plain `docker run`.
HEALTHCHECK --interval=60s --timeout=10s --start-period=60s --retries=3 \
  CMD /usr/local/bin/claude-healthcheck

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
