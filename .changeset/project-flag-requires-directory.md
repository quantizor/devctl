---
"devctl": patch
---

`--project` now refuses anything that is not an existing directory (exit 2, `usage`). Passing a project's NAME instead of its path used to resolve to a nonexistent relative directory and answer an empty scoped view: `devctl down --project myproj` reported success against a phantom project while the real server kept running.
