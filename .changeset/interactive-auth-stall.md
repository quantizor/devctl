---
"devctl": patch
---

A server whose start command waits on an interactive credential prompt (a secrets CLI unlock, a biometric approval) can no longer crash-loop invisibly. When runs repeatedly exit on their own, nonzero, after tens of seconds, without ever passing a healthcheck, status surfaces `blockedOn: "interactive-auth"` with the remedy in human status, `devctl why`, and the session-context block: start the server once in a terminal to surface the prompt, then `devctl ensure`. The classification is a heuristic in devctl's own words and clears the first time a run dies differently or a healthcheck passes.
