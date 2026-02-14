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
echo "$PACKAGES_CONFIG" | jq -r 'to_entries[] | 
  "[\(.key)]\nsource = \"github\"\ngithub = \"\(.value.github)\"\n" +
  (if .value.use_latest_release then "use_latest_release = true\n" else "" end) +
  (if .value.use_max_tag then "use_max_tag = true\n" else "" end) +
  (if .value.prefix then "prefix = \"\(.value.prefix)\"\n" else "" end) +
  (if .value.include_regex then "include_regex = '\''\(.value.include_regex)'\''\n" else "" end)
' >> nvchecker.toml

# Export package list for downstream steps
PACKAGES=$(echo "$PACKAGES_CONFIG" | jq -r 'keys | join(" ")')
echo "PACKAGES=$PACKAGES" >> "$GITHUB_ENV"

echo "Generated nvchecker.toml for packages: $PACKAGES"
