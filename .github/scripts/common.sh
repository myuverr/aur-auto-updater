#!/usr/bin/env bash
# Common utility functions for AUR update workflow
# shellcheck shell=bash

set -euo pipefail

# Retry a command with exponential backoff
# Usage: retry_command <max_attempts> <base_delay> <command...>
# Example: retry_command 3 2 curl -sf "$url"
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

# Safe awk-based replacement for pkgver/pkgrel (handles all special characters)
# Usage: safe_update_pkgbuild_version <file> <new_version>
safe_update_pkgbuild_version() {
  local file="$1"
  local new_version="$2"
  local temp_file
  
  temp_file=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$temp_file'" RETURN
  
  # Use awk to safely replace version without sed escaping issues
  awk -v new_ver="$new_version" '
    /^pkgver=/ { print "pkgver=" new_ver; next }
    /^pkgrel=/ { print "pkgrel=1"; next }
    { print }
  ' "$file" > "$temp_file" && mv "$temp_file" "$file"
}

# Retry HTTP request with exponential backoff (for AUR API)
# Usage: retry_http_request <output_file> <url> <max_attempts> <base_delay> <rate_limit_delay>
# Returns: Sets global HTTP_CODE variable, returns 0 on success, 1 on failure
retry_http_request() {
  local output_file="$1"
  local url="$2"
  local max_attempts="${3:-4}"
  local base_delay="${4:-3}"
  local rate_limit_delay="${5:-5}"
  local attempt http_code
  
  HTTP_CODE=""
  for attempt in $(seq 1 "$max_attempts"); do
    # shellcheck disable=SC2034
    http_code=$(curl -s -w "%{http_code}" -o "$output_file" "$url" 2>/dev/null || true)
    if [ "$http_code" = "200" ]; then
      HTTP_CODE="$http_code"
      return 0
    elif [ "$http_code" = "429" ]; then
      echo "::warning::HTTP 429 rate limited, waiting before retry (attempt $attempt/$max_attempts)..."
      sleep $((attempt * rate_limit_delay))
    else
      echo "::warning::HTTP request failed with code $http_code (attempt $attempt/$max_attempts)"
      sleep $((attempt * base_delay))
    fi
  done
  
  HTTP_CODE="$http_code"
  return 1
}
