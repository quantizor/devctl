---
"devctl": patch
---

A repo's devservers.json can no longer reach outside what it describes. A server name became a path component of the log directory verbatim, so a name containing `../` made the daemon create directories elsewhere on the machine and write that server's raw output into them. Names are now flattened to a single component, and two names that flatten alike keep separate homes.

Session context is devctl's own words again. A server name, url, or head went into the fenced block unescaped, and a JSON key legally holds a newline, so a pulled branch could close the fence and continue as though the harness were speaking. Those values are now kept to one line and the fence is left intact. The port-conflict warning also carried the squatting process's own command line, chosen by that process; it now says which port and what state, which is the part devctl knows.

A port a TCP port cannot hold took the daemon down. `config check` accepted `"port": 70000`, and the first probe against it crashed devctld, which under launchd came straight back, re-read the same config, and crashed again. Out-of-range ports, including a `portSpan` that runs past the end, are now config errors, and the probe answers that nothing is listening rather than failing.

Logs no longer repeat themselves. A server writing while devctl was reading its output had the overlap ingested twice, so lines appeared in duplicate and error tallies counted them twice.

Two crashes in the same moment now raise two notifications. The menu bar tracked how far it had read using a value it advanced mid-pass, so when several servers went down together, only the first was announced.
