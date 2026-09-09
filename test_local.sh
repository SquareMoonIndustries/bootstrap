#!/usr/bin/env bash
# ==============================================================================
# Square Moon Deno Runtime Support — Local Verification Test Suite
# ==============================================================================
# Usage:
#   ./test_local.sh          # Runs comprehensive tests in an isolated sandbox
#   ./test_local.sh --apply  # Installs shims and tests against real ~/.local/bin
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY_REAL=0

if [[ "${1:-}" == "--apply" ]]; then
  APPLY_REAL=1
fi

echo "============================================================"
echo " Square Moon Deno Runtime Local Verification Suite"
echo "============================================================"

# --- Step 1: Pre-flight Environment Inspection ---
echo
echo "[1/5] Checking current host environment..."
echo "  • Operating System : $(uname -s) $(uname -m)"
echo "  • Node on PATH     : $(command -v node 2>/dev/null || echo 'NONE (as expected)')"
echo "  • Deno on PATH     : $(command -v deno 2>/dev/null || echo 'NONE')"
echo "  • Homebrew Deno    : $(ls -l /opt/homebrew/bin/deno 2>/dev/null || echo 'NONE')"
echo "  • ~/.deno/bin/deno : $(ls -l "$HOME/.deno/bin/deno" 2>/dev/null || echo 'NONE')"

DENO_FOUND=""
for c in "$(command -v deno || true)" /opt/homebrew/bin/deno "$HOME/.deno/bin/deno" /usr/local/bin/deno; do
  if [[ -n "$c" && -x "$c" ]]; then
    DENO_FOUND="$c"
    break
  fi
done

if [[ -z "$DENO_FOUND" ]]; then
  echo "❌ Error: Deno binary not found on this system." >&2
  exit 1
fi
echo "  ✅ Resolved Deno binary: $DENO_FOUND ($("$DENO_FOUND" --version | head -1))"

# Locate mac.sh source
MAC_SH=""
for p in "$SCRIPT_DIR/mac.sh" "$SCRIPT_DIR/bootstrap/mac.sh"; do
  if [[ -f "$p" ]]; then
    MAC_SH="$p"
    break
  fi
done

if [[ -z "$MAC_SH" ]]; then
  echo "❌ Error: Could not locate mac.sh in $SCRIPT_DIR" >&2
  exit 1
fi
echo "  ✅ Resolved mac.sh: $MAC_SH"

# --- Step 2: Target Directories Setup ---
if [[ "$APPLY_REAL" -eq 1 ]]; then
  TARGET_LOCAL_BIN="$HOME/.local/bin"
  TARGET_DENO_BIN="$HOME/.deno/bin"
  TARGET_PREFIX="$HOME/.squaremoon/favro-cli"
  echo
  echo "[2/5] Target mode: LIVE APPLICATION"
  echo "  • Shims will be written to: $TARGET_LOCAL_BIN and $TARGET_DENO_BIN"
  echo "  • Favro prefix: $TARGET_PREFIX"
else
  SANDBOX_DIR="$(mktemp -d -t sqm-deno-test)"
  trap 'rm -rf "$SANDBOX_DIR"' EXIT
  TARGET_LOCAL_BIN="$SANDBOX_DIR/.local/bin"
  TARGET_DENO_BIN="$SANDBOX_DIR/.deno/bin"
  TARGET_PREFIX="$SANDBOX_DIR/.squaremoon/favro-cli"
  echo
  echo "[2/5] Target mode: ISOLATED SANDBOX (No changes to user files)"
  echo "  • Sandbox directory: $SANDBOX_DIR"
fi

mkdir -p "$TARGET_LOCAL_BIN" "$TARGET_DENO_BIN"

# --- Step 3: Write and Verify Shims ---
echo
echo "[3/5] Generating node and npm shims using mac.sh implementation..."

# Dynamically extract write_shims from mac.sh to guarantee exact production behavior
eval "$(sed -n '/write_shims() {/,/^[[:space:]]*write_shims "\$HOME\/\.local\/bin"/p' "$MAC_SH" | sed 's/write_shims "\$HOME.*//')"

write_shims "$TARGET_LOCAL_BIN"
write_shims "$TARGET_DENO_BIN"

echo "  • Testing node -v..."
NODE_VER="$("$TARGET_LOCAL_BIN/node" -v)"
echo "    -> Output: $NODE_VER"
[[ "$NODE_VER" =~ ^v[0-9]+ ]] || { echo "❌ Failed: Unexpected node version output"; exit 1; }

echo "  • Testing node -p '20 + 22'..."
NODE_PRINT="$("$TARGET_LOCAL_BIN/node" -p '20 + 22')"
echo "    -> Output: $NODE_PRINT"
[[ "$NODE_PRINT" == "42" ]] || { echo "❌ Failed: Unexpected node print output"; exit 1; }

echo "  • Testing npm -v..."
NPM_VER="$("$TARGET_LOCAL_BIN/npm" -v)"
echo "    -> Output: $NPM_VER"
[[ "$NPM_VER" =~ 10\. ]] || { echo "❌ Failed: Unexpected npm version output"; exit 1; }

echo "  ✅ All shims responded correctly!"

# --- Step 4: Test CLI Package Installation & Execution ---
echo
echo "[4/5] Testing fleet installation using npm shim and package tarball..."

# Locate favro-cli tarball or generate a self-contained test tarball
TGZ=""
for t in "$SCRIPT_DIR/downloaded_subscripts/favro-cli/square-moon-favro-cli-5.1.2.tgz" \
         "$SCRIPT_DIR/../downloaded_subscripts/favro-cli/square-moon-favro-cli-5.1.2.tgz"; do
  if [[ -f "$t" ]]; then
    TGZ="$t"
    break
  fi
done

if [[ -z "$TGZ" ]]; then
  echo "  • Local favro-cli tarball not found; generating mock package tarball for verification..."
  MOCK_DIR="$(mktemp -d -t sqm-mock-pkg)"
  mkdir -p "$MOCK_DIR/package/dist"
  cat <<'EOF' > "$MOCK_DIR/package/package.json"
{
  "name": "@square-moon/favro-cli",
  "version": "5.1.2",
  "bin": { "favro": "./dist/cli.js" }
}
EOF
  cat <<'EOF' > "$MOCK_DIR/package/dist/cli.js"
#!/usr/bin/env node
if (process.argv.includes("--version")) {
  console.log("5.1.2");
  process.exit(0);
}
console.log("Usage: favro [options] [command]");
EOF
  chmod +x "$MOCK_DIR/package/dist/cli.js"
  TGZ="$MOCK_DIR/mock-favro-5.1.2.tgz"
  tar -czf "$TGZ" -C "$MOCK_DIR" package
  rm -rf "$MOCK_DIR/package"
fi

"$TARGET_LOCAL_BIN/npm" install --prefix "$TARGET_PREFIX" --no-save --no-fund --no-audit "$TGZ"

CLI_FILE="$TARGET_PREFIX/node_modules/@square-moon/favro-cli/dist/cli.js"
if [[ ! -x "$CLI_FILE" ]]; then
  echo "❌ Error: $CLI_FILE was not marked executable!" >&2
  exit 1
fi

# Symlink favro into bin
ln -sf "$CLI_FILE" "$TARGET_LOCAL_BIN/favro"

echo "  • Executing favro --version via shebang..."
FAVRO_VER="$(PATH="$TARGET_LOCAL_BIN:$PATH" "$TARGET_LOCAL_BIN/favro" --version)"
echo "    -> Output: $FAVRO_VER"
[[ "$FAVRO_VER" == "5.1.2" ]] || { echo "❌ Failed: Unexpected favro version: $FAVRO_VER"; exit 1; }

echo "  • Executing favro --help (first line)..."
PATH="$TARGET_LOCAL_BIN:$PATH" "$TARGET_LOCAL_BIN/favro" --help | head -n 1

echo "  ✅ CLI package is fully functional under Deno!"

# --- Step 5: LaunchAgent / Cron Environment Simulation ---
echo
echo "[5/5] Testing non-interactive LaunchAgent PATH resilience..."
(
  # Clean LaunchAgent PATH exactly as defined in se.squaremoon.fleet.plist:
  export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  
  # Prepend the fleet node directory:
  export PATH="$TARGET_LOCAL_BIN:$PATH"
  
  # Verify node and favro in this bare environment
  V_N="$(node -v)"
  V_F="$("$TARGET_LOCAL_BIN/favro" --version)"
  echo "  • LaunchAgent node  : $V_N"
  echo "  • LaunchAgent favro : $V_F"
)
echo "  ✅ LaunchAgent non-interactive execution passed!"

echo
echo "============================================================"
echo " 🎉 ALL LOCAL TESTS PASSED!"
if [[ "$APPLY_REAL" -eq 1 ]]; then
  echo " The shims and favro-cli are now actively installed in:"
  echo "   • $TARGET_LOCAL_BIN/node"
  echo "   • $TARGET_LOCAL_BIN/npm"
  echo "   • $TARGET_LOCAL_BIN/favro"
  echo " You can test running 'favro' directly in your terminal!"
else
  echo " Ran in isolated sandbox. To install onto your actual machine,"
  echo " run: ./test_local.sh --apply"
fi
echo "============================================================"
