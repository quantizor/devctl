#!/usr/bin/env node
/** Keep DevCtlVersion.version and package-lock.json root version in lockstep
    with package.json after `changeset version`. GitHub releases use
    package.json; the CLI/app report the Swift constant. */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;
if (typeof version !== "string" || !/^\d+\.\d+\.\d+/.test(version)) {
  console.error(`sync-version: refusing unexpected package.json version: ${version}`);
  process.exit(1);
}

const swiftPath = join(root, "Sources/DevCtlKit/Model/Models.swift");
const before = readFileSync(swiftPath, "utf8");
const after = before.replace(
  /public static let version = "[^"]+"/,
  `public static let version = "${version}"`,
);
if (after === before) {
  if (!before.includes(`public static let version = "${version}"`)) {
    console.error("sync-version: DevCtlVersion.version declaration not found in Models.swift");
    process.exit(1);
  }
  console.log(`sync-version: Models.swift already at ${version}`);
} else {
  writeFileSync(swiftPath, after);
  console.log(`sync-version: Models.swift -> ${version}`);
}

const lockPath = join(root, "package-lock.json");
const lock = JSON.parse(readFileSync(lockPath, "utf8"));
let lockChanged = false;
if (lock.version !== version) {
  lock.version = version;
  lockChanged = true;
}
if (lock.packages?.[""] && lock.packages[""].version !== version) {
  lock.packages[""].version = version;
  lockChanged = true;
}
if (lockChanged) {
  writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
  console.log(`sync-version: package-lock.json -> ${version}`);
} else {
  console.log(`sync-version: package-lock.json already at ${version}`);
}
