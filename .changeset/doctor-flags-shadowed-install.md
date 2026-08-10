---
"devctl": patch
---

`devctl doctor` now catches a second devctl copy shadowing your Homebrew install, the failure where `brew upgrade` changes one copy while a bare `devctl` (or the background daemon) keeps running an older one. It reports when a manual `~/.local/bin` install coexists with the Homebrew cask (whichever `~/.local/bin` or brew's bin comes first on your PATH is what actually runs), and when an `/Applications/devctl.app` that Homebrew did not place is still present. Each finding names the exact cleanup command. Like doctor's other environment findings, it only reports, and only fires when a Homebrew install is present, so a plain `make install` is never flagged.
