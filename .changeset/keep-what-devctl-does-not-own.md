---
"devctl": patch
---

`devctl hook install` can no longer erase your harness settings. It merges its session hook into a file it does not own, and it writes that whole file back, so it has to read everything already in it first. When that read failed, for a stray character mid-edit or anything else that stopped the file parsing, it treated the file as empty and wrote it back with only its own hook in it, taking every other hook, permission and setting along with it, then reported a successful install. It now leaves the file alone and says which file it could not read and why.

The port shown for a server is the port it is actually on. When a server rebound to a different port to avoid a collision with a sibling checkout, the menu bar and the statusline still showed the port it had asked for, sending you somewhere nothing was listening, while the session context shown to agents had it right. All three now agree.

A version mismatch between `devctl` and a running daemon is reported rather than skipped. If the opening handshake failed partway, the connection was left half-open and every later request on it went out without the check ever running again.

A timestamp before 1970 no longer comes out in a form devctl cannot read back.
