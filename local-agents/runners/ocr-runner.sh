#!/usr/bin/env bash
# ocr-runner.sh - read-only OCR status. This runner never restarts anything.
set -euo pipefail

# shellcheck disable=SC1091 source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

job_dir=${FM_AGENT_JOB_DIR:?FM_AGENT_JOB_DIR is required}
summary_file=$job_dir/summary.txt
report=$job_dir/report.md
task=$(job_get task)
host=$(job_get _dispatch.host)

if [ "$task" != "status" ] && [ "$task" != "report" ]; then
  printf '%s\n' "task not allowed" >"$summary_file"
  write_result failed "$summary_file" ""
  exit 0
fi

set +e
docker_out=$(docker ps --filter 'name=^/ocr-vlm$' --format '{{.Names}} {{.Status}}' 2>&1)
docker_rc=$?
systemd_out=$(systemctl is-active ocr-vlm.service 2>&1)
systemd_rc=$?
nvidia_out=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>&1)
nvidia_rc=$?
set -e

running=0
if [ "$docker_rc" -eq 0 ] && printf '%s\n' "$docker_out" | awk '$1 == "ocr-vlm" && $2 == "Up" { found = 1 } END { exit !found }'; then
  running=1
fi
if [ "$systemd_rc" -eq 0 ] && [ "$(printf '%s' "$systemd_out" | tr -d '[:space:]')" = "active" ]; then
  running=1
fi

set +e
roots=$(python3 - "$host" "$job_dir/agents.json" <<'PY'
import json
import os
import sys
from pathlib import Path

host, registry = sys.argv[1:3]
try:
    data = json.loads(Path(registry).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
roots = data.get("agents", {}).get("ocr-runner", {}).get("allowed_roots", {}).get(host, [])
if not isinstance(roots, list):
    raise SystemExit(1)
resolved = []
for raw in roots:
    if not isinstance(raw, str):
        continue
    root = Path(os.path.expanduser(raw))
    if not root.is_absolute():
        continue
    try:
        root = root.resolve(strict=True)
    except OSError:
        continue
    if root.is_dir():
        resolved.append(str(root))
if not resolved:
    raise SystemExit(1)
print("\n".join(resolved))
PY
)
roots_rc=$?
set -e
if [ "$roots_rc" -ne 0 ]; then
  printf '%s\n' "configured OCR roots are unavailable" >"$summary_file"
  write_result failed "$summary_file" "configured OCR roots are unavailable"
  exit 0
fi
file_count=0
while IFS= read -r root; do
  [ -n "$root" ] || continue
  count=$(find "$root" -xdev -type f 2>/dev/null | wc -l | tr -d '[:space:]')
  file_count=$((file_count + count))
done <<EOF
$roots
EOF
progress_note="progress files: $file_count under configured roots"

{
  printf '%s\n' "# OCR status"
  printf '\n%s\n' "## Containers"
  printf '%s\n' "docker exit: $docker_rc"
  printf '%s\n' "$docker_out"
  printf '\n%s\n' "## Service"
  printf '%s\n' "systemctl exit: $systemd_rc"
  printf '%s\n' "$systemd_out"
  printf '\n%s\n' "## Compute apps"
  printf '%s\n' "nvidia-smi exit: $nvidia_rc"
  printf '%s\n' "$nvidia_out"
  printf '\n%s\n' "## Progress"
  printf '%s\n' "$progress_note"
} >"$report"

if [ "$running" -eq 0 ]; then
  printf '%s\n' "blocked: ocr-vlm is not running" >"$summary_file"
  write_result blocked "$summary_file" "$progress_note"
  exit 0
fi

printf '%s\n' "succeeded: ocr-vlm is running" >"$summary_file"
write_result succeeded "$summary_file" "$progress_note"
exit 0
