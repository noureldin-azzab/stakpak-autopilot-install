#!/usr/bin/env bash
#
# Stakpak Autopilot — One-shot bootstrap installer
# ─────────────────────────────────────────────────
# Hosted at: https://raw.githubusercontent.com/noureldin-azzab/stakpak-autopilot-install/main/autopilot-install.sh
#
# Designed to be invoked by the /autopilot-install skill after a target adapter
# resolves a reachable SSH host. This script is intentionally cloud-agnostic:
# keep AWS/GCP/Azure API calls in target adapters. It accepts all secrets via
# env vars (preferred) or flags. Idempotent. ~90s end-to-end on a fresh host
# (~30s if Docker + image are already present).
#
# Usage (env-var style, preferred — keeps secrets out of command args):
#   curl -sSL https://raw.githubusercontent.com/noureldin-azzab/stakpak-autopilot-install/main/autopilot-install.sh | \
#     STAKPAK_API_KEY=... \
#     SLACK_BOT_TOKEN=xoxb-... \
#     SLACK_APP_TOKEN=xapp-... \
#     sudo -E bash
#
# Usage (flag style):
#   curl -sSL https://raw.githubusercontent.com/noureldin-azzab/stakpak-autopilot-install/main/autopilot-install.sh | sudo bash -s -- \
#     --api-key STAKPAK_KEY \
#     --slack-bot xoxb-... \
#     --slack-app xapp-...
#
# Flags:
#   --api-key <key>         (or STAKPAK_API_KEY env)
#   --provider <name>       stakpak (default) | anthropic
#   --model <model>         Model for scheduled agents (or STAKPAK_MODEL)
#   --notify-channel <type> Notification channel type: slack|telegram|discord
#   --notify-chat-id <id>   Destination, e.g. #prod for Slack
#   --slack-bot <token>     (or SLACK_BOT_TOKEN)
#   --slack-app <token>     (or SLACK_APP_TOKEN)
#   --telegram <token>      (or TELEGRAM_BOT_TOKEN)
#   --discord <token>       (or DISCORD_BOT_TOKEN)
#   --target-user <user>    Default: SUDO_USER
#   --skip-channels         Don't configure any channel
#   --skip-up               Install only; don't run `stakpak up`
#   -h, --help              Show this help
#
# Exit codes:
#   0  success
#   1  generic error
#   2  bad input
#   3  unsupported OS
#   4  preflight failure
#   5  autopilot health check failed

set -Eeuo pipefail

# ─── Globals ───────────────────────────────────────────────────────────────────

SCRIPT_VERSION="1.0.0"
SANDBOX_IMAGE="ghcr.io/stakpak/agent:latest"

STAKPAK_API_KEY="${STAKPAK_API_KEY:-}"
AUTH_PROVIDER="${STAKPAK_AUTH_PROVIDER:-stakpak}"
STAKPAK_MODEL="${STAKPAK_MODEL:-claude-opus-4-5-20251101}"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-}"
TELEGRAM_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
DISCORD_TOKEN="${DISCORD_BOT_TOKEN:-}"
NOTIFY_CHANNEL="${STAKPAK_NOTIFY_CHANNEL:-}"
NOTIFY_CHAT_ID="${STAKPAK_NOTIFY_CHAT_ID:-}"
TARGET_USER="${SUDO_USER:-}"
SKIP_CHANNELS=0
SKIP_UP=0
START_TS=$(date +%s)

DOCKER_PULL_PID=""

# ─── UI helpers ────────────────────────────────────────────────────────────────

C_BLUE=$'\033[0;34m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
C_RED=$'\033[0;31m'; C_CYAN=$'\033[1;36m'; C_RESET=$'\033[0m'
[[ -t 1 ]] || { C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_RESET=""; }

info()  { printf "%s[INFO]%s %s\n"  "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf "%s[ OK ]%s %s\n"  "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf "%s[WARN]%s %s\n"  "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf "%s[FAIL]%s %s\n"  "$C_RED"    "$C_RESET" "$*" >&2; }
step()  { printf "\n%s▶ %s%s\n"     "$C_CYAN"   "$*" "$C_RESET"; }

die() { err "$*"; exit "${2:-1}"; }
elapsed() { echo $(( $(date +%s) - START_TS ))s; }

trap 'rc=$?; [[ $rc -ne 0 ]] && err "Aborted at line $LINENO (exit $rc) after $(elapsed)"' ERR

# ─── Arg parsing ───────────────────────────────────────────────────────────────

print_help() { sed -n '2,40p' "$0" | sed 's/^# \?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key)        STAKPAK_API_KEY="$2"; shift 2 ;;
    --provider)       AUTH_PROVIDER="$2"; shift 2 ;;
    --model)          STAKPAK_MODEL="$2"; shift 2 ;;
    --notify-channel) NOTIFY_CHANNEL="$2"; shift 2 ;;
    --notify-chat-id) NOTIFY_CHAT_ID="$2"; shift 2 ;;
    --slack-bot)      SLACK_BOT_TOKEN="$2"; shift 2 ;;
    --slack-app)      SLACK_APP_TOKEN="$2"; shift 2 ;;
    --telegram)       TELEGRAM_TOKEN="$2"; shift 2 ;;
    --discord)        DISCORD_TOKEN="$2"; shift 2 ;;
    --target-user)    TARGET_USER="$2"; shift 2 ;;
    --skip-channels)  SKIP_CHANNELS=1; shift ;;
    --skip-up)        SKIP_UP=1; shift ;;
    -h|--help)        print_help; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" 2 ;;
  esac
done

# ─── Preflight ─────────────────────────────────────────────────────────────────

step "Preflight"

[[ $(id -u) -eq 0 ]] || die "Must run as root (use sudo -E to preserve env vars)" 4
[[ -n "$TARGET_USER" ]] || die "Could not determine target user; pass --target-user" 2
id "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' does not exist" 2
[[ -n "$STAKPAK_API_KEY" ]] || die "API key required (--api-key or STAKPAK_API_KEY)" 2

TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
TARGET_UID=$(id -u "$TARGET_USER")

OS_ID=""; PKG_MGR=""; DOCKER_PKG=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
fi

case "$OS_ID" in
  amzn|rhel|fedora|rocky|almalinux|centos)
    PKG_MGR=$(command -v dnf >/dev/null && echo dnf || echo yum)
    DOCKER_PKG="docker"
    ;;
  ubuntu|debian)
    PKG_MGR="apt-get"
    DOCKER_PKG="docker.io"
    ;;
  *) die "Unsupported OS: $OS_ID" 3 ;;
esac

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64|aarch64|arm64) ;;
  *) die "Unsupported architecture: $ARCH" 3 ;;
esac

ok "OS=$OS_ID, arch=$ARCH, pkg=$PKG_MGR, target=$TARGET_USER"

# Helper: run a command as the target user with a proper systemd user env
as_user() {
  sudo -u "$TARGET_USER" \
    --preserve-env=PATH \
    XDG_RUNTIME_DIR="/run/user/$TARGET_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" \
    HOME="$TARGET_HOME" \
    PATH="$TARGET_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    "$@"
}

# Absolute path to stakpak binary (set after install_stakpak).
# Required because sudo's `secure_path` strips PATH overrides on RHEL/AL,
# so calling `stakpak` by name fails even when we set PATH explicitly.
STAKPAK_BIN=""

resolve_stakpak_bin() {
  local candidates=(
    "$TARGET_HOME/.local/bin/stakpak"
    "/usr/local/bin/stakpak"
    "/usr/bin/stakpak"
  )
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      STAKPAK_BIN="$c"
      return
    fi
  done
  die "Could not locate stakpak binary after install" 1
}


toml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

toml_set_key() {
  local file="$1" section="$2" key="$3" value="$4"
  local tmp
  tmp=$(mktemp)
  awk -v section="$section" -v key="$key" -v value="$value" '
    BEGIN { in_section=0; seen_section=0; key_set=0 }
    $0 == section {
      if (in_section && !key_set) { print key " = " value; key_set=1 }
      in_section=1; seen_section=1; print; next
    }
    /^\[/ {
      if (in_section && !key_set) { print key " = " value; key_set=1 }
      in_section=0; print; next
    }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      print key " = " value; key_set=1; next
    }
    { print }
    END {
      if (!seen_section) { print ""; print section; print key " = " value }
      else if (in_section && !key_set) { print key " = " value }
    }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
  chown "$TARGET_USER:$TARGET_USER" "$file" 2>/dev/null || true
}

# ─── Background sandbox image pull (parallel optimization) ─────────────────────

start_image_pull() {
  if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    info "Pre-pulling sandbox image in background"
    ( docker pull "$SANDBOX_IMAGE" >/dev/null 2>&1 || true ) &
    DOCKER_PULL_PID=$!
  fi
}

wait_for_pull() {
  if [[ -n "$DOCKER_PULL_PID" ]]; then
    info "Waiting for sandbox image pull..."
    wait "$DOCKER_PULL_PID" 2>/dev/null || true
    DOCKER_PULL_PID=""
  fi
}

# ─── Step 1: Stakpak CLI ───────────────────────────────────────────────────────

install_stakpak() {
  step "Stakpak CLI"
  if [[ -x "$TARGET_HOME/.local/bin/stakpak" ]] || [[ -x "/usr/local/bin/stakpak" ]] || [[ -x "/usr/bin/stakpak" ]]; then
    resolve_stakpak_bin
    ok "Already installed at $STAKPAK_BIN"
    return
  fi
  info "Installing..."
  as_user bash -c 'yes | curl -sSL https://stakpak.dev/install.sh | bash' \
    >/tmp/stakpak-install.log 2>&1 \
    || { tail -20 /tmp/stakpak-install.log; die "Install failed (see /tmp/stakpak-install.log)"; }

  # Ensure ~/.local/bin in PATH for future shells
  local profile="$TARGET_HOME/.bashrc"
  if [[ -f "$profile" ]] && ! grep -q '.local/bin' "$profile"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$profile"
    chown "$TARGET_USER:$TARGET_USER" "$profile"
  fi
  resolve_stakpak_bin
  ok "Installed at $STAKPAK_BIN"
}

# ─── Step 2: Docker ────────────────────────────────────────────────────────────

install_docker() {
  step "Docker"
  if command -v docker >/dev/null 2>&1; then
    ok "Already installed ($(docker --version 2>&1 | head -1))"
  else
    info "Installing $DOCKER_PKG..."
    case "$PKG_MGR" in
      dnf|yum)  "$PKG_MGR" install -y "$DOCKER_PKG" >/dev/null ;;
      apt-get)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null
        apt-get install -y -qq "$DOCKER_PKG" >/dev/null
        ;;
    esac
    ok "Installed"
  fi

  systemctl is-enabled --quiet docker 2>/dev/null || systemctl enable docker >/dev/null 2>&1 || true
  systemctl is-active --quiet docker || { info "Starting daemon..."; systemctl start docker; }

  if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
    info "Adding $TARGET_USER to docker group"
    usermod -aG docker "$TARGET_USER"
  fi
  ok "Daemon running, $TARGET_USER in docker group"
}

# ─── Step 3: Systemd user session (THE critical fix) ───────────────────────────
#
# Without this, `stakpak up` will silently crash-loop with:
#   "Container stdout EOF before server CA was found"
# because the systemd user manager keeps the OLD (pre-docker-group) session.

setup_systemd_user() {
  step "Systemd user session"

  if ! loginctl show-user "$TARGET_USER" 2>/dev/null | grep -q "Linger=yes"; then
    info "Enabling linger"
    loginctl enable-linger "$TARGET_USER"
  fi

  info "Restarting user@$TARGET_UID.service (applies docker group membership)"
  systemctl stop "user@$TARGET_UID.service" >/dev/null 2>&1 || true
  sleep 2
  systemctl start "user@$TARGET_UID.service" >/dev/null 2>&1 || true
  sleep 2

  for i in {1..15}; do
    [[ -d "/run/user/$TARGET_UID" ]] && break
    sleep 1
  done
  [[ -d "/run/user/$TARGET_UID" ]] || die "Systemd user runtime dir never appeared" 4

  as_user docker info >/dev/null 2>&1 \
    || die "User cannot access Docker after restart (check 'newgrp docker' or reboot)" 4
  ok "Linger enabled, user can access Docker"
}

# ─── Step 4: Auth ──────────────────────────────────────────────────────────────

configure_auth() {
  step "Authentication"
  as_user "$STAKPAK_BIN" auth login \
    --provider "$AUTH_PROVIDER" \
    --api-key "$STAKPAK_API_KEY" >/dev/null 2>&1 \
    || die "Auth failed (bad API key or provider?)" 1

  local cfg="$TARGET_HOME/.stakpak/config.toml"
  if [[ -f "$cfg" ]]; then
    toml_set_key "$cfg" "[profiles.default]" "api_endpoint" "$(toml_quote "https://apiv2.stakpak.dev")"
    toml_set_key "$cfg" "[profiles.default]" "model" "$(toml_quote "$STAKPAK_MODEL")"
  fi

  ok "Authenticated (provider=$AUTH_PROVIDER, model=$STAKPAK_MODEL)"
}

# ─── Step 5: Channels ──────────────────────────────────────────────────────────

configure_channels() {
  if [[ "$SKIP_CHANNELS" == "1" ]]; then
    info "Skipping channels (--skip-channels)"
    return
  fi

  step "Notification channels"
  local n=0

  if [[ -n "$SLACK_BOT_TOKEN" && -n "$SLACK_APP_TOKEN" ]]; then
    info "Adding Slack"
    as_user "$STAKPAK_BIN" autopilot channel add slack \
      --bot-token "$SLACK_BOT_TOKEN" \
      --app-token "$SLACK_APP_TOKEN" >/dev/null
    ok "Slack configured"
    ((n++)) || true
  elif [[ -n "$SLACK_BOT_TOKEN" || -n "$SLACK_APP_TOKEN" ]]; then
    warn "Slack needs BOTH bot+app tokens; skipping"
  fi

  if [[ -n "$TELEGRAM_TOKEN" ]]; then
    info "Adding Telegram"
    as_user "$STAKPAK_BIN" autopilot channel add telegram --token "$TELEGRAM_TOKEN" >/dev/null
    ok "Telegram configured"
    ((n++)) || true
  fi

  if [[ -n "$DISCORD_TOKEN" ]]; then
    info "Adding Discord"
    as_user "$STAKPAK_BIN" autopilot channel add discord --token "$DISCORD_TOKEN" >/dev/null
    ok "Discord configured"
    ((n++)) || true
  fi

  if [[ "$n" -eq 0 ]]; then
    warn "No channels configured. Add later: stakpak autopilot channel add <type> ..."
  fi
  return 0
}


configure_notifications() {
  if [[ "$SKIP_CHANNELS" == "1" ]]; then
    return 0
  fi

  step "Notification routing"

  if [[ -z "$NOTIFY_CHANNEL" ]]; then
    if [[ -n "$SLACK_BOT_TOKEN" && -n "$SLACK_APP_TOKEN" ]]; then
      NOTIFY_CHANNEL="slack"
    elif [[ -n "$TELEGRAM_TOKEN" ]]; then
      NOTIFY_CHANNEL="telegram"
    elif [[ -n "$DISCORD_TOKEN" ]]; then
      NOTIFY_CHANNEL="discord"
    fi
  fi

  if [[ -z "$NOTIFY_CHANNEL" || -z "$NOTIFY_CHAT_ID" ]]; then
    warn "Notification destination not configured. Set STAKPAK_NOTIFY_CHANNEL and STAKPAK_NOTIFY_CHAT_ID."
    return 0
  fi

  local cfg="$TARGET_HOME/.stakpak/autopilot.toml"
  mkdir -p "$(dirname "$cfg")"
  touch "$cfg"
  chown "$TARGET_USER:$TARGET_USER" "$cfg" 2>/dev/null || true

  toml_set_key "$cfg" "[notifications]" "channel" "$(toml_quote "$NOTIFY_CHANNEL")"
  toml_set_key "$cfg" "[notifications]" "chat_id" "$(toml_quote "$NOTIFY_CHAT_ID")"
  toml_set_key "$cfg" "[notifications]" "gateway_url" "$(toml_quote "http://127.0.0.1:4096")"

  ok "Notifications configured ($NOTIFY_CHANNEL -> $NOTIFY_CHAT_ID)"
}

# ─── Step 6: Bring up ──────────────────────────────────────────────────────────

bring_up() {
  if [[ "$SKIP_UP" == "1" ]]; then
    info "Skipping 'stakpak up'"
    return
  fi
  step "Starting autopilot"
  wait_for_pull

  if as_user "$STAKPAK_BIN" autopilot status 2>/dev/null | grep -q "Service.*active"; then
    info "Already running — restarting to apply config"
    as_user "$STAKPAK_BIN" down >/dev/null 2>&1 || true
    sleep 2
  fi

  info "stakpak up (sandbox boot can take 60-120s)..."
  as_user "$STAKPAK_BIN" up --non-interactive >/tmp/stakpak-up.log 2>&1 || {
    tail -30 /tmp/stakpak-up.log >&2
    die "stakpak up failed. See /tmp/stakpak-up.log and: stakpak autopilot logs -c server" 5
  }

  sleep 3
  if as_user "$STAKPAK_BIN" autopilot status 2>&1 | grep -q "Server.*✓ reachable"; then
    ok "Healthy"
  else
    warn "Started but health unclear — verify with: stakpak autopilot status"
  fi
}

# ─── Summary ───────────────────────────────────────────────────────────────────

summary() {
  step "Done in $(elapsed)"
  cat <<EOF

  User:    $TARGET_USER
  Config:  $TARGET_HOME/.stakpak/autopilot.toml
  Notify:  ${NOTIFY_CHANNEL:-none} ${NOTIFY_CHAT_ID:-}

  Useful commands (run as $TARGET_USER):
    stakpak autopilot status          # health
    stakpak autopilot logs -f         # tail logs
    stakpak autopilot channel list    # list channels
    stakpak autopilot schedule add ... # add monitoring
    stakpak down                       # stop

  Add your first schedule, e.g.:
    sudo -u $TARGET_USER stakpak autopilot schedule add host-health \\
      --cron '*/5 * * * *' \\
      --prompt 'Check CPU/mem/disk; alert on anomalies' \\
      --channel slack

EOF
}

# ─── Main ──────────────────────────────────────────────────────────────────────

main() {
  info "Stakpak Autopilot bootstrap v$SCRIPT_VERSION"

  start_image_pull       # parallel: starts now if Docker exists
  install_stakpak        # ~10s
  install_docker         # ~30s (or instant)
  start_image_pull       # if Docker just installed, start pull now
  setup_systemd_user     # fixes the P1 bug
  configure_auth         # ~2s
  configure_channels     # ~5s
  configure_notifications # routing for schedule output
  bring_up               # ~25-60s (waits on pull)
  summary
}

main "$@"
