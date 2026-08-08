---
"devctl": minor
---

`devctl restart <name>` is a real command. Agents were writing `devctl stop X && devctl ensure X` by hand, and several assumed the verb already existed. That pair has two problems this fixes: another session's `ensure` can land between the two commands, and a refusal (a held resource, a paused server, a config that no longer parses) arrives only after the server is already down, leaving it down. A restart now refuses before it stops anything, and keeps the server's resume-on-boot intent, which a manual stop clears.

A server can also list the config files it reads at boot but does not reload on its own, and devctl restarts it when one changes. Without that, a long-lived supervised server keeps running the old config, so a correct fix looks like it did nothing and a test harness keeps checking stale behavior. A server whose framework already reloads its own config declares nothing and behaves exactly as before. A config a server writes during its own startup will not bounce it, one save touching several files is a single restart, and a server that rewrites its own watched file has its watch suspended with a log line naming the culprit rather than restarting forever.
