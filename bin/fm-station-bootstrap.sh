#!/usr/bin/env bash
# Take a bare Linux SSH target from nothing to fm-remote-doctor.sh green.
#
# Usage:
#   fm-station-bootstrap.sh <ssh-alias> [--code-root <abs-path>] [--fork <url>] [--dry-run]
#
# The alias must already land in a POSIX shell over non-interactive SSH.
# This script never creates the SSH route itself: that stays a per-host
# prerequisite (a WSL target needs its own sshd route, never a PowerShell
# landing). It never seeds a secondmate home: seeding stays a separate later
# step owned by secondmate-provisioning and gated on a clean doctor pass.
#
# Steps, each idempotent (probed first, skipped cleanly when satisfied):
#   1. preflight the transport and refuse a non-POSIX (PowerShell) landing.
#   2. install missing OS packages for git, curl, jq, python3, and node/npm.
#   3. clone the fork to the absolute code root (default $HOME/firstmate).
#   4. link ~/.local/bin/fm-remote-entrypoint.sh at the code root and prove it
#      resolves on a fresh non-interactive PATH.
#   5. install herdr per herdr.dev, tasks-axi and treehouse per their
#      documented installers, and opencode as the verified harness lane when
#      no verified harness CLI resolves yet.
#   6. install llm-router-axi and usage-axi from their GitHub clones, write
#      the router policy mirroring this machine's shape with jev shadow on
#      when the remote's policy differs, skipped cleanly when it already
#      matches, and prove the router degrades to source fallback with no key
#      present.
#   7. run fm-remote-doctor.sh --fix then read-only, and print both outputs.
#
# Reporting is plain readable step output for the operator, not wake-event
# vocabulary. A foreign file at the entrypoint path, an existing non-repo
# directory at the code root, and a missing package privilege are reported as
# operator steps and counted as remaining gaps, never worked around.
#
# Exit 0 when the final read-only doctor passes. Exit 1 when steps ran but
# operator gaps remain or the doctor still fails. Exit 2 on usage or on a
# transport failure before any step could run. --dry-run probes read-only,
# prints what each step would change, runs only the read-only doctor, and
# always exits 0.
#
# Environment knobs: FM_SSH_BIN (default ssh, a test seam), FM_SSH_CONNECT_TIMEOUT.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"

SSH_BIN=${FM_SSH_BIN:-ssh}
CONNECT_TIMEOUT=${FM_SSH_CONNECT_TIMEOUT:-15}
HARNESS_TOOLS="claude codex opencode pi pi-signed grok kimi"
HERDR_INSTALL_URL="https://herdr.dev/install.sh"
TREEHOUSE_INSTALL_URL="https://kunchenguid.github.io/treehouse/install.sh"
OPENCODE_INSTALL_URL="https://opencode.ai/install"
ROUTER_REPO="https://github.com/adibirzu/llm-router-axi"
USAGE_REPO="https://github.com/adibirzu/usage-axi"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
step() { printf '\n== %s ==\n' "$1"; }
say() { printf '%s\n' "$1"; }

ALIAS=
CODE_ROOT=
FORK=
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --code-root) [ "$#" -ge 2 ] || usage; CODE_ROOT=$2; shift 2 ;;
    --fork) [ "$#" -ge 2 ] || usage; FORK=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    -*) usage ;;
    *) [ -z "$ALIAS" ] || usage; ALIAS=$1; shift ;;
  esac
done
[ -n "$ALIAS" ] || usage
[ "$#" -eq 0 ] || usage
case "$ALIAS" in ''|-*|*[!A-Za-z0-9._-]*) die "SSH alias must be a safe config name: $ALIAS" 2 ;; esac

if [ -n "$CODE_ROOT" ]; then
  case "$CODE_ROOT" in /*) ;; *) die "--code-root must be absolute: $CODE_ROOT" 2 ;; esac
  case "$CODE_ROOT" in *$'\n'*|*$'\r'*|*$'\t'*|*"'"*) die "--code-root contains unsafe characters" 2 ;; esac
  case "/$CODE_ROOT/" in */../*|*/./*) die "--code-root contains traversal components" 2 ;; esac
  case "$CODE_ROOT" in *'//'*|*'..'*) die "--code-root contains an empty or dot-dot component" 2 ;; esac
fi
if [ -z "$FORK" ]; then
  FORK=$(git -C "$FM_ROOT" remote get-url origin 2>/dev/null || true)
  [ -n "$FORK" ] || die "cannot read this checkout's origin URL; pass --fork <url>" 2
fi
fm_project_origin_safe "$FORK" || die "fork is not an accepted clone URL: $FORK" 2

# Single-quote a value for safe embedding in a remote sh command string.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

SSH_BASE=("$SSH_BIN" -o BatchMode=yes -o "ConnectTimeout=$CONNECT_TIMEOUT"
  -o ForwardAgent=no -o ClearAllForwardings=yes -o 'SendEnv=-*')

GAPS=0
CHANGES=0
PENDING=0
gap() { printf 'OPERATOR NEEDED: %s\n' "$1"; GAPS=$((GAPS + 1)); }
changed() { printf 'INSTALLED: %s\n' "$1"; CHANGES=$((CHANGES + 1)); }
skipped() { printf 'OK (already present): %s\n' "$1"; }
would() { printf 'WOULD CHANGE: %s\n' "$1"; PENDING=$((PENDING + 1)); }

# probe runs a read-only remote command and prints its stdout; exit status is
# the remote status. run executes a mutating remote command, or prints what it
# would do under --dry-run (status 0, empty output).
probe() { "${SSH_BASE[@]}" -- "$ALIAS" "$1" 2>&1; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'would run on %s: %s\n' "$ALIAS" "$1"
    return 0
  fi
  "${SSH_BASE[@]}" -- "$ALIAS" "$1" 2>&1
}

step "preflight: transport and POSIX shell on $ALIAS"
# shellcheck disable=SC2016 # $HOME expands on the target host, not here.
PREFLIGHT=$(probe 'printf "POSIX_OK\n"; command -v uname >/dev/null 2>&1 && uname -s; printf "HOME=%s\n" "$HOME"') \
  || die "SSH to $ALIAS failed; fix the alias and key first, then rerun (tried: $SSH_BIN)" 1
case "$PREFLIGHT" in
  *POSIX_OK*) ;;
  *) say "$PREFLIGHT"; gap "SSH lands in Windows PowerShell, not a POSIX shell. Create a Linux sshd route first (for WSL: install openssh-server in the target distro and expose it, e.g. a portproxy plus a Host alias that lands in bash), then rerun this script against that alias."; ;;
esac
REMOTE_HOME=$(printf '%s\n' "$PREFLIGHT" | sed -n 's/^HOME=//p' | head -n 1)
case "$REMOTE_HOME" in /*) say "remote HOME: $REMOTE_HOME" ;; *) die "remote HOME is unreadable: ${REMOTE_HOME:-<empty>}" 1 ;; esac
if [ -z "$CODE_ROOT" ]; then
  CODE_ROOT="$REMOTE_HOME/firstmate"
fi
say "code root: $CODE_ROOT"
say "fork: $FORK"
[ "$DRY_RUN" -eq 0 ] || say "dry run: probing only, changing nothing"

step "OS packages: git curl jq python3 node npm"
# shellcheck disable=SC2016 # $t and $missing expand on the target host, not here.
NEED_PKGS=$(probe 'missing=""; for t in git curl jq python3 node npm; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done; printf "%s" "$missing"') \
  || die "package probe failed on $ALIAS" 1
if [ -z "$NEED_PKGS" ]; then
  skipped "git curl jq python3 node npm all resolve"
else
  say "missing on host:$NEED_PKGS"
  SUDO=""
  if [ "$(probe 'id -u')" = 0 ]; then
    SUDO=""
  elif probe 'sudo -n true' >/dev/null 2>&1; then
    SUDO="sudo -n"
  fi
  PM=$(probe 'if command -v apt-get >/dev/null 2>&1; then printf apt; elif command -v dnf >/dev/null 2>&1; then printf dnf; elif command -v apk >/dev/null 2>&1; then printf apk; fi') || PM=""
  if [ -z "$SUDO" ] && [ "$(probe 'id -u')" != 0 ]; then
    gap "no passwordless sudo on $ALIAS, so packages cannot be installed non-interactively. On the host run: <package-manager> install git curl jq python3 nodejs npm (or grant NOPASSWD sudo), then rerun."
  elif [ -z "$PM" ]; then
    gap "no apt-get, dnf, or apk on $ALIAS. Install git curl jq python3 nodejs npm with that host's package manager, then rerun."
  elif [ "$DRY_RUN" -eq 1 ]; then
    would "install$NEED_PKGS via $PM"
  else
    case "$PM" in
      apt) INSTALL_CMD="$SUDO apt-get update && $SUDO apt-get install -y git curl jq python3 nodejs npm" ;;
      dnf) INSTALL_CMD="$SUDO dnf install -y git curl jq python3 nodejs npm" ;;
      apk) INSTALL_CMD="$SUDO apk add git curl jq python3 nodejs npm" ;;
    esac
    if run "$INSTALL_CMD" >/dev/null 2>&1; then
      changed "installed$NEED_PKGS via $PM"
    else
      gap "package install via $PM failed. On the host run the install by hand, then rerun."
    fi
  fi
fi

step "firstmate clone at $CODE_ROOT"
ROOT_Q=$(sq "$CODE_ROOT")
FORK_Q=$(sq "$FORK")
CLONE_STATE=$(probe "if git -C $ROOT_Q rev-parse --is-inside-work-tree >/dev/null 2>&1; then printf repo; elif [ -e $ROOT_Q ]; then printf foreign; else printf absent; fi") \
  || die "clone probe failed on $ALIAS" 1
case "$CLONE_STATE" in
  repo) skipped "git checkout at $CODE_ROOT ($(probe "git -C $ROOT_Q remote get-url origin" || true))" ;;
  foreign) gap "$CODE_ROOT exists but is not a git checkout. Inspect it on the host, move it aside, then rerun; this script never overwrites existing files." ;;
  absent)
    if [ "$DRY_RUN" -eq 1 ]; then
      would "git clone $FORK $CODE_ROOT"
    elif run "git clone $FORK_Q $ROOT_Q" >/dev/null 2>&1 \
      && [ "$(probe "git -C $ROOT_Q rev-parse --is-inside-work-tree" || true)" = true ]; then
      changed "cloned $FORK to $CODE_ROOT"
    else
      gap "git clone of $FORK to $CODE_ROOT failed. Clone it on the host by hand, then rerun."
    fi
    ;;
esac

step "remote entrypoint symlink"
WANT="$CODE_ROOT/bin/fm-remote-entrypoint.sh"
WANT_Q=$(sq "$WANT")
# shellcheck disable=SC2016 # $HOME and $p expand on the target host, not here.
LINK_STATE=$(probe 'p="$HOME/.local/bin/fm-remote-entrypoint.sh"; if [ -L "$p" ]; then printf "link|%s" "$(readlink "$p")"; elif [ -e "$p" ]; then printf "foreign"; else printf "absent"; fi') \
  || die "entrypoint probe failed on $ALIAS" 1
if [ "link|$WANT" = "$LINK_STATE" ]; then
  skipped "${REMOTE_HOME}/.local/bin/fm-remote-entrypoint.sh points at the code root"
elif case "$LINK_STATE" in link\|*) true ;; *) false ;; esac; then
  gap "${REMOTE_HOME}/.local/bin/fm-remote-entrypoint.sh points at ${LINK_STATE#link|} instead of $WANT. Fix the symlink on the host by hand, then rerun; this script never rewrites it."
elif [ "$LINK_STATE" = foreign ]; then
  gap "${REMOTE_HOME}/.local/bin/fm-remote-entrypoint.sh exists and is not a symlink. Inspect it on the host and replace it with: ln -sfn $WANT ${REMOTE_HOME}/.local/bin/fm-remote-entrypoint.sh"
elif [ "$LINK_STATE" = absent ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    would "link ~/.local/bin/fm-remote-entrypoint.sh to $WANT"
  elif run "mkdir -p \"\$HOME/.local/bin\" && ln -s $WANT_Q \"\$HOME/.local/bin/fm-remote-entrypoint.sh\"" >/dev/null 2>&1; then
    changed "linked ${REMOTE_HOME}/.local/bin/fm-remote-entrypoint.sh"
  else
    gap "could not create the entrypoint symlink. Create it on the host by hand, then rerun."
  fi
else
  die "entrypoint probe returned an unreadable value" 1
fi
if [ "$DRY_RUN" -eq 0 ] && [ "$GAPS" -eq 0 ]; then
  if probe 'command -v fm-remote-entrypoint.sh' >/dev/null 2>&1; then
    say "entrypoint resolves on a fresh non-interactive PATH: $(probe 'command -v fm-remote-entrypoint.sh' || true)"
  else
    gap "fm-remote-entrypoint.sh does not resolve on a fresh non-interactive PATH. Check ${REMOTE_HOME}/.local/bin on the host, then rerun."
  fi
fi

step "herdr per herdr.dev"
if probe 'command -v herdr' >/dev/null 2>&1; then
  skipped "herdr $(probe 'herdr --version' || true)"
elif [ "$DRY_RUN" -eq 1 ]; then
  would "install herdr via $HERDR_INSTALL_URL"
elif run "curl -fsSL $HERDR_INSTALL_URL | sh" >/dev/null 2>&1 \
  && probe 'command -v herdr' >/dev/null 2>&1; then
  changed "installed herdr $(probe 'herdr --version' || true)"
else
  gap "herdr install failed. On the host run: curl -fsSL $HERDR_INSTALL_URL | sh (see https://herdr.dev), then rerun."
fi

step "tasks-axi via npm"
# shellcheck disable=SC2016 # $HOME expands on the target host, not here.
TASKS_AXI_INSTALL='npm install -g tasks-axi || npm install -g --prefix "$HOME/.local" tasks-axi'
if probe 'command -v tasks-axi' >/dev/null 2>&1; then
  skipped "tasks-axi $(probe 'tasks-axi --version' || true)"
elif [ "$DRY_RUN" -eq 1 ]; then
  would "npm install -g tasks-axi (user-local prefix fallback)"
elif run "$TASKS_AXI_INSTALL" >/dev/null 2>&1 \
  && probe 'command -v tasks-axi' >/dev/null 2>&1; then
  changed "installed tasks-axi $(probe 'tasks-axi --version' || true)"
else
  gap "tasks-axi install failed. On the host run: npm install -g tasks-axi (Node 18+ required), then rerun."
fi

step "treehouse"
if probe 'command -v treehouse' >/dev/null 2>&1; then
  skipped "treehouse $(probe 'treehouse --version' || true)"
elif [ "$DRY_RUN" -eq 1 ]; then
  would "install treehouse via $TREEHOUSE_INSTALL_URL"
elif run "curl -fsSL $TREEHOUSE_INSTALL_URL | sh" >/dev/null 2>&1 \
  && probe 'command -v treehouse' >/dev/null 2>&1; then
  changed "installed treehouse $(probe 'treehouse --version' || true)"
else
  gap "treehouse install failed. On the host run: curl -fsSL $TREEHOUSE_INSTALL_URL | sh, then rerun."
fi

step "verified harness lane (opencode default)"
FOUND_HARNESS=$(probe "for t in $HARNESS_TOOLS; do command -v \"\$t\" >/dev/null 2>&1 && { printf '%s' \"\$t\"; break; }; done") || FOUND_HARNESS=""
if [ -n "$FOUND_HARNESS" ]; then
  skipped "harness already resolves: $FOUND_HARNESS ($(probe "command -v $FOUND_HARNESS" || true))"
elif [ "$DRY_RUN" -eq 1 ]; then
  would "install opencode via $OPENCODE_INSTALL_URL"
elif run "curl -fsSL $OPENCODE_INSTALL_URL | bash" >/dev/null 2>&1 \
  && probe 'command -v opencode' >/dev/null 2>&1; then
  changed "installed opencode $(probe 'opencode --version' || true)"
else
  gap "opencode install failed and no other verified harness (claude codex opencode pi pi-signed grok kimi) resolves. Install one on the host, then rerun."
fi

step "llm-router-axi with jev shadow enabled"
# shellcheck disable=SC2016 # $missing expands on the target host, not here.
ROUTER_MISSING=$(probe 'missing=""; command -v llm-router-axi >/dev/null 2>&1 || missing="$missing llm-router-axi"; command -v usage-axi >/dev/null 2>&1 || missing="$missing usage-axi"; printf "%s" "$missing"') \
  || die "router probe failed on $ALIAS" 1
if [ -z "$ROUTER_MISSING" ]; then
  skipped "llm-router-axi and usage-axi resolve"
elif [ "$DRY_RUN" -eq 1 ]; then
  would "build llm-router-axi and usage-axi from GitHub clones ($ROUTER_MISSING)"
else
  say "missing on host:$ROUTER_MISSING"
  # shellcheck disable=SC2016 # $repo, $dir, $HOME, $1, $2 expand on the target host, not here.
  BUILD_REMOTE='set -eu
build_axi() {
  repo=$1; dir=$2
  if [ ! -d "$dir/.git" ]; then rm -rf "$dir"; git clone "$repo" "$dir"; fi
  (cd "$dir" && npm ci && npm run build && npm install -g --prefix "$HOME/.local" .)
}
build_axi $ROUTER_REPO_Q "$HOME/llm-router-axi"
build_axi $USAGE_REPO_Q "$HOME/usage-axi"'
  BUILD_REMOTE=${BUILD_REMOTE//\$ROUTER_REPO_Q/$(sq "$ROUTER_REPO")}
  BUILD_REMOTE=${BUILD_REMOTE//\$USAGE_REPO_Q/$(sq "$USAGE_REPO")}
  # shellcheck disable=SC2016 # $missing expands on the target host, not here.
  if run "$BUILD_REMOTE" >/dev/null 2>&1 \
    && [ -z "$(probe 'missing=""; command -v llm-router-axi >/dev/null 2>&1 || missing="$missing llm-router-axi"; command -v usage-axi >/dev/null 2>&1 || missing="$missing usage-axi"; printf "%s" "$missing"')" ]; then
    changed "built llm-router-axi and usage-axi into ~/.local/bin"
  else
    gap "router build failed. On the host: git clone $ROUTER_REPO plus $USAGE_REPO, then in each run npm ci && npm run build && npm install -g --prefix the remote account's .local directory (Node 18+ required), then rerun."
  fi
fi
if [ "$DRY_RUN" -eq 0 ]; then
  if probe 'command -v llm-router-axi' >/dev/null 2>&1; then
    POLICY_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-station-policy.XXXXXX") || die "cannot stage router policy" 1
    trap 'rm -f -- "$POLICY_TMP"' EXIT
    if [ -f ~/.config/llm-router-axi/policy.json ] && command -v jq >/dev/null 2>&1; then
      jq '.jev.shadow.enabled = true' ~/.config/llm-router-axi/policy.json > "$POLICY_TMP" \
        || die "cannot derive the router policy from this machine's copy" 1
      say "policy: mirrored from this machine's llm-router-axi policy.json with jev.shadow.enabled=true"
    else
      printf '{"version":1,"jev":{"shadow":{"enabled":true}}}\n' > "$POLICY_TMP"
      say "policy: minimal default (no local policy to mirror); router defaults apply"
    fi
    # shellcheck disable=SC2016 # $HOME expands on the target host, not here.
    REMOTE_POLICY=$(probe 'cat "$HOME/.config/llm-router-axi/policy.json" 2>/dev/null' || true)
    if [ "$REMOTE_POLICY" = "$(cat "$POLICY_TMP")" ]; then
      skipped "${REMOTE_HOME}/.config/llm-router-axi/policy.json already matches the desired policy"
    else
      # shellcheck disable=SC2016 # $HOME expands on the target host, not here.
      "${SSH_BASE[@]}" -- "$ALIAS" 'mkdir -p "$HOME/.config/llm-router-axi" && cat > "$HOME/.config/llm-router-axi/policy.json"' < "$POLICY_TMP" >/dev/null 2>&1 \
        || die "policy transfer to $ALIAS failed" 1
      changed "wrote ${REMOTE_HOME}/.config/llm-router-axi/policy.json"
    fi
    rm -f -- "$POLICY_TMP"
    trap - EXIT
    if probe 'llm-router-axi policy validate' >/dev/null 2>&1; then
      say "policy validates on the host with jev shadow on"
    else
      gap "router policy does not validate on the host. Inspect ${REMOTE_HOME}/.config/llm-router-axi/policy.json there, then rerun."
    fi
    CLASSIFY_OUT=$(probe 'llm-router-axi classify --task "station bootstrap smoke probe" --json' || true)
    case "$CLASSIFY_OUT" in
      *'"source": "fallback"'*)
        say "router degrades gracefully with no key present (source: fallback). To enable Jev shadow on this station, place that host's own TYPESAFE_API_KEY in its ${REMOTE_HOME}/.claude/.env file; never copy this Mac's value." ;;
      *'"source": "jev"'*)
        say "router answers via Jev on the host (source: jev); a host-local TYPESAFE_API_KEY is already configured." ;;
      *)
        gap "router classify probe failed on the host. Run llm-router-axi doctor there, then rerun." ;;
    esac
  elif [ "$GAPS" -eq 0 ]; then
    gap "llm-router-axi still missing after the build step; close the build gap above first."
  fi
fi

step "final verification: fm-remote-doctor.sh on $ALIAS"
say "steps applied so far: $CHANGES changed, $GAPS operator gap(s) open"
if [ "$DRY_RUN" -eq 1 ]; then
  say "dry run: read-only doctor below (no --fix, nothing repaired)"
  probe "$ROOT_Q/bin/fm-remote-doctor.sh" || true
  say "dry run: $PENDING step(s) would change the host; rerun without --dry-run to apply"
  exit 0
fi
if [ "$GAPS" -gt 0 ]; then
  die "bootstrap incomplete: $GAPS operator gap(s) remain above; close them, then rerun" 1
fi
if [ ! -x "$FM_ROOT/bin/fm-remote-doctor.sh" ]; then
  die "this checkout has no bin/fm-remote-doctor.sh" 1
fi
DOCTOR_REMOTE="$ROOT_Q/bin/fm-remote-doctor.sh"
say "--- doctor --fix (repairs workers, then re-derives every check) ---"
probe "$DOCTOR_REMOTE --fix" || true
say "--- doctor read-only (final verdict) ---"
if probe "$DOCTOR_REMOTE"; then
  say "station is ready: doctor passes on $ALIAS (seeding via fm-remote-home-seed.sh is the separate next step)"
  exit 0
fi
die "doctor still reports gaps on $ALIAS; close the OPERATOR NEEDED items above, then rerun" 1
