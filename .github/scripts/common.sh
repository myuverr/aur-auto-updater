#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

# Shared helper functions for workflow scripts
# shellcheck shell=bash

set -euo pipefail

# retry_command <max_attempts> <base_delay_s> <command...>
# Retries with linear backoff: attempt * base_delay
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
      echo "::warning::Attempt $attempt/$max_attempts failed, retrying in $((attempt * base_delay))s..."
      sleep $((attempt * base_delay))
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
# Retries HTTP fetch, using a separate delay path for HTTP 429
retry_http_request() {
  local output_file="$1"
  local url="$2"
  local max_attempts="${3:-4}"
  local base_delay="${4:-3}"
  local rate_limit_delay="${5:-5}"
  local attempt http_code
  
  for attempt in $(seq 1 "$max_attempts"); do
    http_code=$(curl -s --connect-timeout 10 --max-time 30 -w "%{http_code}" -o "$output_file" "$url" 2>/dev/null || true)
    if [ "$http_code" = "200" ]; then
      return 0
    elif [ "$http_code" = "429" ]; then
      echo "::warning::HTTP 429 rate limited, waiting before retry (attempt $attempt/$max_attempts)..."
      sleep $((attempt * rate_limit_delay))
    else
      echo "::warning::HTTP request failed with code $http_code (attempt $attempt/$max_attempts)"
      sleep $((attempt * base_delay))
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
