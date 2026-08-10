---
"devctl": patch
---

The Homebrew install now tells you what to do next. A fresh `brew install --cask quantizor/tap/devctl` used to finish with a post-install message that mentioned only uninstall, so you were left with an app that had not started and no hint that the background agent only comes up once you open the app for the first time. The message now names the menu bar app and its agent, the one step to start it (`open -a devctl`), the one-time macOS confirmation you will see on that first launch, and how to enable your coding-agent session hooks.
