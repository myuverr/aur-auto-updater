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

# Validate TOML and extract package list
PACKAGES=$(printf '%s' "$PACKAGES_CONFIG" | python3 -c '
import sys, tomllib
try:
    data = tomllib.loads(sys.stdin.read())
except tomllib.TOMLDecodeError as e:
    print(f"::error::PACKAGES_CONFIG is not valid TOML: {e}", file=sys.stderr)
    sys.exit(1)
if not data:
    print("::error::PACKAGES_CONFIG contains no package sections", file=sys.stderr)
    sys.exit(1)
print(" ".join(data.keys()))
')

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

printf '\n%s\n' "$PACKAGES_CONFIG" >> nvchecker.toml

# Export package list for downstream steps
echo "PACKAGES=$PACKAGES" >> "$GITHUB_ENV"

echo "Generated nvchecker.toml for packages: $PACKAGES"
