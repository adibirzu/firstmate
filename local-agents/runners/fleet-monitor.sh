#!/usr/bin/env bash
# fleet-monitor.sh - read-only disk, version, and host check. No restarts.
set -euo pipefail

# shellcheck disable=SC1091 source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

job_dir=${FM_AGENT_JOB_DIR:?FM_AGENT_JOB_DIR is required}
summary_file=$job_dir/summary.txt
report=$job_dir/report.md
task=$(job_get task)

if [ "$task" != "check" ]; then
  printf '%s\n' "task not allowed" >"$summary_file"
  write_result failed "$summary_file" ""
  exit 0
fi

disk_bad=0
available=""
set +e
df_out=$(df -k / 2>&1)
df_rc=$?
set -e
if [ "$df_rc" -ne 0 ]; then
  disk_bad=1
else
  available=$(printf '%s\n' "$df_out" | awk 'NR > 1 { value = $4 } END { print value }')
  case "$available" in
    ''|*[!0-9]*) disk_bad=1 ;;
    *)
      if [ "$available" -lt 8388608 ]; then
        disk_bad=1
      fi
      ;;
  esac
fi

versions=""
tool_name=""
for tool_name in no-mistakes orca herdr grok; do
  if command -v "$tool_name" >/dev/null 2>&1; then
    set +e
    tool_ver=$("$tool_name" --version 2>&1 | head -n 1)
    set -e
    versions="$versions$tool_name: ${tool_ver:-unknown}"$'\n'
  else
    versions="$versions$tool_name: missing"$'\n'
  fi
done

git_line="firstmate checkout: missing"
if [ -d "$HOME/dev/firstmate/.git" ]; then
  set +e
  git_counts=$(git -C "$HOME/dev/firstmate" rev-list --left-right --count origin/main...HEAD 2>&1)
  git_rc=$?
  set -e
  if [ "$git_rc" -eq 0 ]; then
    git_line="firstmate ahead/behind origin/main (left right): $git_counts"
  else
    git_line="firstmate rev-list failed: $git_counts"
  fi
fi

remote_script="uptime; systemctl --user is-active litellm.service langfuse.service comfyui.service || true; docker ps -a --filter status=exited --format '{{.Names}} {{.Status}}' || true"
set +e
adi1_out=$(ssh -o BatchMode=yes -o ConnectTimeout=8 adi1 "$remote_script" 2>&1)
adi1_rc=$?
adi2_out=$(ssh -o BatchMode=yes -o ConnectTimeout=8 adi2-ts "$remote_script" 2>&1)
adi2_rc=$?
set -e

{
  printf '%s\n' "# Fleet monitor"
  printf '\n%s\n' "## Disk"
  printf '%s\n' "df exit: $df_rc"
  printf '%s\n' "available_kb: ${available:-unknown}"
  printf '\n%s\n' "## Versions"
  printf '%s\n' "$versions"
  printf '%s\n' "$git_line"
  printf '\n%s\n' "## adi1 (exit $adi1_rc)"
  printf '%s\n' "$adi1_out"
  printf '\n%s\n' "## adi2-ts (exit $adi2_rc)"
  printf '%s\n' "$adi2_out"
} >"$report"

details=""
if [ "$adi1_rc" -eq 0 ]; then
  details="$details"$'\n'"adi1 exited containers:"$'\n'"$adi1_out"
fi
if [ "$adi2_rc" -eq 0 ]; then
  details="$details"$'\n'"adi2-ts exited containers:"$'\n'"$adi2_out"
fi

if [ "$disk_bad" -eq 1 ] || [ "$adi1_rc" -ne 0 ] || [ "$adi2_rc" -ne 0 ]; then
  printf '%s\n' "blocked: disk below 8 GiB or a monitored host is unreachable" >"$summary_file"
  write_result blocked "$summary_file" "$details"
  exit 0
fi

printf '%s\n' "succeeded: disk is fine and monitored hosts answered" >"$summary_file"
write_result succeeded "$summary_file" "$details"
exit 0
