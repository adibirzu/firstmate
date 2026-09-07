#!/usr/bin/env bash
set -euo pipefail
repo=/Users/adrianb/.no-mistakes/worktrees/80e4cf1781af/01M1XCRT7JYY1Y6VQWHYYYXDEN
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
home="$fixture/home"
fakebin="$fixture/fakebin"
mkdir -p "$home/state" "$home/data" "$home/projects/demo" "$home/config" "$fakebin" "$fixture/codex-config"
printf '%s\n' '## In flight' '- [ ] usage-demo - Demonstrate the live usage row (repo: demo) (kind: ship)' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
printf '%s\n' \
  'window=demo:usage-demo' \
  'worktree='"$home"'/projects/demo' \
  'project=demo' \
  'harness=codex' \
  'kind=ship' \
  'mode=ship' \
  'yolo=off' \
  'model=gpt-5.6-terra' \
  'account=codex-demo' \
  'spawn_gen=1' > "$home/state/usage-demo.meta"
gen=$("$repo/bin/fm-busy-event.sh" arm "$home/state" usage-demo)
"$repo/bin/fm-busy-event.sh" apply "$home/state" usage-demo busy --gen "$gen" --source codex-hook --event user-prompt-submit
printf '%s\n' \
  '{' \
  '  "codex-demo": {' \
  '    "harness": "codex",' \
  '    "isolation": "config-dir-env",' \
  '    "env": "CODEX_HOME",' \
  '    "config_dir": "'"$fixture"'/codex-config"' \
  '  }' \
  '}' > "$fixture/accounts.json"
printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in' '  list-windows) sed -n "s/^window=[^:]*://p" "$FM_HOME"/state/*.meta ;;' '  display-message) printf "%%1\\n" ;;' '  capture-pane) printf "working on usage row\\n" ;;' 'esac' > "$fakebin/tmux"
printf '%s\n' '#!/usr/bin/env bash' 'printf "status=ok source=codex context_pct=40\\n"' > "$fakebin/statusline"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "{\"providers\":[{\"provider\":\"codex\",\"quotaSemantics\":{\"effectiveAvailability\":[{\"selection\":{\"status\":\"known\",\"spendPriority\":-3.25}}]}}]}"' > "$fakebin/quota-axi"
chmod +x "$fakebin/tmux" "$fakebin/statusline" "$fakebin/quota-axi"
PATH="$fakebin:$PATH" FM_HOME="$home" FM_ACCOUNTS_FILE="$fixture/accounts.json" FM_CREW_USAGE_ENABLE_QUOTA=1 FM_CREW_USAGE_STATUSLINE_BIN="$fakebin/statusline" "$repo/bin/fm-bearings-snapshot.sh" --json \
  | jq '{schema, in_flight: [.in_flight[] | select(.id == "usage-demo") | {id, usage_harness, usage_model, usage_context_pct, usage_quota}]}'
