#!/usr/bin/env bash
# agy (Antigravity CLI) session-open adapter: the RUN tier transport for agy.
#
# Registered in tracked .agents/hooks.json for agy's `SessionStart` hook. It is
# a thin transport around bin/fm-sessionstart-run.sh, which remains the single
# owner of source routing, eligibility, and the digest itself.
#
# agy runs a SessionStart hook's stdout object and injects each `injectSteps`
# entry into the conversation, so a `systemMessage` step lands the digest before
# the first turn (verified live, agy 1.4.7: a marker injected this way was
# repeated by the model on request). agy's payload has no `source` field, so the
# registration supplies it.
#
# Usage: fm-sessionstart-agy.sh --source <source>
#
# Every path exits 0 and prints one JSON object. A failed session start must
# reach the agent as digest text it can act on, never as a refusal to open the
# session, and `{}` is agy's documented no-op output.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE=
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE=${2:-}
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    *) shift ;;
  esac
done

DIGEST=$("$SCRIPT_DIR/fm-sessionstart-run.sh" --source "$SOURCE" </dev/null 2>/dev/null || true)
if [ -z "$DIGEST" ] || ! command -v jq >/dev/null 2>&1; then
  printf '{}\n'
  exit 0
fi
jq -n --arg c "$DIGEST" '{injectSteps:[{systemMessage:{systemMessage:$c}}]}' 2>/dev/null || printf '{}\n'
exit 0
