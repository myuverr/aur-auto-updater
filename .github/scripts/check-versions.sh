#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

# Detect upstream updates for configured AUR packages
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=common.sh
source "$GITHUB_WORKSPACE/.github/scripts/common.sh"

# Keep summary below GitHub's 1 MiB limit
MAX_SUMMARY_SIZE=900000

updates='[]'
# Collect per-package errors for the final report
errors='[]'

# add_error <package> <message>
add_error() {
  errors=$(echo "$errors" | jq -c --arg pkg "$1" --arg err "$2" '. + [{package: $pkg, error: $err}]')
}

# Per-run temp workspace
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Build summary in a temp file and append once at the end
SUMMARY_FILE="$TEMP_DIR/check_summary.md"
{
  echo "## Version Check Results"
  echo ""
  echo "| Package | AUR Version | Upstream | Status |"
  echo "|---------|-------------|----------|--------|"
} > "$SUMMARY_FILE"

if [ -z "${PACKAGES:-}" ]; then
  echo "::error::No packages defined (PACKAGES is empty)"
  exit 1
fi

# shellcheck disable=SC2086
for pkg in $PACKAGES; do
  echo "::group::Checking $pkg"

  # Run nvchecker; stderr is captured and sanitized before logging
  nvchecker_stderr="$TEMP_DIR/nvchecker_${pkg}.err"
  if ! nvchecker_output=$(nvchecker -c nvchecker.toml --logger json -e "$pkg" 2>"$nvchecker_stderr"); then
    sanitized_err=$(sanitize_log "$nvchecker_stderr" 5)
    echo "::warning::nvchecker failed for $pkg: ${sanitized_err:-unknown error}"
    echo "::warning::Check nvchecker.toml configuration and upstream source availability"
    echo "| $pkg | - | - | ⚠️ nvchecker failed |" >> "$SUMMARY_FILE"
    add_error "$pkg" "nvchecker failed: ${sanitized_err:-unknown}"
    echo "::endgroup::"
    continue
  fi

  latest_ver_raw=$(echo "$nvchecker_output" | jq -r 'select(.name == "'"$pkg"'") | .version // empty')
  if [ -z "$latest_ver_raw" ]; then
    echo "::warning::Could not parse version for $pkg"
    echo "| $pkg | - | - | ⚠️ Parse failed |" >> "$SUMMARY_FILE"
    add_error "$pkg" "Could not parse upstream version"
    echo "::endgroup::"
    continue
  fi

  # nvchecker `prefix` handles tag prefix stripping.
  latest_ver="$latest_ver_raw"
  echo "Upstream: $latest_ver"

  # Query current version from AUR RPC
  aur_response=""
  aur_response_file="$TEMP_DIR/aur_response_${pkg}.json"
  aur_url="https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg"
  if retry_http_request "$aur_response_file" "$aur_url" "$RETRY_MAX_ATTEMPTS" "$RETRY_DELAY_BASE" "$AUR_RATE_LIMIT_DELAY"; then
    aur_response=$(cat "$aur_response_file")
  fi

  if [ -z "$aur_response" ]; then
    echo "::warning::Could not fetch AUR info for $pkg after $RETRY_MAX_ATTEMPTS attempts"
    echo "::warning::Verify package exists at https://aur.archlinux.org/packages/$pkg"
    echo "| $pkg | - | $latest_ver | ⚠️ AUR fetch failed |" >> "$SUMMARY_FILE"
    add_error "$pkg" "AUR API fetch failed after $RETRY_MAX_ATTEMPTS attempts"
    echo "::endgroup::"
    continue
  fi

  # Validate AUR RPC response schema
  if ! echo "$aur_response" | jq -e '.results' >/dev/null 2>&1; then
    echo "::warning::Invalid AUR API response for $pkg"
    echo "| $pkg | - | $latest_ver | ⚠️ Invalid response |" >> "$SUMMARY_FILE"
    add_error "$pkg" "Invalid AUR API response format"
    echo "::endgroup::"
    continue
  fi

  full_aur_ver=$(echo "$aur_response" | jq -r '.results[0].Version // empty')
  if [ -z "$full_aur_ver" ]; then
    echo "::warning::Package $pkg not found on AUR"
    echo "| $pkg | Not found | $latest_ver | ⚠️ Not on AUR |" >> "$SUMMARY_FILE"
    add_error "$pkg" "Package not found on AUR"
    echo "::endgroup::"
    continue
  fi

  current_ver=$(strip_pkgrel "$full_aur_ver")
  compare_current_ver="$current_ver"
  # Drop AUR epoch only when upstream version has no epoch
  if [[ "$latest_ver" != *:* ]]; then
    compare_current_ver=$(strip_epoch "$current_ver")
  fi
  echo "AUR current: $current_ver (full: $full_aur_ver)"

  # Compare normalized versions
  if [ "$(vercmp "$latest_ver" "$compare_current_ver")" -gt 0 ]; then
    echo "Update needed: $compare_current_ver -> $latest_ver"
    updates=$(echo "$updates" | jq -c --arg pkg "$pkg" --arg ver "$latest_ver" '. + [{package: $pkg, version: $ver}]')
    echo "| $pkg | $compare_current_ver | $latest_ver | ⬆️ Update needed |" >> "$SUMMARY_FILE"
  else
    echo "Up to date"
    echo "| $pkg | $compare_current_ver | $latest_ver | ✅ Up to date |" >> "$SUMMARY_FILE"
  fi

  echo "::endgroup::"
done

echo "matrix={\"include\":$updates}" >> "$GITHUB_OUTPUT"

# Finalize status outputs and summary footer
if [ "$updates" = "[]" ]; then
  echo "has_updates=false" >> "$GITHUB_OUTPUT"
  echo "" >> "$SUMMARY_FILE"
  echo "**Result:** ✅ No updates needed" >> "$SUMMARY_FILE"
else
  echo "has_updates=true" >> "$GITHUB_OUTPUT"
  echo "" >> "$SUMMARY_FILE"
  echo "**Result:** ⬆️ Updates found" >> "$SUMMARY_FILE"
fi

# Append collected errors and emit aggregate failure signal
if [ "$errors" != "[]" ]; then
  error_count=$(echo "$errors" | jq 'length')
  echo "" >> "$SUMMARY_FILE"
  echo "### ⚠️ Errors Encountered ($error_count)" >> "$SUMMARY_FILE"
  echo "" >> "$SUMMARY_FILE"
  echo "| Package | Error |" >> "$SUMMARY_FILE"
  echo "|---------|-------|" >> "$SUMMARY_FILE"
  echo "$errors" | jq -r '.[] | "| \(.package) | \(.error) |"' >> "$SUMMARY_FILE"
  echo "::error::$error_count package(s) encountered errors during version check"
  # Propagate error count to downstream status job
  echo "error_count=$error_count" >> "$GITHUB_OUTPUT"
else
  echo "error_count=0" >> "$GITHUB_OUTPUT"
fi

# Enforce summary size cap
SUMMARY_SIZE=$(wc -c < "$SUMMARY_FILE")
if [ "$SUMMARY_SIZE" -gt "$MAX_SUMMARY_SIZE" ]; then
  echo "::warning::Job summary truncated due to size limit ($SUMMARY_SIZE bytes)"
  head -c "$MAX_SUMMARY_SIZE" "$SUMMARY_FILE" >> "$GITHUB_STEP_SUMMARY"
  echo "" >> "$GITHUB_STEP_SUMMARY"
  echo "" >> "$GITHUB_STEP_SUMMARY"
  echo "*[Summary truncated due to size limit]*" >> "$GITHUB_STEP_SUMMARY"
else
  cat "$SUMMARY_FILE" >> "$GITHUB_STEP_SUMMARY"
fi
