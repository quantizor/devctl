#!/usr/bin/env node
// Fails on a changeset Changesets itself cannot parse. One with frontmatter
// like `"minor"` (no package name) blocked every release for weeks: it merged
// clean because the CI gate ignores markdown, and only the Release workflow on
// main ever read it. This checks the shape directly, so it needs no git history
// and no comparison against a base branch.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const DIR = ".changeset";
const BUMPS = new Set(["major", "minor", "patch"]);
const pkg = JSON.parse(readFileSync("package.json", "utf8")).name;

const problems = [];
for (const file of readdirSync(DIR)) {
  if (!file.endsWith(".md") || file === "README.md") continue;
  const path = join(DIR, file);
  const lines = readFileSync(path, "utf8").split("\n");
  if (lines[0].trim() !== "---") {
    problems.push(`${path}: must open with a --- frontmatter fence`);
    continue;
  }
  const end = lines.indexOf("---", 1);
  if (end === -1) {
    problems.push(`${path}: frontmatter fence is never closed`);
    continue;
  }
  const entries = lines.slice(1, end).filter((line) => line.trim() !== "");
  if (entries.length === 0) {
    problems.push(`${path}: frontmatter names no package`);
    continue;
  }
  for (const entry of entries) {
    const separator = entry.indexOf(":");
    if (separator === -1) {
      problems.push(
        `${path}: frontmatter line ${JSON.stringify(entry.trim())} is not "<package>": <bump>`,
      );
      continue;
    }
    const name = entry.slice(0, separator).trim().replace(/^["']|["']$/g, "");
    const bump = entry.slice(separator + 1).trim();
    if (name !== pkg) {
      problems.push(`${path}: names package ${JSON.stringify(name)}, expected ${JSON.stringify(pkg)}`);
    }
    if (!BUMPS.has(bump)) {
      problems.push(`${path}: bump ${JSON.stringify(bump)} is not major, minor, or patch`);
    }
  }
}

if (problems.length > 0) {
  console.error("Invalid changeset frontmatter:\n" + problems.map((p) => `  ${p}`).join("\n"));
  console.error(`\nExpected each file to open with:\n---\n"${pkg}": patch\n---`);
  process.exit(1);
}
console.log(`changesets ok (${readdirSync(DIR).filter((f) => f.endsWith(".md") && f !== "README.md").length} checked)`);
