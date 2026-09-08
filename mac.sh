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
  # ---------------------------------------------------------------------------
  # Runtime check: favro-cli and workstation tooling require a modern JS runtime:
  #   - Node >= 18 (via PATH, Homebrew, NVM, FNM, ASDF, Volta, Mise, Nodenv)
  #   - Deno (native Deno support for favro-cli is in the works; runs via Node/npm compat)
  # ---------------------------------------------------------------------------

  find_node_gte_18() {
    local candidates=()
    local p

    # 1. Current PATH
    if command -v node >/dev/null 2>&1; then
      candidates+=("$(command -v node)")
    fi

    # 2. Homebrew and standard locations
    for p in /opt/homebrew/bin/node /usr/local/bin/node; do
      [[ -x "$p" ]] && candidates+=("$p")
    done

    # 3. Version managers (NVM, FNM, ASDF, Volta, Mise, Nodenv)
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    if [[ -d "$nvm_dir/versions/node" ]]; then
      for p in "$nvm_dir"/versions/node/*/bin/node; do
        [[ -x "$p" ]] && candidates+=("$p")
      done
    fi

    for p in "${FNM_DIR:-$HOME/.fnm}"/current/bin/node \
             "$HOME/.local/share/fnm/current/bin/node" \
             "$HOME/.asdf/shims/node" \
             "$HOME/.asdf/installs/nodejs"/*/bin/node \
             "${VOLTA_HOME:-$HOME/.volta}/bin/node" \
             "$HOME/.local/share/mise/installs/node"/*/bin/node \
             "$HOME/.nodenv/shims/node" \
             "$HOME/.nodenv/versions"/*/bin/node; do
      [[ -x "$p" ]] && candidates+=("$p")
    done

    if [[ ${#candidates[@]} -gt 0 ]]; then
      for p in "${candidates[@]}"; do
        local major
        major="$("$p" -v 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\).*/\1/p' || true)"
        if [[ -n "$major" && "$major" -ge 18 ]]; then
          echo "$p"
          return 0
        fi
      done
    fi

    return 1
  }

  VALID_NODE="$(find_node_gte_18 || true)"
  DENO_BIN="$(command -v deno 2>/dev/null || { [[ -x /opt/homebrew/bin/deno ]] && echo /opt/homebrew/bin/deno; } || true)"

  if [[ -n "$VALID_NODE" ]]; then
    # Pin valid Node first on PATH so later stages use it
    NODE_DIR="$(dirname "$VALID_NODE")"
    export PATH="$NODE_DIR:$PATH"
    echo "Using Node $("$VALID_NODE" -v) at $VALID_NODE"
  elif [[ -n "$DENO_BIN" ]]; then
    export PATH="$HOME/.deno/bin:$PATH"
    echo "Using Deno $("$DENO_BIN" --version | head -n 1) (Node & npm compatible)"

    # Note: Native Deno support for favro-cli is in the works. In the meantime,
    # provide node/npm shims in ~/.deno/bin for any downstream tooling expecting them.
    mkdir -p "$HOME/.deno/bin" 2>/dev/null || true
    if [[ -d "$HOME/.deno/bin" && -w "$HOME/.deno/bin" ]]; then
      if ! command -v node >/dev/null 2>&1; then
        cat <<'SHIM' > "$HOME/.deno/bin/node"
#!/bin/sh
if [ "$1" = "-v" ] || [ "$1" = "--version" ]; then
  exec deno eval "console.log(process.version)"
fi
exec deno run -A "$@"
SHIM
        chmod +x "$HOME/.deno/bin/node"
      fi

      if ! command -v npm >/dev/null 2>&1; then
        cat <<'SHIM' > "$HOME/.deno/bin/npm"
#!/bin/sh
case "$1" in
  install|i)
    if [ "${2:-}" = "-g" ] || [ "${2:-}" = "--global" ]; then
      shift 2
      exec deno install -g -A "npm:$@"
    fi
    exec deno install "$@"
    ;;
  *)
    exec deno x "$@"
    ;;
esac
SHIM
        chmod +x "$HOME/.deno/bin/npm"
      fi
    fi
  else
    CURRENT_NODE_VER="$(node -v 2>/dev/null || true)"
    if [[ -n "$CURRENT_NODE_VER" ]]; then
      echo "Existing Node version ($CURRENT_NODE_VER) is older than 18."
    fi
    echo "Installing Node via Homebrew (need >=18)..."
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
