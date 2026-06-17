#!/usr/bin/env bash
#
# install.sh - Set up the global `session-aligner` command and make the scripts
# runnable. This is a thin convenience wrapper: it does NOT change how the tool
# works, it just lets you run `session-aligner ...` from anywhere instead of
# `./aligner.sh ...` from this folder.
#
# Run it once:   ./install.sh
set -u

# Resolve this script's real folder (handles symlinks + spaces).
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  dir="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [ "${SOURCE:0:1}" != "/" ] && SOURCE="$dir/$SOURCE"
done
REPO_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

ALIGNER="${REPO_DIR}/aligner.sh"
BIN_DIR="/usr/local/bin"
LINK="${BIN_DIR}/session-aligner"

OK="  \xE2\x9C\x93"   # green-ish check (✓)
BAD="  \xE2\x9C\x97"  # cross (✗)
WARN="  \xE2\x9A\xA0" # warning (⚠)

say()  { printf '%b\n' "$1"; }
check(){ printf "${OK} %s\n" "$1"; }
fail() { printf "${BAD} %s\n" "$1"; }
warn() { printf "${WARN} %s\n" "$1"; }

echo "Session Aligner Installer"
echo "-------------------------"
echo
echo "This installs the command:"
echo
echo "  session-aligner"
echo
echo "After install, you can run Session Aligner from anywhere:"
echo
echo "  session-aligner status"
echo "  session-aligner setup"
echo "  session-aligner test"
echo
printf 'Continue? [Y/n] '
read -r reply
case "$(printf '%s' "${reply:-y}" | tr '[:upper:]' '[:lower:]')" in
  n|no) echo "Cancelled. You can still use ./aligner.sh from this folder."; exit 0 ;;
esac

echo
echo "Checking requirements..."

# Make our scripts executable.
chmod +x "${REPO_DIR}/aligner.sh" "${REPO_DIR}/ping.sh" "${REPO_DIR}/ping.exp" \
         "${REPO_DIR}/schedule-wakes.sh" "${REPO_DIR}/install.sh" 2>/dev/null || true

# macOS?
if [ "$(uname -s)" = "Darwin" ]; then
  check "macOS detected"
else
  fail "This tool is macOS-only (auto-wake uses macOS pmset/launchd)."
fi

# Claude Code present? (warn-only)
if command -v claude >/dev/null 2>&1; then
  check "Claude Code found: $(command -v claude)"
else
  warn "Claude Code not found. Install it and run 'claude' then '/login'"
  warn "before sending a ping (otherwise pings will fail)."
fi

# expect present? (warn-only, but it is required for pings)
if command -v expect >/dev/null 2>&1; then
  check "expect found: $(command -v expect)"
else
  warn "'expect' not found - it is REQUIRED for the interactive Claude Code"
  warn "automation. Install Xcode Command Line Tools: xcode-select --install"
fi

# Scripts executable?
if [ -x "$ALIGNER" ] && [ -x "${REPO_DIR}/ping.sh" ] && [ -x "${REPO_DIR}/schedule-wakes.sh" ]; then
  check "scripts are executable"
else
  fail "could not make scripts executable - try: chmod +x *.sh ping.exp"
fi

# Create the global command symlink.
echo
HAVE_GLOBAL=0
mkdir -p "$BIN_DIR" 2>/dev/null || true
if ln -sf "$ALIGNER" "$LINK" 2>/dev/null; then
  HAVE_GLOBAL=1
  check "Installed command: ${LINK}"
else
  echo "Creating ${LINK} needs admin rights (because ${BIN_DIR} is owned by root)."
  echo "You'll be asked for your Mac password once. It is not stored."
  if sudo mkdir -p "$BIN_DIR" 2>/dev/null && sudo ln -sf "$ALIGNER" "$LINK" 2>/dev/null; then
    HAVE_GLOBAL=1
    check "Installed command: ${LINK}"
  else
    warn "Could not create the global command."
    warn "No problem - you can still use it from this folder:  ./aligner.sh"
  fi
fi

# Offer guided setup.
echo
printf 'Run guided setup now? [Y/n] '
read -r reply
case "$(printf '%s' "${reply:-y}" | tr '[:upper:]' '[:lower:]')" in
  n|no)
    echo
    if [ "$HAVE_GLOBAL" -eq 1 ]; then
      echo "Done. When you're ready:  session-aligner setup"
    else
      echo "Done. When you're ready:  ./aligner.sh setup"
    fi
    ;;
  *)
    echo
    if [ "$HAVE_GLOBAL" -eq 1 ] && command -v session-aligner >/dev/null 2>&1; then
      session-aligner setup
    else
      "$ALIGNER" setup
    fi
    ;;
esac
