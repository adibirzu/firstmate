#!/usr/bin/env bash
# lifeos-cowork-backup.sh — Full backup for LifeOS, CoWork, and Firstmate fleet state
set -euo pipefail

BACKUP_ROOT="/Volumes/ExternalNVME/Backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="${BACKUP_ROOT}/LifeOS_Backup_${TIMESTAMP}"
ARCHIVE_PATH="${BACKUP_ROOT}/LifeOS_CoWork_Fleet_Backup_${TIMESTAMP}.tar.gz"

mkdir -p "${BACKUP_DIR}"

echo "==> Starting comprehensive backup at ${TIMESTAMP}..."

# 1. Backup Claude CoWork & Projects
if [ -d "${HOME}/Documents/Claude" ]; then
  echo "==> Backing up ~/Documents/Claude..."
  tar -czf "${BACKUP_DIR}/Claude_CoWork.tar.gz" -C "${HOME}/Documents" Claude
fi

# 2. Backup LifeOS USER Config & Memory
if [ -d "${HOME}/.config/LIFEOS" ]; then
  echo "==> Backing up ~/.config/LIFEOS..."
  tar -czf "${BACKUP_DIR}/LifeOS_User_Config.tar.gz" -C "${HOME}/.config" LIFEOS
fi

# 3. Backup LifeOS Runtime & State
if [ -d "${HOME}/.claude/LIFEOS" ]; then
  echo "==> Backing up ~/.claude/LIFEOS..."
  tar -czf "${BACKUP_DIR}/LifeOS_Runtime.tar.gz" -C "${HOME}/.claude" LIFEOS
fi

# 4. Backup Firstmate Fleet Data & State
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRSTMATE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [ -d "${FIRSTMATE_ROOT}/data" ] || [ -d "${FIRSTMATE_ROOT}/state" ]; then
  echo "==> Backing up Firstmate fleet records..."
  tar -czf "${BACKUP_DIR}/Firstmate_Fleet_State.tar.gz" -C "${FIRSTMATE_ROOT}" data state config 2>/dev/null || true
fi

# Create single master tarball
echo "==> Compressing master archive to ${ARCHIVE_PATH}..."
tar -czf "${ARCHIVE_PATH}" -C "${BACKUP_ROOT}" "LifeOS_Backup_${TIMESTAMP}"

# Cleanup intermediate directory
rm -rf "${BACKUP_DIR}"

echo "==> Backup successfully created:"
ls -lh "${ARCHIVE_PATH}"
