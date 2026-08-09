---
"devctl": patch
---

The installer no longer tells you to fix a PATH that is already fine. It asked the app's own process for its PATH, and the app is launched by Finder, so that was launchd's rather than your shell's: it can never contain `~/.local/bin`, so the warning appeared for everyone whatever their shell actually had.

Asking a login shell was not enough either. `zsh -l` without `-i` runs `.zshenv`, `.zprofile` and `.zlogin` and skips `.zshrc`, which is where most tools put themselves. On the machine this was found, that meant devctl handed every server it started a PATH missing `~/.local/bin`, pnpm, conda and gcloud, so a server script calling `devctl` could not find it. Both the warning and the PATH your servers inherit now reflect what your shell really has.

Reading that PATH means running your shell profile, which devctl does not control, so it now gives up after a while and falls back rather than waiting forever. A profile that waits on the network or on a terminal that is not there used to hang the app at launch with nothing on screen. `DEVCTL_RESOLVING_ENVIRONMENT` is set while it runs, so a profile can skip whatever needs a real session.
