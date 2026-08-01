#!/usr/bin/env bash
# fm-statusline-quota-lib.sh - best-effort parse of crewmate statusline quota signals.
#
# Sourced, never executed. Owns pure parsers for the pane-visible statusline
# shapes that empirically report remaining capacity when quota-axi cannot:
#   claude: "5HR 3% ... WK 5% ..." (and similar token fragments)
#   codex:  "... Context 100% left · weekly 21% left"
#
# Contract (safety-critical):
#   - Unparseable input is "unknown", never "exhausted".
#   - A false exhaustion reading would migrate a healthy worker for no reason.
#   - This library never decides to hand off; firstmate chooses when to act.
#   - quota-axi remains best-effort elsewhere; this path is independent of it.
#
# Public functions:
#   fm_statusline_quota_parse <text>
#     Prints one line of key=value fields for the parsed signal.
#     Always exits 0. Fields always present: status, source.
#     status is one of: ok | low | unknown
#     "exhausted" is never emitted from unparseable input; only when a parsed
#     remaining percentage is exactly 0 (or the literal "0% left" shape).
#   fm_statusline_quota_verdict <text>
#     Prints only the status token (ok|low|unknown|exhausted).

# fm_statusline_quota_parse <text>
fm_statusline_quota_parse() {
  local text=${1-} status=unknown source=none five_hr='' weekly='' context=''
  local n

  # Codex: "Context N% left" and/or "weekly N% left"
  if printf '%s' "$text" | grep -Eqi 'Context[[:space:]]+[0-9]+%[[:space:]]+left'; then
    context=$(printf '%s' "$text" | sed -nE 's/.*[Cc]ontext[[:space:]]+([0-9]+)%[[:space:]]+left.*/\1/p' | head -n1)
    source=codex
  fi
  if printf '%s' "$text" | grep -Eqi 'weekly[[:space:]]+[0-9]+%[[:space:]]+left'; then
    weekly=$(printf '%s' "$text" | sed -nE 's/.*[Ww]eekly[[:space:]]+([0-9]+)%[[:space:]]+left.*/\1/p' | head -n1)
    source=codex
  fi

  # Claude: "5HR N%" and/or "WK N%"
  if printf '%s' "$text" | grep -Eqi '5HR[[:space:]]+[0-9]+%'; then
    five_hr=$(printf '%s' "$text" | sed -nE 's/.*5HR[[:space:]]+([0-9]+)%.*/\1/p' | head -n1)
    source=claude
  fi
  if printf '%s' "$text" | grep -Eqi 'WK[[:space:]]+[0-9]+%'; then
    weekly=$(printf '%s' "$text" | sed -nE 's/.*WK[[:space:]]+([0-9]+)%.*/\1/p' | head -n1)
    [ "$source" = none ] && source=claude
  fi

  if [ "$source" = none ]; then
    printf 'status=unknown source=none\n'
    return 0
  fi

  # A zero sample is exhausted and wins outright; otherwise any sample in 1..20
  # is low; anything else leaves ok. Unparseable samples never downgrade.
  status=ok
  for n in $five_hr $weekly $context; do
    case "$n" in
      ''|*[!0-9]*) continue ;;
      0) status=exhausted; break ;;
      [1-9]|1[0-9]|20) status=low ;;
    esac
  done

  printf 'status=%s source=%s' "$status" "$source"
  [ -n "$five_hr" ] && printf ' five_hour_pct=%s' "$five_hr"
  [ -n "$weekly" ] && printf ' weekly_pct=%s' "$weekly"
  [ -n "$context" ] && printf ' context_pct=%s' "$context"
  printf '\n'
}

# fm_statusline_quota_verdict <text>
fm_statusline_quota_verdict() {
  local line
  line=$(fm_statusline_quota_parse "$1")
  case "$line" in
    status=exhausted*) printf 'exhausted\n' ;;
    status=low*) printf 'low\n' ;;
    status=ok*) printf 'ok\n' ;;
    *) printf 'unknown\n' ;;
  esac
}
