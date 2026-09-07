#!/usr/bin/env bash
# Square Moon workstation setup — stage 1. Public on purpose: this is the only
# thing a bare machine can fetch, since it has no credentials yet. Contains no
# secrets. Installs the prerequisites, authenticates gh, hands off to the
# private repo.
#
#   curl -fsSL https://raw.githubusercontent.com/SquareMoonIndustries/bootstrap/master/mac.sh | bash -s developer
set -euo pipefail

ROLE="${1:-}"
case "$ROLE" in
  developer|consultant) ;;
  *) echo "usage: ... | bash -s <developer|consultant>" >&2; exit 64 ;;
esac

ORG="SquareMoonIndustries"

if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install || true
  echo
  echo "Command Line Tools are installing. Click through that dialog, wait for"
  echo "it to finish, then run this same line again."
  exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew (it will ask for your Mac password)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"

command -v gh >/dev/null 2>&1 || brew install gh
if [[ "$ROLE" == "developer" ]]; then
  command -v node >/dev/null 2>&1 || brew install node
fi

if ! gh auth status >/dev/null 2>&1; then
  echo
  echo "Sign in to GitHub — a browser window will open."
  gh auth login --hostname github.com --git-protocol https --web
fi

gh api "repos/$ORG/skill-library/contents/fleet/bootstrap.sh" \
  -H "Accept: application/vnd.github.raw" | bash -s "$ROLE"
