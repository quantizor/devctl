---
"devctl": patch
---

A crashed server no longer leaves its workers running. When a supervised server spawned a helper process and then crashed, that helper could survive forever, holding its port and its files while devctl reported the server as gone. The next start would then fail on a port held by a process nothing was tracking.

Two things had to line up, and both are common. A helper started through most process APIs lands in its own process group, so signalling the server's group never reaches it, leaving devctl's record of live descendants as the only way to find it. That record was refreshed when the server started and then not again until its first healthcheck, which for a server declaring no healthcheck is a couple of seconds later. A helper started in between was in no record at all.

Teardown now also sweeps by session, which is the one relationship that survives the server exiting and its helpers being adopted by the system. The record is refreshed throughout startup as well, so the common case is caught before the sweep is needed.
