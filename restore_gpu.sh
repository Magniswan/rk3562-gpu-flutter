#!/usr/bin/env bash
set -euo pipefail

# Restore the state recorded by enable_gpu.sh. The current enable script makes
# no device changes, so restore is a verification/no-op unless a future
# version records an explicit reversible change.

ADB_BIN="${ADB_BIN:-}"
if [[ -z "$ADB_BIN" ]]; then
  if command -v adb >/dev/null 2>&1; then
    ADB_BIN=adb
  elif command -v adb.exe >/dev/null 2>&1; then
    ADB_BIN=adb.exe
  else
    printf 'ERROR: adb/adb.exe not found in PATH\n' >&2
    exit 1
  fi
fi
ADB=("$ADB_BIN")
if [[ -n "${ADB_SERIAL:-}" ]]; then
  ADB+=( -s "$ADB_SERIAL" )
fi

shell() {
  "${ADB[@]}" shell "$1" | tr -d '\r'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

"${ADB[@]}" wait-for-device
[[ "$("${ADB[@]}" get-state 2>/dev/null | tr -d '\r')" == "device" ]] || die "ADB device is not ready"

backup_dir="${1:-}"
if [[ -z "$backup_dir" ]]; then
  backup_dir="$(find "${GPU_BACKUP_DIR:-$PWD/.gpu-backups}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
fi
[[ -n "$backup_dir" && -f "$backup_dir/state.env" ]] || die "No enable_gpu.sh state backup found"

# shellcheck disable=SC1090
source "$backup_dir/state.env"
current_status="$(shell 'tr -d "\000\r\n" </sys/firmware/devicetree/base/gpu@ff320000/status 2>/dev/null || true')"
current_compat="$(shell 'tr "\000" "\n" </sys/firmware/devicetree/base/compatible 2>/dev/null | sed -n "1p" || true')"

[[ "$current_compat" == "$compat" ]] || die "Device identity changed: backup=$compat current=$current_compat"

if [[ "${remote_changes:-none}" != "none" ]]; then
  die "Backup requests a change type that this conservative restore script does not recognize: $remote_changes"
fi

printf 'No device changes were made by enable_gpu.sh; nothing to revert.\n'
printf 'GPU DT status remains: %s (original: %s)\n' "${current_status:-missing}" "${gpu_status:-missing}"
printf 'Verified against backup: %s\n' "$backup_dir"
