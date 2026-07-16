#!/usr/bin/env bash
# Idempotent bootstrap for polaris-trade self-hosted GitHub Actions runners.
# Re-run safe. Handles system deps, rustup, toolchains, cargo tools.
#
# Usage:
#   sudo ./vps-bootstrap.sh                    # everything
#   sudo ./vps-bootstrap.sh system             # OS packages only
#   ./vps-bootstrap.sh rustup                  # rustup + toolchains only (no sudo)
#   ./vps-bootstrap.sh toolchains              # refresh rustup toolchains only
#   ./vps-bootstrap.sh tools                   # cargo-nextest, cargo-audit, cargo-hack, cargo-fuzz
#   sudo ./vps-bootstrap.sh links              # /usr/local/bin symlinks for systemd PATH
#   ./vps-bootstrap.sh gc                      # prune target/ dirs, old toolchains
#
# `all` runs: system, rustup, toolchains, tools, links, gc.
#
# Tuning:
#   FLEET_MSRVS="1.96.1" space-separated declared MSRVs to provision (default "1.96.1")
#   EXTRA_TOOLCHAINS=""  space-separated extra pins, e.g. "beta 1.90.0"
#   RUNNER_USER=<name>   user the runner runs as (owner of ~/.cargo, ~/.rustup);
#                        defaults to the sudo caller, else the current user
#
# Prereqs: AlmaLinux 9 / RHEL 9 family. Adjust pkg step for other distros.

set -euo pipefail

SUBCMD="${1:-all}"
FLEET_MSRVS="${FLEET_MSRVS:-1.96.1}"
EXTRA_TOOLCHAINS="${EXTRA_TOOLCHAINS:-}"
RUNNER_USER="${RUNNER_USER:-${SUDO_USER:-$(id -un)}}"
CARGO_TOOLS=("cargo-nextest" "cargo-audit" "cargo-hack" "cargo-fuzz")

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
    elfutils-libelf-devel zlib-devel numactl-devel \
    libbpf libbpf-devel libxdp libxdp-devel \
    dpdk dpdk-devel \
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

# ---- toolchains (stable + nightly + declared fleet MSRVs) ----
step_toolchains() {
  require_user "toolchains"
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"

  local toolchains=("stable" "nightly")
  for msrv in $FLEET_MSRVS; do
    toolchains+=("$msrv")
  done
  for extra in $EXTRA_TOOLCHAINS; do
    toolchains+=("$extra")
  done
  log "provisioning toolchains: ${toolchains[*]}"

  for tc in "${toolchains[@]}"; do
    if rustup toolchain list | grep -q "^$tc-"; then
      log "  $tc present, updating"
      rustup update "$tc" --no-self-update
    else
      log "  installing $tc"
      rustup toolchain install "$tc" --profile minimal --component clippy
    fi
  done

  # nightly needs rustfmt for the reusable fmt job, miri + rust-src for the
  # reusable miri job (miri builds its interpreter sysroot from rust-src)
  rustup component add rustfmt miri rust-src --toolchain nightly

  log "toolchains ready"
  rustup toolchain list
}

# ---- cargo CLI tools ----
step_tools() {
  require_user "tools"
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"

  local t
  for t in "${CARGO_TOOLS[@]}"; do
    if command -v "$t" >/dev/null 2>&1; then
      log "  $t present ($($t --version 2>&1 | head -1))"
    else
      log "  installing $t"
      cargo install "$t" --locked
    fi
  done
}

# ---- /usr/local/bin symlinks ----
step_links() {
  require_root "links"
  # systemd-launched runner processes never see the runner user's PATH;
  # expose cargo tools at /usr/local/bin. Root-owned step: a non-root step
  # calling sudo dies without a tty, which is exactly how `all` runs.
  local home t
  home=$(getent passwd "$RUNNER_USER" | cut -d: -f6)
  [ -n "$home" ] || die "cannot resolve home dir for ${RUNNER_USER}"
  for t in "${CARGO_TOOLS[@]}"; do
    if [ -x "$home/.cargo/bin/$t" ]; then
      ln -sf "$home/.cargo/bin/$t" "/usr/local/bin/$t"
      log "  linked /usr/local/bin/$t"
    else
      log "  $t missing under ${home}/.cargo/bin, skipped"
    fi
  done
}

# ---- garbage collection ----
step_gc() {
  require_user "gc"
  log "pruning runner target/ and toolchain leftovers"
  find /opt/actions-runner-*/_work -type d -name target -prune -exec du -sh {} \; 2>/dev/null || true
  # non-tty (the `all` chain): keep target dirs, prompt would die under set -e
  local ans=N
  if [ -t 0 ]; then
    read -r -p "remove all runner target/ dirs? [y/N] " ans || ans=N
  else
    log "non-interactive run: keeping runner target/ dirs"
  fi
  if [ "${ans:-N}" = "y" ] || [ "${ans:-N}" = "Y" ]; then
    find /opt/actions-runner-*/_work -type d -name target -prune -exec rm -rf {} + 2>/dev/null || true
    log "target dirs removed"
  fi
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"

  # drop installed toolchains outside the configured fleet set
  local keep=("stable" "nightly")
  for msrv in $FLEET_MSRVS; do
    keep+=("$msrv")
  done
  for extra in $EXTRA_TOOLCHAINS; do
    keep+=("$extra")
  done
  log "keeping toolchains: ${keep[*]}"

  local tc keep_tc matched
  while IFS= read -r tc; do
    [ -n "$tc" ] || continue
    matched=0
    for keep_tc in "${keep[@]}"; do
      case "$tc" in
        "$keep_tc"-*) matched=1; break ;;
      esac
    done
    if [ "$matched" -eq 0 ]; then
      log "  removing stale toolchain $tc"
      rustup toolchain uninstall "$tc"
    fi
  done < <(rustup toolchain list | awk '{print $1}')

  du -sh "$HOME/.rustup/toolchains/" 2>/dev/null || true
}

case "$SUBCMD" in
  all)
    require_root "all (uses sudo for system step)"
    step_system
    sudo -u "$RUNNER_USER" -H bash -c "FLEET_MSRVS='$FLEET_MSRVS' EXTRA_TOOLCHAINS='$EXTRA_TOOLCHAINS' RUNNER_USER=$RUNNER_USER $(realpath "$0") rustup"
    sudo -u "$RUNNER_USER" -H bash -c "FLEET_MSRVS='$FLEET_MSRVS' EXTRA_TOOLCHAINS='$EXTRA_TOOLCHAINS' RUNNER_USER=$RUNNER_USER $(realpath "$0") toolchains"
    sudo -u "$RUNNER_USER" -H bash -c "FLEET_MSRVS='$FLEET_MSRVS' EXTRA_TOOLCHAINS='$EXTRA_TOOLCHAINS' RUNNER_USER=$RUNNER_USER $(realpath "$0") tools"
    step_links
    sudo -u "$RUNNER_USER" -H bash -c "FLEET_MSRVS='$FLEET_MSRVS' EXTRA_TOOLCHAINS='$EXTRA_TOOLCHAINS' RUNNER_USER=$RUNNER_USER $(realpath "$0") gc"
    log "bootstrap complete"
    ;;
  system)     step_system ;;
  rustup)     step_rustup ;;
  toolchains) step_toolchains ;;
  tools)      step_tools ;;
  links)      step_links ;;
  gc)         step_gc ;;
  *)          die "unknown subcommand: $SUBCMD (all|system|rustup|toolchains|tools|gc)" ;;
esac
