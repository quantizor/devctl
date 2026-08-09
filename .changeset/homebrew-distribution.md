---
"devctl": minor
---

devctl installs from Homebrew: `brew install --cask quantizor/tap/devctl`. `brew upgrade` keeps it current, and when a newer version ships the menu bar popover shows a quiet notice with a one-click Upgrade button that runs the upgrade in Terminal (a Homebrew install) or links to the release notes (a direct download). A direct DMG download still works exactly as before.

A new Settings window, opened from the gear at the bottom of the popover, is the way back to anything you skipped at first run: install or remove the Claude Code and Cursor session hooks per harness, toggle Start at login, and turn the update check on or off. devctl still only edits a harness's settings when you click; it never changes them on its own.

Removing devctl is now a single command. `devctl uninstall` unregisters the background agent, removes the agent hooks, and removes the CLI, keeping your data unless you pass `--purge`; running servers keep going. The Settings window offers the same as a button. `devctl doctor` reports a harness whose hook is missing or points at a path that no longer exists, and names the command to fix it.
