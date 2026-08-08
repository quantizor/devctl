---
"devctl": patch
---

A server that loses its port to another supervised server now names that server the way a person reads it. The message carried devctl's internal server id, so it read `managed server '/Users/me/code/proj::web'`, and it now says `'web' in /Users/me/code/proj` with a `devctl stop` command that can be run as printed.
