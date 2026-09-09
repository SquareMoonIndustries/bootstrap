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

# macOS only, and checked before anything else. Without this, a Linux or WSL
# box falls into the Xcode branch below, prints "Command Line Tools are
# installing", and exits 0 -- reporting success for an install that never
# happened. Everything here is Darwin-specific: xcode-select, Homebrew's
# prefixes, launchctl for the hourly agent, osascript for notifications.
if [[ "$(uname -s)" != "Darwin" ]]; then
  cat >&2 <<MSG

This installer is for macOS only. You appear to be on $(uname -s).

There is no Windows or Linux version yet. If you need the skill library on
this machine, tell Styrbjörn -- do not try to adapt this script, and do not
let an AI agent adapt it for you. It installs a launchd agent and uses
Homebrew and osascript, none of which exist here.

MSG
  exit 1
fi

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

# Look for brew where it actually lives, not on PATH. A freshly installed
# Homebrew is not on the PATH of the shell you installed it from -- the
# installer writes /etc/paths.d/homebrew, which only a new login shell picks
# up. `command -v brew` therefore says "missing" on a second run in the same
# terminal, and this script would start the whole install again, sudo prompt
# and all. A tester hit exactly that: installed Homebrew, script stopped for an
# unrelated reason, re-ran, and was asked to install Homebrew a second time.
find_brew() {
  local candidate
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Persist it for the user's own shell too, so new terminals have brew without
# them pasting the three commands Homebrew prints (which scroll past inside a
# longer run, and which one tester mis-pasted). Idempotent, and skipped for a
# shell whose profile we would only be guessing at.
persist_brew() {
  local brew_bin="$1" profile
  case "$(basename "${SHELL:-}")" in
    bash) profile="$HOME/.bash_profile" ;;
    zsh)  profile="$HOME/.zprofile" ;;
    *)
      echo "Add this to your shell profile so new terminals find Homebrew:" >&2
      echo "  eval \"\$($brew_bin shellenv)\"" >&2
      return 0
      ;;
  esac
  if [[ -f "$profile" ]] && grep -qF "$brew_bin shellenv" "$profile"; then
    return 0
  fi
  {
    echo
    echo "# Added by Square Moon setup"
    echo "eval \"\$($brew_bin shellenv)\""
  } >> "$profile"
  echo "Added Homebrew to $profile (takes effect in new terminals)."
}

BREW_BIN="$(find_brew || true)"
if [[ -z "$BREW_BIN" ]]; then
  need_tty "install Homebrew"
  echo "Installing Homebrew (it will ask for your Mac password)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  BREW_BIN="$(find_brew || true)"
  if [[ -n "$BREW_BIN" ]]; then
    persist_brew "$BREW_BIN"
  fi
fi
if [[ -z "$BREW_BIN" ]]; then
  echo "Homebrew is not at /opt/homebrew or /usr/local after installing — stopping" >&2
  exit 1
fi
eval "$("$BREW_BIN" shellenv)"
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
  DENO_BIN=""
  for p in "$(command -v deno 2>/dev/null || true)" /opt/homebrew/bin/deno "$HOME/.deno/bin/deno" /usr/local/bin/deno; do
    if [[ -n "$p" && -x "$p" ]]; then
      DENO_BIN="$p"
      break
    fi
  done

  if [[ -n "$VALID_NODE" ]]; then
    # Pin valid Node first on PATH so later stages use it
    NODE_DIR="$(dirname "$VALID_NODE")"
    export PATH="$NODE_DIR:$PATH"
    echo "Using Node $("$VALID_NODE" -v) at $VALID_NODE"
  elif [[ -n "$DENO_BIN" ]]; then
    mkdir -p "$HOME/.deno/bin" "$HOME/.local/bin" 2>/dev/null || true
    export PATH="$HOME/.local/bin:$HOME/.deno/bin:$PATH"
    echo "Using Deno $("$DENO_BIN" --version | head -n 1) (Node & npm compatible)"

    # Note: Native Deno support for favro-cli is in the works. In the meantime,
    # provide node/npm shims in ~/.local/bin and ~/.deno/bin for any downstream tooling expecting them.
    write_shims() {
      local dir="$1"
      mkdir -p "$dir" 2>/dev/null || true
      [[ -d "$dir" && -w "$dir" ]] || return 0

      cat <<'SHIM' > "$dir/node"
#!/bin/sh
export PATH="$HOME/.deno/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ "$1" = "-v" ] || [ "$1" = "--version" ]; then
  exec deno eval "console.log(process.version)"
elif [ "$1" = "-p" ] || [ "$1" = "--print" ]; then
  shift
  exec deno eval -p "$@"
elif [ "$1" = "-e" ] || [ "$1" = "--eval" ]; then
  shift
  exec deno eval "$@"
elif [ -z "$1" ]; then
  exec deno repl
else
  exec deno run -A --unstable-detect-cjs "$@"
fi
SHIM
      chmod +x "$dir/node"

      cat <<'SHIM' > "$dir/npm"
#!/bin/bash
set -e
export PATH="$HOME/.deno/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

cmd="${1:-}"

case "$cmd" in
  install|i|add)
    shift
    prefix=""
    global=0
    tgz_files=()
    pkgs=()

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --prefix)
          prefix="$2"
          shift 2
          ;;
        --prefix=*)
          prefix="${1#*=}"
          shift
          ;;
        -g|--global)
          global=1
          shift
          ;;
        --no-save|--no-fund|--no-audit|--save|--save-dev|--save-prod|-E|--save-exact)
          shift
          ;;
        *.tgz)
          tgz_files+=("$1")
          shift
          ;;
        -*)
          shift
          ;;
        *)
          pkgs+=("$1")
          shift
          ;;
      esac
    done

    if [[ ${#tgz_files[@]} -gt 0 ]]; then
      for tgz in "${tgz_files[@]}"; do
        if [[ ! -f "$tgz" ]]; then
          echo "npm: tarball not found: $tgz" >&2
          exit 1
        fi

        pkg_name="$(tar -xzf "$tgz" -O package/package.json 2>/dev/null | sed -n 's/.*"name":[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
        if [[ -z "$pkg_name" ]]; then
          pkg_name="package"
        fi

        base_dir="${prefix:-.}"
        mkdir -p "$base_dir"

        tmp_pkg="$(mktemp -d)"
        tar -xzf "$tgz" -C "$tmp_pkg" --strip-components=1

        (cd "$tmp_pkg" && deno install -q 2>&1) || true

        chmod +x "$tmp_pkg"/dist/*.js 2>/dev/null || true

        dest_dir="$base_dir/node_modules/$pkg_name"
        mkdir -p "$(dirname "$dest_dir")"
        rm -rf "$dest_dir"
        mv "$tmp_pkg" "$dest_dir"
      done
      exit 0
    elif [[ $global -eq 1 ]]; then
      exec deno install -g -A "npm:${pkgs[@]}"
    elif [[ -n "$prefix" ]]; then
      (cd "$prefix" && deno install -q "${pkgs[@]}")
      exit 0
    else
      exec deno install -q "${pkgs[@]}"
    fi
    ;;
  -v|--version)
    echo "10.0.0 (deno-shim)"
    ;;
  *)
    exec deno x "$@"
    ;;
esac
SHIM
      chmod +x "$dir/npm"
    }

    write_shims "$HOME/.local/bin"
    write_shims "$HOME/.deno/bin"
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
