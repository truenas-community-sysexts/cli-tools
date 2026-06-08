#!/usr/bin/env bash
# TrueNAS PREINIT script: activates cli-tools.raw sysext on every boot.
# Runs before middleware starts. Unlike a driver sysext, nothing here loads
# kernel modules -- it only re-merges the sysext so the bundled commands are
# back on PATH (under /usr/bin and /usr/sbin) after a reboot.
#
# Stored on persistent pool; registered via midclt during install.
# Idempotent: safe to run on every boot.

set -euo pipefail

log() {
    echo "[cli-tools-preinit] $*"
    logger -t cli-tools-preinit "$*" 2>/dev/null || true
}

# --- Find persistent config via glob ---
# nullglob: if no pool matches, the loop body never runs (instead of
# iterating once with the literal glob string).
PERSIST_DIR=""
PERSIST_DIRS=()
shopt -s nullglob
for d in /mnt/*/.config/cli-tools; do
    [ -d "$d" ] && PERSIST_DIRS+=("$d")
done
shopt -u nullglob

if [ ${#PERSIST_DIRS[@]} -eq 0 ]; then
    log "No persistent config found at /mnt/*/.config/cli-tools/, nothing to do"
    exit 0
fi
if [ ${#PERSIST_DIRS[@]} -gt 1 ]; then
    log "WARNING: cli-tools config found on ${#PERSIST_DIRS[@]} pools: ${PERSIST_DIRS[*]}"
    log "WARNING: using ${PERSIST_DIRS[0]} (alphabetically first). Remove duplicates to silence this warning."
fi
PERSIST_DIR="${PERSIST_DIRS[0]}"

# The persistent blob on the data pool is the sysext image itself; we point
# /run/extensions at it directly instead of copying it onto the boot pool.
# /usr is wiped on every TrueNAS update, so a boot-pool copy would not survive
# anyway, and writing to /usr means toggling its readonly ZFS property.
CLI_TOOLS_RAW="${PERSIST_DIR}/cli-tools.raw"

if [ ! -f "$CLI_TOOLS_RAW" ]; then
    log "No cli-tools.raw at ${CLI_TOOLS_RAW}, nothing to do"
    exit 0
fi

# --- Activate sysext directly off the data pool ---
# /run/extensions is tmpfs (gone after reboot), so we recreate the symlink
# every boot. systemd-sysext loop-mounts the symlink target wherever it lives;
# loop_device_make_by_path() is filesystem-agnostic, so a ZFS data-pool path
# works the same as a boot-pool path.
log "Activating cli-tools sysext..."
mkdir -p /run/extensions
ln -sf "$CLI_TOOLS_RAW" /run/extensions/cli-tools.raw
systemd-sysext refresh
ldconfig

# Report what merged, for the journal. A non-zero exit from `list` is not
# fatal -- the refresh above is the operation that matters.
if systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx cli-tools; then
    log "cli-tools sysext merged into /usr"
else
    log "WARNING: cli-tools sysext did not appear in 'systemd-sysext list' after refresh"
fi

log "Done"
exit 0
