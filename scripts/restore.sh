#!/usr/bin/env bash
# Restores the original state by removing the cli-tools.raw sysext.
# Run this to completely remove the bundled CLI tools.

set -euo pipefail

# --- Parse CLI arguments ---
for arg in "$@"; do
    case "$arg" in
        --help)
            echo "Usage: sudo ./restore.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --help     Show this help"
            echo ""
            echo "Removes the cli-tools sysext, deregisters its PREINIT script,"
            echo "and deletes its persistent config from /mnt/*/.config/cli-tools."
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $arg (see --help)" >&2
            exit 2
            ;;
    esac
done

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "ERROR: must run as root (use sudo)" >&2
    exit 1
fi

# Source shared library (provides cli_tools_init_script_lookup).
# Try the sibling file first (checkout or extracted release); fall back to
# downloading from the release for the curl|bash case.
_source_cli_tools_lib() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || dir=""
    if [ -n "$dir" ] && [ -f "${dir}/cli-tools-lib.sh" ]; then
        # shellcheck source=scripts/cli-tools-lib.sh
        source "${dir}/cli-tools-lib.sh"
        return 0
    fi
    local tmp repo
    repo="${CLI_TOOLS_REPO:-truenas-community-sysexts/cli-tools}"
    tmp=$(mktemp /tmp/cli-tools-lib.XXXXXXXXXX)
    if curl -fsSL --max-time 30 \
           "https://github.com/${repo}/releases/latest/download/cli-tools-lib.sh" \
           -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        # shellcheck source=scripts/cli-tools-lib.sh
        source "$tmp"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}
_source_cli_tools_lib || {
    echo "ERROR: Could not load cli-tools-lib.sh (not found locally, download failed)." >&2
    echo "  Run from the release directory, or ensure network access to GitHub." >&2
    exit 1
}

echo "=== Removing cli-tools sysext ==="

# Remove the cli-tools sysext symlink and unmerge to drop the /usr overlay.
# Plain `systemd-sysext refresh` would re-merge any other active sysexts (e.g.
# an NVIDIA or Coral sysext) instead of dropping ours cleanly, so unmerge
# everything first and re-merge the survivors below. The cli-tools.raw image
# itself lives on the data pool and is removed with the persistent config.
echo "Removing cli-tools sysext..."
rm -f /run/extensions/cli-tools.raw
systemd-sysext unmerge 2>/dev/null || true

# Re-merge any remaining sysexts that were deactivated by the unmerge above.
if ls /run/extensions/*.raw >/dev/null 2>&1; then
    echo "Re-merging remaining sysexts..."
    systemd-sysext refresh 2>/dev/null || echo "WARNING: Failed to re-merge remaining sysexts"
    ldconfig 2>/dev/null || true
fi

echo ""
echo "=== Cleaning up persistence ==="

# Deregister init script. Treat midclt errors as "not found": there's nothing
# safe to do if we can't query, and a stale entry the user can clean up
# manually beats a half-finished restore.
INIT_LOOKUP=$(cli_tools_init_script_lookup)
if [ "$INIT_LOOKUP" = "error" ]; then
    echo "WARNING: Could not query TrueNAS middleware, skipping init script deregistration"
    INIT_ID=""
else
    INIT_ID="${INIT_LOOKUP%%|*}"
fi

if [ -n "$INIT_ID" ]; then
    midclt call initshutdownscript.delete "$INIT_ID" 2>/dev/null \
        && echo "Init script deregistered (id: ${INIT_ID})" \
        || echo "WARNING: Failed to deregister init script"
elif [ "$INIT_LOOKUP" != "error" ]; then
    echo "No init script found to deregister"
fi

# Remove persistent config
for d in /mnt/*/.config/cli-tools; do
    if [ -d "$d" ]; then
        echo "Removing persistent config: $d"
        rm -rf "$d"
    fi
done

echo "Persistence cleanup complete"
echo ""
echo "=== Restore complete ==="
echo "The bundled CLI tools have been removed. Tools that ship with TrueNAS itself are unaffected."
