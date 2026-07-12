#!/usr/bin/env bash
# Idempotent bootstrap for polaris-trade self-hosted GitHub Actions runners.
# Re-run safe. Handles system deps, rustup, toolchains, cargo tools.
#
# Usage:
#   sudo ./vps-bootstrap.sh                    # everything
#   sudo ./vps-bootstrap.sh system             # OS packages only
#   ./vps-bootstrap.sh rustup                  # rustup + toolchains only (no sudo)
#   ./vps-bootstrap.sh toolchains              # refresh rustup toolchains only
#   ./vps-bootstrap.sh tools                   # cargo-nextest, other CLI tools
#   ./vps-bootstrap.sh gc                      # prune target/ dirs, old toolchains
#
# Tuning:
#   MSRV_WINDOW=3        rolling stable-N..stable window (default 3, matches rust-ci)
#   EXTRA_TOOLCHAINS=""  space-separated extra pins, e.g. "beta 1.90.0"
#   RUNNER_USER=aurora   user the runner runs as (owner of ~/.cargo, ~/.rustup)
#
# Prereqs: AlmaLinux 9 / RHEL 9 family. Adjust pkg step for other distros.

set -euo pipefail

SUBCMD="${1:-all}"
MSRV_WINDOW="${MSRV_WINDOW:-3}"
EXTRA_TOOLCHAINS="${EXTRA_TOOLCHAINS:-}"
RUNNER_USER="${RUNNER_USER:-aurora}"

log() { printf '\033[1;36m[bootstrap]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "$1 must run as root (sudo)"
}
require_user() {
  [ "$(id -u)" -eq 0 ] && die "$1 must NOT run as root; run as ${RUNNER_USER}"
}

# ---- system packages ----
step_system() {
  require_root "system"
  log "installing OS packages"
  dnf install -y \
    git curl jq tar gzip zstd \
    clang lld llvm \
    gcc gcc-c++ make cmake pkgconf-pkg-config \
    libelf-devel zlib-devel numactl-devel \
    libbpf libbpf-devel libxdp libxdp-devel \
    meson ninja-build \
    kernel-devel-"$(uname -r)" \
    policycoreutils-python-utils
  log "OS packages installed"
}

# ---- rustup ----
step_rustup() {
  require_user "rustup"
  if command -v rustup >/dev/null 2>&1; then
    log "rustup present ($(rustup --version | head -1))"
    rustup self update || true
  else
    log "installing rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain none --profile minimal
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
  fi
}

# ---- toolchains (msrv..stable window + nightly) ----
step_toolchains() {
  require_user "toolchains"
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"

  local stable major minor msrv_minor
  stable=$(curl -sSL https://static.rust-lang.org/dist/channel-rust-stable.toml \
    | awk '/^\[pkg\.rust\]$/{f=1; next} f && /^version = /{ print; exit }' \
    | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
  [ -n "$stable" ] || die "could not parse current stable version"
  major=$(echo "$stable" | cut -d. -f1)
  minor=$(echo "$stable" | cut -d. -f2)
  msrv_minor=$((minor - MSRV_WINDOW))
  log "stable=$stable  msrv window=${major}.${msrv_minor}..${major}.${minor}"

  local toolchains=()
  for i in $(seq 0 "$MSRV_WINDOW"); do
    toolchains+=("${major}.$((msrv_minor + i))")
  done
  toolchains+=("nightly")
  for extra in $EXTRA_TOOLCHAINS; do
    toolchains+=("$extra")
  done

  for tc in "${toolchains[@]}"; do
    if rustup toolchain list | grep -q "^$tc-"; then
      log "  $tc present, updating"
      rustup update "$tc" --no-self-update
    else
      log "  installing $tc"
      rustup toolchain install "$tc" --profile minimal --component clippy
    fi
  done

  # nightly needs rustfmt for the reusable fmt job
  rustup component add rustfmt --toolchain nightly

  log "toolchains ready"
  rustup toolchain list
}

# ---- cargo CLI tools ----
step_tools() {
  require_user "tools"
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"

  local tools=("cargo-nextest")
  for t in "${tools[@]}"; do
    if command -v "$t" >/dev/null 2>&1; then
      log "  $t present ($($t --version 2>&1 | head -1))"
    else
      log "  installing $t"
      cargo install "$t" --locked
    fi
  done

  # expose cargo-nextest at /usr/local/bin so systemd-launched runners find it
  # without depending on the runner user's PATH.
  if [ -x "$HOME/.cargo/bin/cargo-nextest" ]; then
    sudo ln -sf "$HOME/.cargo/bin/cargo-nextest" /usr/local/bin/cargo-nextest
  fi
}

# ---- garbage collection ----
step_gc() {
  require_user "gc"
  log "pruning runner target/ and toolchain leftovers"
  find /opt/actions-runner-*/_work -type d -name target -prune -exec du -sh {} \; 2>/dev/null || true
  read -r -p "remove all runner target/ dirs? [y/N] " ans
  if [ "${ans:-N}" = "y" ] || [ "${ans:-N}" = "Y" ]; then
    find /opt/actions-runner-*/_work -type d -name target -prune -exec rm -rf {} + 2>/dev/null || true
    log "target dirs removed"
  fi
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
  # drop toolchains outside our msrv window
  local keep_pattern
  keep_pattern=$(rustup toolchain list | awk '{print $1}' | tr '\n' '|' | sed 's/|$//')
  log "keeping toolchains: $keep_pattern"
  du -sh "$HOME/.rustup/toolchains/" 2>/dev/null || true
}

case "$SUBCMD" in
  all)
    require_root "all (uses sudo for system step)"
    step_system
    sudo -u "$RUNNER_USER" -H bash -c "MSRV_WINDOW=$MSRV_WINDOW EXTRA_TOOLCHAINS='$EXTRA_TOOLCHAINS' RUNNER_USER=$RUNNER_USER $(realpath "$0") rustup"
    sudo -u "$RUNNER_USER" -H bash -c "MSRV_WINDOW=$MSRV_WINDOW EXTRA_TOOLCHAINS='$EXTRA_TOOLCHAINS' RUNNER_USER=$RUNNER_USER $(realpath "$0") toolchains"
    sudo -u "$RUNNER_USER" -H bash -c "MSRV_WINDOW=$MSRV_WINDOW EXTRA_TOOLCHAINS='$EXTRA_TOOLCHAINS' RUNNER_USER=$RUNNER_USER $(realpath "$0") tools"
    log "bootstrap complete"
    ;;
  system)     step_system ;;
  rustup)     step_rustup ;;
  toolchains) step_toolchains ;;
  tools)      step_tools ;;
  gc)         step_gc ;;
  *)          die "unknown subcommand: $SUBCMD (all|system|rustup|toolchains|tools|gc)" ;;
esac
