#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

# Update one AUR package to VERSION
# Required env: PKG, VERSION, RETRY_MAX_ATTEMPTS, RETRY_DELAY_BASE
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=common.sh
source "$GITHUB_WORKSPACE/.github/scripts/common.sh"

BUILDER_SCRIPT="$GITHUB_WORKSPACE/.github/scripts/builder-build.sh"

export GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=$HOME/.ssh/known_hosts -o StrictHostKeyChecking=yes"

# Runs builder-build.sh as user `builder` and restores root ownership
# Returns builder-build.sh exit code
run_as_builder() {
  local rc=0
  chown -R builder:builder .
  if su builder -s /bin/bash -- "$BUILDER_SCRIPT" "$@" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  chown -R root:root .
  return "$rc"
}

# Always publish a per-package summary on exit
UPDATE_STATUS="failed"
write_summary() {
  {
    echo "## Update Result: $PKG"
    echo ""
    echo "| Package | Version | Status |"
    echo "|---------|---------|--------|"
    case "$UPDATE_STATUS" in
      success)    echo "| $PKG | $VERSION | ✅ Updated |" ;;
      no_changes) echo "| $PKG | $VERSION | ⚠️ No changes |" ;;
      *)          echo "| $PKG | $VERSION | ❌ Failed |" ;;
    esac
  } >> "$GITHUB_STEP_SUMMARY"
}
trap write_summary EXIT

echo "Updating $PKG to $VERSION"

# Clone AUR repo with retries
if ! retry_command "$RETRY_MAX_ATTEMPTS" "$RETRY_DELAY_BASE" git clone "ssh://aur@aur.archlinux.org/${PKG}.git"; then
  echo "::error::Verify SSH key is configured and package exists at https://aur.archlinux.org/packages/$PKG"
  exit 1
fi

cd "$PKG"

# Configure git identity for this repo
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# Validate PKGBUILD presence
if [ ! -f PKGBUILD ]; then
  echo "::error::PKGBUILD not found"
  exit 1
fi

# Apply target version in PKGBUILD
current_ver=$(awk -F= '/^pkgver=/{print $2}' PKGBUILD)
echo "Current version: $current_ver"

update_pkgbuild_version PKGBUILD "$VERSION"

# Build and commit in builder context
if run_as_builder "$VERSION"; then
  :
else
  builder_exit=$?
  if [ "${builder_exit:-1}" -eq 2 ]; then
    echo "::error::No changes detected after processing — version mismatch between check and update"
    echo "::error::This may indicate AUR was already updated or version detection issue"
    UPDATE_STATUS="no_changes"
    exit 1
  fi
  exit 1
fi

# Preserve commit message for conflict recovery
commit_msg=$(git log -1 --format=%B)

# Push with fetch/rebase retry loop
push_to_aur() {
  local attempt

  for attempt in $(seq 1 "$RETRY_MAX_ATTEMPTS"); do
    echo "Pushing to AUR (attempt $attempt/$RETRY_MAX_ATTEMPTS)..."

    # Refresh origin/master before push
    git fetch origin master 2>/dev/null || true

    # Rebase if local HEAD is behind origin/master
    if ! git merge-base --is-ancestor origin/master HEAD 2>/dev/null; then
      echo "::warning::Remote has new commits, rebasing..."

      if ! git rebase origin/master 2>/dev/null; then
        echo "::warning::Rebase conflict, resetting and reapplying changes..."
        git rebase --abort 2>/dev/null || true
        git reset --hard origin/master

        # Rebuild commit on top of refreshed origin/master
        update_pkgbuild_version PKGBUILD "$VERSION"
        if run_as_builder "$VERSION" --refresh-only "$commit_msg"; then
          refresh_exit=0
        else
          refresh_exit=$?
        fi
        if [ "$refresh_exit" -eq 2 ]; then
          echo "No changes after refresh — already up to date"
        elif [ "$refresh_exit" -ne 0 ]; then
          echo "::warning::Failed to regenerate checksums during retry"
          sleep $((attempt * 2))
          continue
        fi
      fi
    fi

    # Push via SSH
    if git push origin master 2>&1; then
      echo "Successfully pushed $PKG to AUR"
      return 0
    fi

    echo "::warning::Push attempt $attempt failed, retrying in $((attempt * RETRY_DELAY_BASE))s..."
    sleep $((attempt * RETRY_DELAY_BASE))
  done

  return 1
}

if push_to_aur; then
  UPDATE_STATUS="success"
else
  echo "::error::Failed to push $PKG after $RETRY_MAX_ATTEMPTS attempts"
  echo "::error::Check SSH key permissions and verify no conflicting updates on AUR"
  exit 1
fi
