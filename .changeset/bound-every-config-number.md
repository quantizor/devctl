---
"devctl": patch
---

A number in devservers.json can no longer take the daemon down. Out-of-range ports were already caught, but the values beside them were not: a `ports` entry's `offset`, a `portSpan` that overflows when added to its port, and a healthcheck's `healthyAfter`, `intervalMs`, `timeoutMs` and `unhealthyAfter` all reached code that assumed they fit. `devctl config check` now reports each of them by name with the range it expected, and refuses the start rather than letting it crash.

The `offset` case was the one nothing could see. It was checked for being too small but never for being too large, so `config check` called the file clean and reported no errors at all, and the failure only arrived later as an unrelated-looking `daemon-unreachable`.

One bad project no longer stops the others. Reading status across every project validated each one's config along the way, so a single unusable number anywhere on the machine took down the daemon supervising all of them, and the menu bar's polling brought it straight back to do it again.

A damaged state file is no longer fatal either. A process id too large to be one was read back from disk and used directly, which crashed the daemon on startup, and starting again re-read the same file. Such a value is now treated the way an exited process already was.

`devctl lock` no longer reports success while protecting nothing. When a project's config could not be read, the lock found no servers declaring the resource, paused none of them, and said it had taken the hold, so the guarded command ran against a live server still holding the resource open. It now refuses.
