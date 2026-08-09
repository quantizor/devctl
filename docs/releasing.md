# Releasing devctl

How the app bundle, DMG, signing, notarization, the GitHub release workflow, and the Homebrew cask bump fit together. Agents never bump versions or publish; version bumps and tagging live in CONTRIBUTING.md.

## make app

`make app` assembles the fat `devctl.app` via `scripts/make-app-bundle.sh`:

- CLI in `Contents/Resources`.
- Signed `Helpers/devctld` plus a `Contents/Library/LaunchAgents` BundleProgram plist for SMAppService.
- `AppIcon.icns`.
- Declares the `devctl://` URL scheme.
- Writes both `CFBundleShortVersionString` and `CFBundleVersion`.

## Signing

Signing identity comes from `scripts/signing-identity.sh`:

- A Developer ID certificate when the keychain has one, else ad-hoc with a warning.
- `SIGN_IDENTITY=...` overrides, including `SIGN_IDENTITY=-` to force ad-hoc.
- `DEVCTL_REQUIRE_SIGNING=1` (set by the release build) fails rather than falling back to ad-hoc. This is enforced in `make-app-bundle.sh` because the Makefile's `$(shell ...)` swallows `signing-identity.sh`'s exit code.

Ad-hoc signing has consequences for launchd spawn under the BTM constraint; see docs/macos-lifecycle.md.

## make dmg

`make dmg` builds a UDZO image via `scripts/make-dmg.sh`:

- Holds the app alone (no `/Applications` symlink: the app installs itself after an in-app confirm).
- Background rendered by `scripts/make-dmg-background.swift` that says to double-click.
- Finder window layout needs a GUI session and a volume name that is not already mounted. On a headless runner that pass is skipped and the image still ships.

Two kinds of image:

- TEST DMG: signed with whatever identity (ad-hoc when none), not notarized. This is what a contributor gets, produced whenever notarytool credentials are absent.
- REAL DMG: notarized, stapled, `com.apple.quarantine`-stamped. Built where the credentials live (the `devctl-notary` keychain profile locally, App Store Connect API key env in CI).

## Notarization

- `make dmg` notarizes automatically when credentials are reachable.
- `DEVCTL_NOTARIZE=1` (implied by `DEVCTL_REQUIRE_SIGNING=1`) demands the real path and fails if credentials are missing.
- `SKIP_NOTARIZE=1` forces the fast loop.
- `DEVCTL_DMG_QUARANTINE=0` drops the quarantine stamp.
- `scripts/notarize.sh` holds the notarytool + staple step and still runs standalone.

## Release DMG workflow (GitHub Actions)

`Release DMG` publishes only on a `release` event or a dispatch from `main` (the ref `Release` uses). Dispatched from any other branch it builds, signs, notarizes, and verifies, then returns the image as a run artifact instead of uploading, so the release path is testable without clobbering a published asset:

```sh
gh workflow run "Release DMG" --ref <branch> [-f tag=vX.Y.Z]
```

After uploading, it dispatches `Bump Homebrew cask`, which injects the release's version + sha256 into `packaging/homebrew/devctl.rb` (the one home for the cask's structure) and pushes to the `quantizor/homebrew-tap` repo.

## Homebrew cask gate (scripts/smoke-cask.sh)

- Default tier is non-destructive: a throwaway local tap via `brew tap-new --no-git`, the cask rewritten to a local `file://` DMG with its real checksum, then style/audit/info/dry-run/fetch, then untap.
- `DEVCTL_CASK_DESTRUCTIVE=1 scripts/smoke-cask.sh --install` runs a real `brew install --cask` into a temp `--appdir` and asserts the Caskroom backlink resolves to the app and the CLI symlink lands in brew's bin. Its uninstall runs the real `devctl uninstall --agent-only`, so it quits and unregisters a running app's agent (recoverable).
- The strict `--new-cask` audit needs a notarized image and runs in CI, not here.

## make install

`make install`: CLI + daemon to `~/.local/bin`, app to `/Applications`, then `daemon install`.
