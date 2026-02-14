#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

# Runs PKGBUILD refresh/build steps as user `builder`
# Usage:
#   builder-build.sh <version>
#   builder-build.sh <version> --refresh-only <commit_msg>
# Exit codes: 0=success, 1=error, 2=no working-tree changes
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=common.sh
source "$GITHUB_WORKSPACE/.github/scripts/common.sh"

VERSION="$1"
MODE="${2:-full}"

# Refresh checksums before either commit path
if ! retry_command "${RETRY_MAX_ATTEMPTS:-3}" "${RETRY_DELAY_BASE:-3}" updpkgsums; then
  echo '::error::Check source URLs in PKGBUILD and verify upstream files are accessible'
  exit 1
fi

if [ "$MODE" = "--refresh-only" ]; then
  COMMIT_MSG="${3:?commit message required}"
  makepkg --printsrcinfo > .SRCINFO
  if [ -n "$(git status --porcelain)" ]; then
    git add PKGBUILD .SRCINFO
    git commit -m "$COMMIT_MSG"
  else
    exit 2  # No PKGBUILD/.SRCINFO delta
  fi
else
  # Full path: verify build, regenerate metadata, then commit
  echo 'Verifying build...'
  makepkg -sfr --noconfirm
  echo 'Build verified'

  makepkg --printsrcinfo > .SRCINFO
  git clean -fdx

  if [ -n "$(git status --porcelain)" ]; then
    git add PKGBUILD .SRCINFO
    git commit -m "chore: update to $VERSION"
  else
    exit 2  # No PKGBUILD/.SRCINFO delta
  fi
fi
