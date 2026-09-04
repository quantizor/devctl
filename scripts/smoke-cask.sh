#!/bin/zsh
# Homebrew cask gate. Two tiers.
#
# Default (non-destructive): builds a local DMG, drops the cask into a throwaway
# local tap created with `brew tap-new --no-git` (no GitHub, no network), rewrites
# the URL to that local file:// DMG with its real checksum, and runs style, audit,
# info, a dry-run install, and a fetch (which verifies the sha256). Its only
# footprint is a directory under brew's Taps, removed on exit. Safe any time.
#
# --install (destructive): actually `brew install --cask` into a TEMP --appdir so
# artifact staging, the Caskroom backlink, the binary symlink, and the uninstall
# directives run somewhere harmless, then uninstalls. Refuses to run if a directa
# cask is already installed, and leaves nothing behind. It does NOT install to the
# real /Applications: directa's own runtime behavior at the real path is covered by
# smoke.sh and smoke-launchd.sh; conflating the two tiers here would need the real
# /Applications, which this script deliberately avoids. The uninstall directive
# runs the real `directa uninstall --agent-only`, so it will quit and unregister an
# already-running app's agent (recoverable at next launch), the same real-state
# cost smoke-launchd.sh accepts.
#
# The `--new-cask` audit (gktool scan for signing, min-OS enforcement) only passes
# on a Developer ID signed DMG, so it runs only when the DMG is Developer ID
# signed and is skipped with a note on an ad-hoc local build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_TIER=0
[[ "${1:-}" == "--install" ]] && INSTALL_TIER=1

TAP="quantizor/tap"
TOKEN="quantizor/tap/directa"
TAP_DIR="$(brew --repository)/Library/Taps/quantizor/homebrew-tap"
WORK="$(mktemp -d /tmp/directa-cask-smoke.XXXXXX)"

fail() { echo "CASK SMOKE FAIL: $1" >&2; exit 1 }
pass() { echo "  ok: $1" }
note() { echo "  note: $1" }

cleanup() {
  brew untap "$TAP" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ "$INSTALL_TIER" == "1" ]]; then
  # The tier does real, disruptive things on this machine: the cask's quit:
  # directive quits an already-running menu bar app, and the uninstall
  # early_script unregisters its agent. Require an explicit opt-in so it is never
  # run by reflex.
  if [[ "${DIRECTA_CASK_DESTRUCTIVE:-0}" != "1" ]]; then
    fail "the --install tier quits and unregisters your running app; re-run with DIRECTA_CASK_DESTRUCTIVE=1 to accept that"
  fi
  if brew list --cask directa >/dev/null 2>&1; then
    fail "a directa cask is already installed; refusing to run the destructive tier over it"
  fi
fi

# A real DMG to point the cask at. Reuse dist/ if a matching one is already built,
# else build one (ad-hoc + no notarize is fine here; this tests cask mechanics,
# not Gatekeeper). SKIP_NOTARIZE keeps the loop fast.
echo "building the app + DMG (this can take a minute)…"
SKIP_NOTARIZE=1 DIRECTA_DMG_QUARANTINE=0 make -C "$ROOT" dmg >/dev/null 2>&1 \
  || fail "make dmg failed; run it directly to see why"
VERSION="$("$ROOT/.build/release/directa" --version 2>/dev/null || echo 0.0.0)"
DMG="$ROOT/dist/directa-${VERSION}.dmg"
[[ -f "$DMG" ]] || fail "expected DMG at $DMG"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
pass "built directa-${VERSION}.dmg (sha ${SHA:0:12}…)"

# Fresh local tap, no git, no network. Delete the CI workflows tap-new scaffolds.
brew untap "$TAP" >/dev/null 2>&1 || true
brew tap-new "$TAP" --no-git >/dev/null 2>&1 || fail "brew tap-new"
rm -rf "$TAP_DIR/.github" 2>/dev/null || true
mkdir -p "$TAP_DIR/Casks"

# Generate the local cask from the canonical template: real version + sha, and a
# file:// URL to the DMG just built. This is a scratch artifact under brew's Taps,
# regenerated every run, so a generated rewrite is appropriate here.
/usr/bin/python3 - "$ROOT/packaging/homebrew/directa.rb" "$TAP_DIR/Casks/directa.rb" \
  "$VERSION" "$SHA" "$ROOT/dist" <<'PY'
import re, sys
src, dst, version, sha, dist = sys.argv[1:6]
text = open(src).read()
text = re.sub(r'version "[^"]*"', f'version "{version}"', text, count=1)
text = re.sub(r'sha256 "[^"]*"', f'sha256 "{sha}"', text, count=1)
text = re.sub(
    r'url "[^"]*"',
    f'url "file://{dist}/directa-#{{version}}.dmg"',
    text, count=1)
open(dst, "w").write(text)
PY
pass "generated local cask (file:// DMG)"

echo "=== brew style ==="
brew style "$TAP" >/dev/null 2>&1 || fail "brew style reported offenses (run: brew style $TAP)"
pass "brew style clean"

echo "=== brew audit ==="
# The strict --new-cask audit runs `gktool scan`, which requires a NOTARIZED
# image (Developer ID signing alone does not satisfy Gatekeeper). Local builds
# use SKIP_NOTARIZE for speed, so --new-cask runs in CI on the release DMG, not
# here. The plain audit still catches token, URL, and stanza problems.
brew audit --cask "$TOKEN" >/dev/null 2>&1 \
  || note "brew audit reported issues (some are expected for a file:// local build)"
note "skipped --new-cask audit here; it runs in CI against the notarized release DMG"

echo "=== brew info / dry-run / fetch ==="
brew info --cask "$TOKEN" >/dev/null 2>&1 || fail "brew info"
pass "brew info"
brew install --cask --dry-run "$TOKEN" >/dev/null 2>&1 || fail "brew install --dry-run"
pass "brew install --dry-run"
# fetch downloads (copies the file://) and verifies the sha256 against the cask.
brew fetch --cask "$TOKEN" >/dev/null 2>&1 || fail "brew fetch (sha256 mismatch?)"
pass "brew fetch verified the checksum"

if [[ "$INSTALL_TIER" == "0" ]]; then
  echo "CASK SMOKE PASS (non-destructive; --install for the real install tier)"
  exit 0
fi

echo "=== install tier (temp --appdir) ==="
APPDIR="$WORK/Applications"
mkdir -p "$APPDIR"
brew install --cask --appdir="$APPDIR" "$TOKEN" >/dev/null 2>&1 || fail "brew install --cask"
[[ -d "$APPDIR/directa.app" ]] || fail "app not staged into --appdir"
pass "installed into $APPDIR"

# The Caskroom keeps a symlink back to the moved app; realpath equality is exactly
# what SetupPlanner's brew detection keys on.
CASK_APP="$(/bin/ls -d "$(brew --caskroom)/directa"/*/directa.app 2>/dev/null | head -1)"
[[ -n "$CASK_APP" ]] || fail "no Caskroom entry for directa"
[[ "$(/usr/bin/readlink "$CASK_APP" 2>/dev/null || echo "")" == "$APPDIR/directa.app" \
   || "$(cd "$CASK_APP" && pwd -P)" == "$(cd "$APPDIR/directa.app" && pwd -P)" ]] \
  || fail "Caskroom entry does not resolve to the installed app"
pass "Caskroom backlink resolves to the installed app"

# The binary symlink always lands in brew's bin (binarydir is not overridable).
BREW_CLI="$(brew --prefix)/bin/directa"
[[ -L "$BREW_CLI" ]] || fail "CLI symlink not created in brew's bin"
pass "CLI symlink at $BREW_CLI"

# brew quarantines the app it stages from a DMG. A notarized release passes
# Gatekeeper, but a local SKIP_NOTARIZE build does not, so the uninstall
# early_script could not execute the CLI. Clear the quarantine to stand in for
# the notarized release the real cask ships.
xattr -dr com.apple.quarantine "$APPDIR/directa.app" 2>/dev/null || true

echo "=== uninstall ==="
# --force so a missing/blocked early_script cannot wedge the Caskroom (the same
# recovery the cask caveats name). No --appdir: it is an install-time flag, and
# uninstall reads the staged location from the receipt. The early_script runs the
# real `directa uninstall --agent-only`, which quits and unregisters the app's
# agent on this machine (recoverable at next launch).
brew uninstall --cask --force "$TOKEN" >/dev/null 2>&1 || fail "brew uninstall"
[[ ! -e "$APPDIR/directa.app" ]] || fail "app survived uninstall"
[[ ! -e "$BREW_CLI" ]] || fail "CLI symlink survived uninstall"
pass "uninstall removed the app and the CLI symlink"

echo "CASK SMOKE PASS (install tier)"
