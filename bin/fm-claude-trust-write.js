#!/usr/bin/env node
// Atomic Claude workspace-trust store writer used by fm-claude-trust.sh.
// This stays in a file rather than a shell heredoc: the program is larger than
// macOS's pipe buffer, so Bash can block writing the heredoc before Node starts.

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const [store, mode, target, project, trustFlag, importFlagsJson] = process.argv.slice(2);
const importFlags = JSON.parse(importFlagsJson);
const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};
const fingerprint = (buf) =>
  buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex");
const setFlags = (projects, key, flags) => {
  let entry = projects[key];
  if (entry === undefined || entry === null || typeof entry !== "object" || Array.isArray(entry)) {
    entry = {};
  }
  for (const flag of flags) entry[flag] = true;
  projects[key] = entry;
};
const flagsLanded = (projects, key, flags) =>
  flags.every((flag) => projects?.[key]?.[flag] === true);

// The project entry is the launching user's OWN interactive config, not a
// throwaway worktree, so a spawn must never silently reverse a decision the
// human already recorded there. hasClaudeMdExternalIncludesApproved===false
// together with hasClaudeMdExternalIncludesWarningShown===true is exactly that
// decision (the dialog's "No, disable" answer writes that pair; Claude Code's
// default project entry carries Approved===false with WarningShown===false,
// which means never asked, not declined); flipping it to true would grant every
// future interactive session in that checkout silent external-file inclusion
// the human declined. Refuse the whole registration instead of overriding it.
const declinedExternalImports = (projects, key) =>
  projects?.[key]?.hasClaudeMdExternalIncludesApproved === false &&
  projects?.[key]?.hasClaudeMdExternalIncludesWarningShown === true;
// True only on an explicit prior "Yes, allow" answer - the sole state this
// script may treat as standing consent to refresh. Absent, or any other value,
// is NOT consent.
const approvedExternalImports = (projects, key) =>
  projects?.[key]?.hasClaudeMdExternalIncludesApproved === true;

const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  let root = {};
  if (original !== null) {
    const raw = original.toString("utf8");
    if (raw.trim() !== "") {
      root = JSON.parse(raw);
      if (root === null || typeof root !== "object" || Array.isArray(root)) {
        throw new Error(`${store} is not a JSON object`);
      }
    }
  }
  if (root.projects === undefined) root.projects = {};
  const projects = root.projects;
  if (projects === null || typeof projects !== "object" || Array.isArray(projects)) {
    throw new Error(`${store} has a non-object "projects" value`);
  }
  let keys;
  if (mode === "worktree") {
    if (declinedExternalImports(projects, project)) {
      throw new Error(
        `project entry for ${project} in ${store} already declined external CLAUDE.md imports; refusing to override that consent`,
      );
    }
    const carryImportConsent = approvedExternalImports(projects, project);
    const targetFlags = carryImportConsent ? [trustFlag, ...importFlags] : [trustFlag];
    const projectFlags = carryImportConsent ? [trustFlag, ...importFlags] : [trustFlag];
    setFlags(projects, target, targetFlags);
    setFlags(projects, project, projectFlags);
    keys = [[target, targetFlags], [project, projectFlags]];
  } else {
    setFlags(projects, target, [trustFlag]);
    keys = [[target, [trustFlag]]];
  }
  // Unpredictable name plus an exclusive create: the config directory may be
  // writable by another local account, and a predictable path could be
  // pre-created there as a symlink that a plain write would follow into some
  // other file this user owns. "wx" refuses an existing path outright.
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.claude.json.fm-trust.${unique}`);
  // Two-space pretty-printed, because that is the format Claude Code itself
  // writes. Compact would reformat the operator's whole config on every spawn.
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  const landed = keys.every(([key, flags]) => flagsLanded(back.projects, key, flags));
  return landed ? "recorded" : "dropped";
};

try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(
  `error: ${store} did not retain trust for ${target}${project ? ` and ${project}` : ""} after 3 attempts`,
);
process.exit(1);
