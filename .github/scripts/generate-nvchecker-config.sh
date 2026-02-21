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

# Validate TOML, extract package list, and write cleaned config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANED_CONFIG_FILE=$(mktemp)
trap 'rm -f "$CLEANED_CONFIG_FILE"' EXIT

PACKAGES=$(printf '%s' "$PACKAGES_CONFIG" | python3 "$SCRIPT_DIR/validate_packages_config.py" "$CLEANED_CONFIG_FILE")

# Write keyfile.toml with GH_PAT
{
  echo '[keys]'
  echo "github = \"$GH_PAT\""
} > keyfile.toml
chmod 600 keyfile.toml

# Write nvchecker.toml header
cat > nvchecker.toml << 'EOF'
[__config__]
oldver = "old_ver.json"
keyfile = "keyfile.toml"
EOF

# Append cleaned package sections
cat "$CLEANED_CONFIG_FILE" >> nvchecker.toml

# Export package list for downstream steps
echo "PACKAGES=$PACKAGES" >> "$GITHUB_ENV"

echo "Generated nvchecker.toml for packages: $PACKAGES"
