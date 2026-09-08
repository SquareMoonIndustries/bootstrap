#!/usr/bin/env bash
# Square Moon workstation setup — stage 1. Public on purpose: a brand-new
# machine has no credentials yet, so this is the only thing it can fetch.
# Contains no secrets. Everything it pulls afterwards is private.
#
# Run it as a FILE, not through a pipe:
#
#   curl -fsSL https://raw.githubusercontent.com/SquareMoonIndustries/bootstrap/master/mac.sh -o /tmp/sm-setup.sh
#   bash /tmp/sm-setup.sh developer
#
# `curl … | bash` makes stdin the pipe carrying this script, so Homebrew's
# sudo prompt and `gh auth login` would read script text instead of you.
set -euo pipefail

# Without this, `set -e` exits mute: the tester sees a prompt come back with no
# output and has nothing to report. Print where it died and what to send back.
#
# Deliberately no `set -E`: errtrace would propagate this into command
# substitutions, so a failing one reports twice, and the inner run overwrites
# $BASH_COMMAND with this function's own first line. The one function here
# exits explicitly, so nothing is lost by not inheriting.
on_err() {
  local rc=$?
  {
    echo
    echo "──────────────────────────────────────────────"
    echo " Square Moon setup FAILED"
    echo "──────────────────────────────────────────────"
    echo " line:    ${BASH_LINENO[0]}"
    echo " command: $BASH_COMMAND"
    echo " exit:    $rc"
    echo
    echo " Copy everything above, from the command you ran,"
    echo " and send it to Styrbjörn. Nothing is half-installed"
    echo " in a way that breaks your machine; it is safe to"
    echo " re-run this script after the fix."
    echo "──────────────────────────────────────────────"
  } >&2
}
trap on_err ERR

ROLE="${1:-}"
case "$ROLE" in
  developer|consultant) ;;
  *) echo "usage: bash mac.sh <developer|consultant>" >&2; exit 64 ;;
esac

ORG="SquareMoonIndustries"
SELF_URL="https://raw.githubusercontent.com/$ORG/bootstrap/master/mac.sh"

# Called before anything that has to ask the user a question. A warm machine
# never reaches these, so the piped one-liner still works there.
need_tty() {
  [[ -t 0 ]] && return 0
  cat >&2 <<MSG

This next step ("$1") needs to ask you something, but stdin is not a
terminal — you piped this script into bash. Run it as a file instead:

  curl -fsSL $SELF_URL -o /tmp/sm-setup.sh
  bash /tmp/sm-setup.sh $ROLE

MSG
  exit 1
}

if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install || true
  echo
  echo "Command Line Tools are installing. Click through that dialog, wait for"
  echo "it to finish, then run this script again."
  exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
  need_tty "install Homebrew"
  echo "Installing Homebrew (it will ask for your Mac password)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null || true)"
command -v brew >/dev/null 2>&1 || { echo "Homebrew still not on PATH — stopping" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || brew install gh
if [[ "$ROLE" == "developer" ]]; then
  # Version, not presence: favro-cli needs node >=18, and an old nvm version
  # sitting first on PATH would otherwise satisfy a plain `command -v node`.
  #
  # Both guards matter. With no node at all, `node -v` exits 127; `sed` exits 0;
  # `pipefail` hands the pipeline 127; the assignment inherits it and `set -e`
  # kills the script -- on the very line whose job is to notice node is missing,
  # and mute, because 2>/dev/null ate the message. That is the cold path: a Mac
  # without node could never get one installed. `|| true` covers the same shape
  # for a node that exists but is broken.
  NODE_MAJOR=""
  if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -v 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\).*/\1/p')" || true
  fi
  if [[ -z "$NODE_MAJOR" || "$NODE_MAJOR" -lt 18 ]]; then
    echo "Installing Node (need >=18, found ${NODE_MAJOR:-none})..."
    brew install node
  fi
fi

if ! gh auth status >/dev/null 2>&1; then
  need_tty "sign in to GitHub"
  echo
  echo "Signing in to GitHub — a browser window will open."
  gh auth login --hostname github.com --git-protocol https --web
fi

# Stage 2, from the private repo. Written to a file rather than piped so it
# inherits this script's stdin instead of a pipe.
tmp="$(mktemp -t sm-bootstrap)"
trap 'rm -f "$tmp"' EXIT
gh api "repos/$ORG/skill-library/contents/fleet/bootstrap.sh" \
  -H "Accept: application/vnd.github.raw" > "$tmp"
bash "$tmp" "$ROLE"
