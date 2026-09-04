// Close-classification for the OpenCode watch-arm plugin.
// Lives here rather than in the plugin module because OpenCode treats every
// export of a plugin file as a plugin factory; lib/ is not scanned.
//
// An empty watcher cycle and another healthy watcher are attach/idle: the
// plugin re-arms through its bounded silent retry and on the next session.idle
// without a model turn. Actionable wake lines still deliver. Real FAILED lines
// (no live watcher, persistence errors, a watcher that exited nonzero) still
// surface as failure.

export const ACTIONABLE_RE = /^(signal:|stale:|check:|heartbeat($|:))/;
export const HEALTHY_RE = /^watcher: healthy\b/;
export const OWNED_RE = /^watcher: (?:started|attached)\b/;
export const FAILED_RE = /^watcher: FAILED/;
const EMPTY_CYCLE_FAILED_RE = /^watcher: FAILED - cycle ended without an actionable reason/;

function firstMatchingLine(text, pattern) {
  return `${text}`.split(/\r?\n/).find((line) => pattern.test(line));
}

export function classifyArmClose(stdout, stderr, code, signal) {
  const combined = `${stdout}\n${stderr}`;
  const reason = firstMatchingLine(combined, ACTIONABLE_RE);
  if (reason) return { kind: "actionable", message: reason };

  const healthy = firstMatchingLine(combined, HEALTHY_RE);
  if (healthy) return { kind: "idle", message: healthy };

  const emptyFailed = firstMatchingLine(combined, EMPTY_CYCLE_FAILED_RE);
  if (emptyFailed) return { kind: "idle", message: emptyFailed };

  const failed = firstMatchingLine(combined, FAILED_RE);
  if (failed) return { kind: "failure", message: failed };

  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child ended from ${signal}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }

  const owned = firstMatchingLine(combined, OWNED_RE);
  if (owned) return { kind: "idle", message: owned };

  return {
    kind: "idle",
    message: "watcher: idle - OpenCode arm cycle ended without an actionable reason",
  };
}
