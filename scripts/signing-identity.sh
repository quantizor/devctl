#!/bin/zsh
# Prints the code signing identity local builds should use, or "-" for ad-hoc.
# Usage: scripts/signing-identity.sh
#
# One home for the choice: make app and make dmg both sign, and a disagreement
# between them would produce a DMG whose signature does not match the app inside.
#
# Why this prefers a real identity over ad-hoc: an ad-hoc signature has no Team
# ID, so BTM pins the SMAppService launch constraint to the helper's CDHash,
# which changes on every rebuild. Installing over a previous copy then gets
# devctld SIGKILLed on exec (CODESIGNING / Launch Constraint Violation) until
# BTM invalidates its item on its own schedule, costing a launchd
# ThrottleInterval per attempt. A Developer ID signature pins the Team ID, which
# survives rebuilds, so an upgrade spawns immediately.
#
# Only "Developer ID Application" qualifies. An "Apple Development" certificate
# also carries a Team ID but is not valid for distribution, so picking one up
# here would produce an image that fails on any machine but this one.
#
# Always exits 0 and always prints something: callers embed this in a build and
# a missing keychain is a reason to fall back, not to fail the build.
set -uo pipefail

identities="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' || true)"

if [[ -z "$identities" ]]; then
  echo -
  exit 0
fi

count="$(printf '%s\n' "$identities" | grep -c .)"
if (( count > 1 )); then
  echo "signing-identity: $count Developer ID identities found; using the first." >&2
  echo "signing-identity: pass SIGN_IDENTITY=... to choose another." >&2
  printf '%s\n' "$identities" | sed 's/^/  /' >&2
fi

printf '%s\n' "$identities" | head -1
