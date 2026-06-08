# Install Guide

## Quick install

```bash
curl -fsSL https://github.com/truenas-community-sysexts/cli-tools/releases/latest/download/install.sh | sudo bash
```

This downloads the latest `cli-tools.raw`, verifies its checksum, activates it
via `systemd-sysext`, copies it to your data pool, and registers a PREINIT
script so it survives reboots and TrueNAS updates.

## Options

`install.sh` accepts:

| Option | Description |
| --- | --- |
| `--pool=NAME` | ZFS pool to store the persistent copy on (`/mnt/NAME/.config/cli-tools`) |
| `--persist-path=PATH` | Exact persistent path; must be `/mnt/<pool>/.config/cli-tools` |
| `--repo=OWNER/NAME` | Download from a fork instead of the default repo (also via `CLI_TOOLS_REPO`) |
| `--check` | Read-only probe of an existing install; prints a status report |
| `--dry-run` | Validate downloads/checksums/pool resolution without changing anything |
| `--help` | Usage |
| `[path-to-cli-tools.raw]` | Install a local image instead of downloading |

Examples:

```bash
sudo ./install.sh --pool=fast
sudo ./install.sh --check
sudo ./install.sh --dry-run
sudo ./install.sh /tmp/cli-tools.raw
```

## Persistence model

TrueNAS wipes `/usr` on every update and `/run` is tmpfs, so nothing placed
there directly would survive. Instead:

1. The `cli-tools.raw` image is stored on your **data pool** at
   `/mnt/<pool>/.config/cli-tools/cli-tools.raw`.
2. A **PREINIT** script (`cli-tools-preinit.sh`, also stored there) is
   registered with the TrueNAS middleware via `midclt`. On every boot it
   re-creates the `/run/extensions/cli-tools.raw` symlink and runs
   `systemd-sysext refresh`, re-merging the tools into `/usr`.

If you have multiple data pools, pass `--pool=` (or `--persist-path=`) so the
installer knows where to put the persistent copy. The PREINIT script scans
`/mnt/*/.config/cli-tools` at boot, so the path must match that shape exactly.

## Verifying

`sudo ./install.sh --check` reports:

- the activation symlink resolves to an image
- the sysext is merged into `/usr`
- every bundled command resolves on `PATH`
- the persistent backup and PREINIT script are present
- the PREINIT script is registered (PREINIT, enabled) and ran cleanly last boot

## Uninstalling

```bash
curl -fsSL https://github.com/truenas-community-sysexts/cli-tools/releases/latest/download/uninstall.sh | sudo bash
```

`uninstall.sh` is a thin alias for `restore.sh`. It unmerges the sysext,
re-merges any other active sysexts, deregisters the PREINIT script, and removes
`/mnt/*/.config/cli-tools`. Tools that ship with TrueNAS itself are untouched.
