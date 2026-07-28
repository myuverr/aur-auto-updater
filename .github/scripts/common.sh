#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

# Shared helper functions for workflow scripts
# shellcheck shell=bash

set -euo pipefail

# _calc_backoff <attempt> <base_delay> [max_delay]
# Computes full jitter backoff: random(0, min(base_delay * 2^(attempt-1), max_delay))
_calc_backoff() {
  local attempt="$1"
  local base_delay="$2"
  local max_delay="${3:-60}"
  local delay

  delay=$((base_delay * (1 << (attempt - 1))))
  if [ "$delay" -gt "$max_delay" ]; then
    delay=$max_delay
  fi
  echo $((RANDOM % (delay + 1)))
}

# retry_command <max_attempts> <base_delay_s> <command...>
# Retries with full jitter backoff, capped at 60 seconds
retry_command() {
  local max_attempts="$1"
  local base_delay="$2"
  shift 2

  local attempt
  for attempt in $(seq 1 "$max_attempts"); do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      local wait_time
      wait_time=$(_calc_backoff "$attempt" "$base_delay")
      echo "::warning::Attempt $attempt/$max_attempts failed, retrying in ${wait_time}s..."
      sleep "$wait_time"
    fi
  done

  echo "::error::Command failed after $max_attempts attempts: $*"
  return 1
}

# update_pkgbuild_version <file> <new_version>
# Rewrites pkgver and resets pkgrel to 1
update_pkgbuild_version() {
  local file="$1"
  local new_version="$2"
  local temp_file

  temp_file=$(mktemp)

  awk -v new_ver="$new_version" '
    /^pkgver=/ { print "pkgver=" new_ver; next }
    /^pkgrel=/ { print "pkgrel=1"; next }
    { print }
  ' "$file" > "$temp_file" && mv "$temp_file" "$file" || { rm -f "$temp_file"; return 1; }
}

# sanitize_log <file> [max_lines]
# Emits redacted log content to stdout
sanitize_log() {
  local file="$1"
  local max_lines="${2:-}"
  local input
  if [ -n "$max_lines" ]; then
    input=$(sed -n "1,${max_lines}p" "$file")
  else
    input=$(cat "$file")
  fi
  printf '%s' "$input" | sed -E \
    -e 's/(ghp_|github_pat_|ghs_|gho_|ghu_|ghr_)[a-zA-Z0-9_]*/[REDACTED]/g' \
    -e 's/\b[0-9a-f]{40}\b/[REDACTED]/g'
}

# retry_http_request <output_file> <url> [max_attempts] [base_delay] [rate_limit_delay]
# Retries HTTP fetch with full jitter backoff, using a separate delay path for HTTP 429
retry_http_request() {
  local output_file="$1"
  local url="$2"
  local max_attempts="${3:-10}"
  local base_delay="${4:-5}"
  local rate_limit_delay="${5:-10}"
  local attempt http_code

  for attempt in $(seq 1 "$max_attempts"); do
    http_code=$(curl -s --connect-timeout 10 --max-time 30 -w "%{http_code}" -o "$output_file" "$url" 2>/dev/null || true)
    if [ "$http_code" = "200" ]; then
      return 0
    elif [ "$http_code" = "429" ]; then
      if [ "$attempt" -lt "$max_attempts" ]; then
        local wait_429
        wait_429=$(_calc_backoff "$attempt" "$rate_limit_delay")
        echo "::warning::HTTP 429 rate limited, retrying in ${wait_429}s (attempt $attempt/$max_attempts)..."
        sleep "$wait_429"
      fi
    else
      if [ "$attempt" -lt "$max_attempts" ]; then
        local wait_time
        wait_time=$(_calc_backoff "$attempt" "$base_delay")
        echo "::warning::HTTP request failed with code $http_code (attempt $attempt/$max_attempts), retrying in ${wait_time}s..."
        sleep "$wait_time"
      fi
    fi
  done

  return 1
}

# strip_pkgrel removes a trailing -pkgrel suffix
strip_pkgrel() {
  echo "$1" | sed 's/-[0-9]*$//'
}

# strip_epoch removes an epoch prefix (`N:`)
strip_epoch() {
  echo "${1#*:}"
}

# install_aurutils
# Bootstraps aurutils from AUR using a temporary build user
install_aurutils() {
  if command -v aur &>/dev/null; then
    return 0
  fi

  echo "Installing aurutils..."
  useradd -m _aur_build || true
  echo "_aur_build ALL=(ALL) SETENV: NOPASSWD: /usr/bin/pacman, /usr/bin/pacsync" > /etc/sudoers.d/_aur_build
  chmod 440 /etc/sudoers.d/_aur_build

  local orig_dir="$PWD"
  cd /tmp
  runuser -u _aur_build -- git clone https://aur.archlinux.org/aurutils.git
  cd aurutils
  runuser -u _aur_build -- makepkg -si --noconfirm

  cd "$orig_dir"
  userdel -r _aur_build || true
  rm -f /etc/sudoers.d/_aur_build
  rm -rf /tmp/aurutils
  echo "aurutils installed: $(aur --version)"
}

# setup_aur_local_repo
# Sets up a local pacman repository for AUR dependencies
setup_aur_local_repo() {
  local repo_dir="/var/lib/aur-repo"
  if [ -f "$repo_dir/aur-local.db.tar.gz" ]; then
    return 0
  fi

  echo "Setting up local pacman repository for AUR dependencies..."
  mkdir -p "$repo_dir"
  chown -R builder:builder "$repo_dir"

  runuser -u builder -- repo-add "$repo_dir/aur-local.db.tar.gz"

  if ! grep -q "\[aur-local\]" /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<'EOF'

[aur-local]
SigLevel = Optional TrustAll
Server = file:///var/lib/aur-repo
EOF
  fi

  pacman -Sy
}

# resolve_aur_dependencies
# Checks current PKGBUILD/.SRCINFO for non-official dependencies and installs them via aurutils
resolve_aur_dependencies() {
  # Ensure builder user owns current directory so makepkg --printsrcinfo can execute
  chown -R builder:builder .

  # Regenerate .SRCINFO to reflect updated PKGBUILD
  runuser -u builder -- makepkg --printsrcinfo > .SRCINFO 2>/dev/null || true

  local deps dep missing_deps=()
  deps=$(awk '/^\t(depends|makedepends) =/ { sub(/.*= /, ""); sub(/[<>=].*/, ""); print }' .SRCINFO | sort -u)

  for dep in $deps; do
    if [ -n "$dep" ] && ! pacman -Si "$dep" &>/dev/null; then
      missing_deps+=("$dep")
    fi
  done

  if [ ${#missing_deps[@]} -eq 0 ]; then
    echo "No AUR dependencies detected."
    return 0
  fi

  echo "Detected AUR dependencies: ${missing_deps[*]}"

  install_aurutils
  setup_aur_local_repo

  for dep in "${missing_deps[@]}"; do
    echo "Syncing AUR dependency: $dep"
    runuser -u builder -- env HOME=/home/builder aur sync --no-view --noconfirm -d aur-local "$dep"
  done
}
