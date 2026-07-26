#!/usr/bin/env bash
# fm-accounts-lib.sh — per-operator multi-account registry (Phase 4).
#
# Reads config/accounts.json; resolves + validates accounts against the verified
# per-CLI config-dir / auth-isolation matrix (adapters/config-dir-matrix.md).
#
# Three isolation methods (verified 2026-07-26):
#   config-dir-env   set <env>=<config_dir> for the child only (claude/codex/pi)
#   config-dir-flag  pass <flag> <config_dir> in argv           (cline)
#   api-key-env      set <env>=<key> for the child only         (grok/cursor-agent)
#
# Secrets never live here. api-key accounts store a key_file path (0600, in the
# operator's OWN home); fm-spawn reads the key at launch — it is never printed,
# never committed, never placed on argv.
#
# accounts.json schema (one entry per account name):
#   { "<name>": { "provider":"...", "harness":"...", "isolation":"...",
#                 "env":"<ENV>"|null, "flag":"<flag>"|null,
#                 "config_dir":"<path>"|null, "key_file":"<path>"|null,
#                 "scopes":["..."] } }

# Verified harness -> expected "<isolation>\t<env-or-flag>" (matrix source of truth).
fm_account_expect() { # harness
  case "$1" in
    claude)       printf 'config-dir-env\tCLAUDE_CONFIG_DIR\n' ;;
    codex)        printf 'config-dir-env\tCODEX_HOME\n' ;;
    pi)           printf 'config-dir-env\tPI_CODING_AGENT_DIR\n' ;;
    cline)        printf 'config-dir-flag\t--config\n' ;;
    grok)         printf 'api-key-env\tGROK_API_KEY\n' ;;
    cursor-agent) printf 'api-key-env\tCURSOR_API_KEY\n' ;;
    *) return 1 ;;
  esac
}

fm_accounts_file() {
  printf '%s\n' "${FM_ACCOUNTS_FILE:-${FM_HOME:-.}/config/accounts.json}"
}

# Refuse a path resolving into ANOTHER operator's home (cross-uid safety). Own
# home, /tmp, /opt are allowed. Empty path => allowed (method may not use one).
fm_account_assert_safe_path() { # path
  local p rp owner me; p=${1:-}
  [ -n "$p" ] && [ "$p" != "-" ] || return 0
  rp=$(realpath -m "$p"); me=$(id -un)
  case "$rp" in
    /home/*) owner=${rp#/home/}; owner=${owner%%/*}
      if [ "$owner" != "$me" ]; then
        echo "fm-accounts: refusing foreign-home path: $rp" >&2; return 1
      fi ;;
  esac
  return 0
}

# resolve: print TSV harness<TAB>isolation<TAB>env<TAB>flag<TAB>config_dir<TAB>key_file
# missing fields -> "-". Exit 1 if the registry or account is absent.
fm_account_resolve() { # name
  local name=$1 f; f=$(fm_accounts_file)
  [ -f "$f" ] || { echo "fm-accounts: no registry at $f" >&2; return 1; }
  jq -e --arg n "$name" 'has($n)' "$f" >/dev/null 2>&1 \
    || { echo "fm-accounts: unknown account: $name" >&2; return 1; }
  jq -r --arg n "$name" '
    .[$n] | [
      (.harness // "-"), (.isolation // "-"),
      (.env // "-"), (.flag // "-"),
      (.config_dir // "-"), (.key_file // "-")
    ] | @tsv' "$f"
}

# validate: harness known; isolation matches the harness's expected method +
# env/flag; required method fields present; paths cross-uid-safe. Exit 0/1.
fm_account_validate() { # name
  local name=$1 line harness iso env flag cdir kfile exp exp_iso exp_ef
  line=$(fm_account_resolve "$name") || return 1
  IFS=$'\t' read -r harness iso env flag cdir kfile <<<"$line"
  exp=$(fm_account_expect "$harness") \
    || { echo "fm-accounts: unknown harness: $harness" >&2; return 1; }
  exp_iso=$(printf '%s' "$exp" | cut -f1)
  exp_ef=$(printf '%s' "$exp" | cut -f2)
  [ "$iso" = "$exp_iso" ] \
    || { echo "fm-accounts: $name isolation '$iso' != expected '$exp_iso' for $harness" >&2; return 1; }
  case "$iso" in
    config-dir-env)
      [ "$env" = "$exp_ef" ] || { echo "fm-accounts: $name env '$env' != '$exp_ef'" >&2; return 1; }
      [ "$cdir" != "-" ]     || { echo "fm-accounts: $name missing config_dir" >&2; return 1; }
      fm_account_assert_safe_path "$cdir" || return 1 ;;
    config-dir-flag)
      [ "$flag" = "$exp_ef" ] || { echo "fm-accounts: $name flag '$flag' != '$exp_ef'" >&2; return 1; }
      [ "$cdir" != "-" ]      || { echo "fm-accounts: $name missing config_dir" >&2; return 1; }
      fm_account_assert_safe_path "$cdir" || return 1 ;;
    api-key-env)
      [ "$env" = "$exp_ef" ] || { echo "fm-accounts: $name env '$env' != '$exp_ef'" >&2; return 1; }
      [ "$kfile" != "-" ]    || { echo "fm-accounts: $name missing key_file" >&2; return 1; }
      fm_account_assert_safe_path "$kfile" || return 1 ;;
    *) echo "fm-accounts: $name unknown isolation '$iso'" >&2; return 1 ;;
  esac
  return 0
}

fm_account_list() { # -> account names, one per line
  local f; f=$(fm_accounts_file); [ -f "$f" ] || return 0
  jq -r 'keys[]' "$f"
}

fm_account_list_by_harness() { # harness -> matching account names
  local h=$1 f; f=$(fm_accounts_file); [ -f "$f" ] || return 0
  jq -r --arg h "$h" 'to_entries[] | select(.value.harness==$h) | .key' "$f"
}
