#!/usr/bin/env bash
# ocr-runner.sh - read-only OCR status. This runner never restarts anything.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

job_dir=${FM_AGENT_JOB_DIR:?FM_AGENT_JOB_DIR is required}
summary_file=$job_dir/summary.txt
report=$job_dir/report.md
task=$(job_get task)
progress=$(job_input "path:")

if [ "$task" != "status" ] && [ "$task" != "report" ]; then
  printf '%s\n' "task not allowed" >"$summary_file"
  write_result failed "$summary_file" ""
  exit 0
fi

set +e
docker_out=$(docker ps -a --filter name=ocr --format '{{.Names}} {{.Status}}' 2>&1)
docker_rc=$?
nvidia_out=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>&1)
nvidia_rc=$?
set -e

running=0
if [ "$docker_rc" -eq 0 ] && printf '%s\n' "$docker_out" | grep -q 'Up'; then
  running=1
fi
if [ "$nvidia_rc" -eq 0 ] && printf '%s\n' "$nvidia_out" | grep -q '[^[:space:]]'; then
  running=1
fi

progress_note="progress path: not set"
file_count=""
case "$progress" in
  "") ;;
  /*)
    if [ -d "$progress" ]; then
      file_count=$(find "$progress" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
      progress_note="progress files: $file_count under $progress"
    else
      progress_note="progress path is not a directory: $progress"
    fi
    ;;
  *)
    progress_note="progress path must be absolute"
    ;;
esac

{
  printf '%s\n' "# OCR status"
  printf '\n%s\n' "## Containers"
  printf '%s\n' "docker exit: $docker_rc"
  printf '%s\n' "$docker_out"
  printf '\n%s\n' "## Compute apps"
  printf '%s\n' "nvidia-smi exit: $nvidia_rc"
  printf '%s\n' "$nvidia_out"
  printf '\n%s\n' "## Progress"
  printf '%s\n' "$progress_note"
} >"$report"

if [ "$running" -eq 0 ]; then
  printf '%s\n' "blocked: no OCR container or compute process is running" >"$summary_file"
  write_result blocked "$summary_file" "$progress_note"
  exit 0
fi

printf '%s\n' "succeeded: an OCR container or compute process is running" >"$summary_file"
write_result succeeded "$summary_file" "$progress_note"
exit 0
