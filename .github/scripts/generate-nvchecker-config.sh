#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

# Render nvchecker.toml and keyfile.toml from PACKAGES_CONFIG
# Required env: PACKAGES_CONFIG, GH_PAT
# Exports PACKAGES (space-separated) via GITHUB_ENV
# shellcheck shell=bash

set -euo pipefail

if [ -z "${PACKAGES_CONFIG:-}" ]; then
  echo "::error::PACKAGES_CONFIG variable not set. Configure it in repository settings."
  exit 1
fi

# Validate PACKAGES_CONFIG JSON before rendering files.
if ! echo "$PACKAGES_CONFIG" | jq empty 2>/dev/null; then
  echo "::error::PACKAGES_CONFIG is not valid JSON"
  exit 1
fi

# Write keyfile.toml with GH_PAT
{
  echo '[keys]'
  echo "github = \"$GH_PAT\""
} > keyfile.toml
chmod 600 keyfile.toml

# Write nvchecker.toml header
cat > nvchecker.toml << 'EOF2'
[__config__]
oldver = "old_ver.json"
keyfile = "keyfile.toml"
EOF2

# Append package sections from PACKAGES_CONFIG
# Render each package object as TOML using type-aware value encoding.
echo "$PACKAGES_CONFIG" | jq -r '
  to_entries[] |
  "\n[\(.key)]" as $header |
  [
    $header,
    (
      .value | to_entries[] |
      (.value | type) as $type |
      if $type == "boolean" then
        "\(.key) = \(.value)"
      elif $type == "number" then
        "\(.key) = \(.value)"
      elif $type == "string" then
        # Use JSON string encoding so TOML special chars (for example \d in regex)
        # are emitted as escaped backslashes rather than invalid TOML escapes.
        "\(.key) = \(.value | @json)"
      else
        "\(.key) = \((.value | tostring) | @json)"
      end
    )
  ] | join("\n")
' >> nvchecker.toml

# Export package list for downstream steps
PACKAGES=$(echo "$PACKAGES_CONFIG" | jq -r 'keys | join(" ")')
echo "PACKAGES=$PACKAGES" >> "$GITHUB_ENV"

echo "Generated nvchecker.toml for packages: $PACKAGES"
