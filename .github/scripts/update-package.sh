#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

# Update a single AUR package to a new version.
# Called by the update-package job in aur-update.yml.
# Expects env vars: PKG, VERSION, RETRY_MAX_ATTEMPTS, RETRY_DELAY_BASE
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=common.sh
source "$GITHUB_WORKSPACE/.github/scripts/common.sh"

export GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=$HOME/.ssh/known_hosts -o StrictHostKeyChecking=yes"

echo "Updating $PKG to $VERSION"

# Clone AUR repo with retry
if ! retry_command 3 "$RETRY_DELAY_BASE" git clone "ssh://aur@aur.archlinux.org/${PKG}.git"; then
  echo "::error::Verify SSH key is configured and package exists at https://aur.archlinux.org/packages/$PKG"
  exit 1
fi

cd "$PKG"

# Configure git for this repo
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# Verify PKGBUILD exists
if [ ! -f PKGBUILD ]; then
  echo "::error::PKGBUILD not found"
  exit 1
fi

# Update version
current_ver=$(grep "^pkgver=" PKGBUILD | cut -d= -f2)
echo "Current version: $current_ver"

update_pkgbuild_version PKGBUILD "$VERSION"

# Change ownership for builder (all operations until push)
chown -R builder:builder .

# Setup cleanup trap for build failures
cleanup() {
  echo "Cleaning up build artifacts..."
  rm -rf src pkg *.pkg.tar.* 2>/dev/null || true
}
trap cleanup EXIT

# Update checksums with retry
if ! retry_command 3 "$RETRY_DELAY_BASE" su builder -c 'updpkgsums'; then
  echo "::error::Check source URLs in PKGBUILD and verify upstream files are accessible"
  exit 1
fi

# Verify build
echo "Verifying build..."
su builder -c "makepkg -sfr --noconfirm"
echo "Build verified"

# Generate .SRCINFO, clean artifacts, and prepare commit (all as builder)
# Use a temp file to communicate commit status from subshell
# Use a local file for status to avoid permission issues with builder user
COMMIT_STATUS_FILE=".commit_status"
su builder -c "
  makepkg --printsrcinfo > .SRCINFO
  git clean -fdx
  if [ -n \"\$(git status --porcelain)\" ]; then
    git add PKGBUILD .SRCINFO
    git commit -m 'chore: update to $VERSION'
    echo 'committed' > '$COMMIT_STATUS_FILE'
  fi
"

# Restore ownership for git operations
chown -R root:root .

# Check if commit was made
if [ ! -f "$COMMIT_STATUS_FILE" ]; then
  echo "::error::No changes detected after processing - version mismatch between check and update"
  echo "::error::This may indicate AUR was already updated or version detection issue"
  echo "status=no_changes" >> "$GITHUB_OUTPUT"
  exit 1
fi
rm -f "$COMMIT_STATUS_FILE"

# We have changes to push
# Save commit message for potential reapplication
commit_msg=$(git log -1 --format=%B)

# Push with retry and conflict handling
push_success=false
for attempt in 1 2 3; do
  echo "Pushing to AUR (attempt $attempt/3)..."

  # Fetch latest and check if we need to rebase
  git fetch origin master 2>/dev/null || true

  # Check if our commit is based on latest origin/master
  if ! git merge-base --is-ancestor origin/master HEAD 2>/dev/null; then
    echo "::warning::Remote has new commits, rebasing..."

    if ! git rebase origin/master 2>/dev/null; then
      echo "::warning::Rebase conflict, resetting and reapplying changes..."
      git rebase --abort 2>/dev/null || true
      git reset --hard origin/master

      # Reapply as builder
      update_pkgbuild_version PKGBUILD "$VERSION"
      chown -R builder:builder .
      if ! su builder -c 'updpkgsums' 2>&1; then
        echo "::warning::Failed to regenerate checksums during retry"
        sleep $((attempt * 2))
        continue
      fi
      su builder -c "
        makepkg --printsrcinfo > .SRCINFO
        git add PKGBUILD .SRCINFO
        git commit -m '$commit_msg'
      "
      chown -R root:root .
    fi
  fi

  # Push (requires root for SSH)
  if git push origin master 2>&1; then
    push_success=true
    echo "Successfully pushed $PKG to AUR"
    echo "status=success" >> "$GITHUB_OUTPUT"
    break
  fi

  echo "::warning::Push attempt $attempt failed, retrying in $((attempt * RETRY_DELAY_BASE))s..."
  sleep $((attempt * RETRY_DELAY_BASE))
done

if [ "$push_success" != "true" ]; then
  echo "::error::Failed to push $PKG after 3 attempts"
  echo "::error::Check SSH key permissions and verify no conflicting updates on AUR"
  exit 1
fi
