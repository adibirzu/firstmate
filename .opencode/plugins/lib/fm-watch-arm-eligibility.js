import { spawn } from "node:child_process";
import { lstatSync, readFileSync, statSync } from "node:fs";

const SECONDMATE_MARKER = ".fm-secondmate-home";

// Mirror bin/fm-primary-scope-lib.sh::fm_root_is_secondmate_home: the marker
// must be a regular, non-symlink file whose first line is a non-empty id made
// only of [A-Za-z0-9._-]. A stray or empty marker must never force-include a
// linked worktree, exactly as the shared shell owner requires.
function rootIsMarkedSecondmateHome(root) {
  const marker = `${root}/${SECONDMATE_MARKER}`;
  let stat;
  try {
    stat = lstatSync(marker);
  } catch {
    return false;
  }
  if (stat.isSymbolicLink() || !stat.isFile()) return false;
  let contents;
  try {
    contents = readFileSync(marker, "utf8");
  } catch {
    return false;
  }
  // `IFS= read -r id < "$marker"` reports failure at EOF when the first line
  // carries no newline, so the shell owner rejects an unterminated marker.
  // Reject it here too: otherwise a home every shell hook scopes out as
  // non-primary would still arm a watcher from OpenCode.
  const lineEnd = contents.indexOf("\n");
  if (lineEnd < 0) return false;
  // The shell owner strips under LC_ALL=C, so only ASCII blanks go; a wider
  // Unicode class would normalise an id the shell keeps and rejects.
  const id = contents.slice(0, lineEnd).replace(/[ \t\n\v\f\r]+/g, "");
  if (!id) return false;
  return /^[A-Za-z0-9._-]+$/.test(id);
}

// Empty on any failure, so a root git cannot resolve is never mistaken for one
// whose git-dir and git-common-dir agree. Asynchronous like the plugin's own
// process helper: this runs on every session.idle inside the OpenCode TUI
// process, which must never block on a git spawn.
function gitRevParse(root, flag) {
  return new Promise((resolve) => {
    let proc;
    try {
      proc = spawn("git", ["-C", root, "rev-parse", flag], { stdio: ["ignore", "pipe", "pipe"] });
    } catch {
      resolve("");
      return;
    }
    let stdout = "";
    proc.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    proc.stderr.on("data", () => {});
    proc.on("error", () => resolve(""));
    proc.on("close", (code) => resolve(code === 0 ? stdout.trim() : ""));
  });
}

// Mirror bin/fm-primary-scope-lib.sh's `[ -f ]` / `[ -d ]` shape tests, which
// require a regular file and a directory respectively (following symlinks) and
// not merely an existing path. A bare existence test would scope IN a root the
// shell owner scopes OUT - e.g. one carrying a plain file named `bin` - and the
// plugin would arm a watcher every shell hook treats as non-primary.
function isType(path, kind) {
  let stat;
  try {
    stat = statSync(path);
  } catch {
    return false;
  }
  return kind === "dir" ? stat.isDirectory() : stat.isFile();
}

// A root is arm-eligible when it is a genuine firstmate primary home: the main
// checkout OR a marked secondmate home (which runs its own primary session and
// must arm its own supervision even when treehouse leases it as a linked
// worktree). Mirrors bin/fm-primary-scope-lib.sh::fm_primary_scope_matches: a
// valid secondmate marker force-includes; otherwise only a plain checkout
// (git-dir == git-common-dir) qualifies, so crewmate/scout task worktrees stay
// silent. Lives here rather than in the plugin because OpenCode treats every
// export of a plugin module as a plugin factory; lib/ is not scanned.
export async function isArmEligibleRoot(root) {
  if (!root) return false;
  if (!isType(`${root}/AGENTS.md`, "file") || !isType(`${root}/bin`, "dir")) return false;
  if (rootIsMarkedSecondmateHome(root)) return true;
  const gitDir = await gitRevParse(root, "--git-dir");
  const commonDir = await gitRevParse(root, "--git-common-dir");
  if (!gitDir || !commonDir) return false;
  return gitDir === commonDir;
}
