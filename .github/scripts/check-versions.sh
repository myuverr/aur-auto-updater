#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

# Check which AUR packages have upstream updates available.
# Called by the check-versions job in aur-update.yml.
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=common.sh
source "$GITHUB_WORKSPACE/.github/scripts/common.sh"

updates='[]'
# Track errors for final report instead of failing immediately
errors='[]'

# Create unique temp directory for this run
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Initialize summary in temp file to avoid duplication
SUMMARY_FILE="$TEMP_DIR/check_summary.md"
{
  echo "## Version Check Results"
  echo ""
  echo "| Package | AUR Version | Upstream | Status |"
  echo "|---------|-------------|----------|--------|"
} > "$SUMMARY_FILE"

# shellcheck disable=SC2086
for pkg in $PACKAGES; do
  echo "::group::Checking $pkg"

  # Get upstream version
  # Note: stderr is captured separately to prevent token leakage while preserving debug info
  nvchecker_stderr="$TEMP_DIR/nvchecker_${pkg}.err"
  if ! nvchecker_output=$(nvchecker -c nvchecker.toml --logger json -e "$pkg" 2>"$nvchecker_stderr"); then
    sanitized_err=$(sanitize_log "$nvchecker_stderr" | head -5)
    echo "::warning::nvchecker failed for $pkg: ${sanitized_err:-unknown error}"
    echo "::warning::Check nvchecker.toml configuration and upstream source availability"
    echo "| $pkg | - | - | ⚠️ nvchecker failed |" >> "$SUMMARY_FILE"
    errors=$(echo "$errors" | jq -c --arg pkg "$pkg" --arg err "nvchecker failed: ${sanitized_err:-unknown}" '. + [{package: $pkg, error: $err}]')
    echo "::endgroup::"
    continue
  fi

  latest_ver_raw=$(echo "$nvchecker_output" | jq -r 'select(.name == "'"$pkg"'") | .version // empty')
  if [ -z "$latest_ver_raw" ]; then
    echo "::warning::Could not parse version for $pkg"
    echo "| $pkg | - | - | ⚠️ Parse failed |" >> "$SUMMARY_FILE"
    errors=$(echo "$errors" | jq -c --arg pkg "$pkg" --arg err "Could not parse upstream version" '. + [{package: $pkg, error: $err}]')
    echo "::endgroup::"
    continue
  fi

  # Strip 'v' prefix
  latest_ver="${latest_ver_raw#v}"
  echo "Upstream: $latest_ver"

  # Get current AUR version (full version string with epoch support)
  # Use retry_http_request from common.sh
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
    errors=$(echo "$errors" | jq -c --arg pkg "$pkg" --arg err "AUR API fetch failed after $RETRY_MAX_ATTEMPTS attempts" '. + [{package: $pkg, error: $err}]')
    echo "::endgroup::"
    continue
  fi

  # Validate JSON response
  if ! echo "$aur_response" | jq -e '.results' >/dev/null 2>&1; then
    echo "::warning::Invalid AUR API response for $pkg"
    echo "| $pkg | - | $latest_ver | ⚠️ Invalid response |" >> "$SUMMARY_FILE"
    errors=$(echo "$errors" | jq -c --arg pkg "$pkg" --arg err "Invalid AUR API response format" '. + [{package: $pkg, error: $err}]')
    echo "::endgroup::"
    continue
  fi

  full_aur_ver=$(echo "$aur_response" | jq -r '.results[0].Version // empty')
  if [ -z "$full_aur_ver" ]; then
    echo "::warning::Package $pkg not found on AUR"
    echo "| $pkg | Not found | $latest_ver | ⚠️ Not on AUR |" >> "$SUMMARY_FILE"
    errors=$(echo "$errors" | jq -c --arg pkg "$pkg" --arg err "Package not found on AUR" '. + [{package: $pkg, error: $err}]')
    echo "::endgroup::"
    continue
  fi

  # Extract version without pkgrel (handle epoch:version-pkgrel format)
  # Examples: "1.0.0-1" -> "1.0.0", "1:2.0.0-1" -> "1:2.0.0"
  current_ver=$(echo "$full_aur_ver" | sed 's/-[0-9]*$//')
  # For comparison, strip epoch from both if upstream doesn't have it
  current_ver_no_epoch="${current_ver#*:}"
  echo "AUR current: $current_ver (full: $full_aur_ver)"

  # Compare versions
  if [ "$(vercmp "$latest_ver" "$current_ver_no_epoch")" -gt 0 ]; then
    echo "Update needed: $current_ver_no_epoch -> $latest_ver"
    updates=$(echo "$updates" | jq -c --arg pkg "$pkg" --arg ver "$latest_ver" '. + [{package: $pkg, version: $ver}]')
    echo "| $pkg | $current_ver_no_epoch | $latest_ver | ⬆️ Update needed |" >> "$SUMMARY_FILE"
  else
    echo "Up to date"
    echo "| $pkg | $current_ver_no_epoch | $latest_ver | ✅ Up to date |" >> "$SUMMARY_FILE"
  fi

  echo "::endgroup::"
done

echo "matrix={\"include\":$updates}" >> "$GITHUB_OUTPUT"

# Finalize summary
if [ "$updates" = "[]" ]; then
  echo "has_updates=false" >> "$GITHUB_OUTPUT"
  echo "" >> "$SUMMARY_FILE"
  echo "**Result:** ✅ No updates needed" >> "$SUMMARY_FILE"
else
  echo "has_updates=true" >> "$GITHUB_OUTPUT"
  echo "" >> "$SUMMARY_FILE"
  echo "**Result:** ⬆️ Updates found" >> "$SUMMARY_FILE"
fi

# Report collected errors
if [ "$errors" != "[]" ]; then
  error_count=$(echo "$errors" | jq 'length')
  echo "" >> "$SUMMARY_FILE"
  echo "### ⚠️ Errors Encountered ($error_count)" >> "$SUMMARY_FILE"
  echo "" >> "$SUMMARY_FILE"
  echo "| Package | Error |" >> "$SUMMARY_FILE"
  echo "|---------|-------|" >> "$SUMMARY_FILE"
  echo "$errors" | jq -r '.[] | "| \(.package) | \(.error) |"' >> "$SUMMARY_FILE"
  echo "::error::$error_count package(s) encountered errors during version check"
  # Save error count to output for later failure
  echo "error_count=$error_count" >> "$GITHUB_OUTPUT"
else
  echo "error_count=0" >> "$GITHUB_OUTPUT"
fi

# Write to job summary with size limit check
SUMMARY_SIZE=$(wc -c < "$SUMMARY_FILE")
if [ "$SUMMARY_SIZE" -gt "$MAX_SUMMARY_SIZE" ]; then
  echo "::warning::Job summary truncated due to size limit ($SUMMARY_SIZE bytes)"
  head -c "$MAX_SUMMARY_SIZE" "$SUMMARY_FILE" >> "$GITHUB_STEP_SUMMARY"
  echo "" >> "$GITHUB_STEP_SUMMARY"
  echo "" >> "$GITHUB_STEP_SUMMARY"
  echo "*[Summary truncated due to size limit]*" >> "$GITHUB_STEP_SUMMARY"
else
  # Write to job summary
  cat "$SUMMARY_FILE" >> "$GITHUB_STEP_SUMMARY"
fi
