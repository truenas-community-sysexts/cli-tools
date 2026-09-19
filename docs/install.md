# Install Guide

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/cli-tools/main/get.sh | sudo bash
```

`get.sh` (served from `main`) reads the TrueNAS version (`midclt call
system.info`), derives the **train** (the major version from 26 on, so every
26.x including betas is train `26`; major.minor before that, e.g. `25.10`),
and picks the newest release **approved** for that train:

- its notes carry `<!-- verified-train: <train> -->`, written when that
  train's hardware-test issue was closed as completed, or
- it is a full (non-pre-release) release with no `verified-train` marker at
  all. Every release from before per-train approval is one of these, so they
  count for every train.

A marker for another train only does not count, and nothing unapproved is
installed: with no approved release for the train it stops and links the open
hardware-test issues. It then downloads **that** release's `install.sh` and
`cli-tools-lib.sh` and runs `install.sh` with your arguments plus
`--release=<tag>`, which downloads that release's `cli-tools.raw`, verifies
its checksum, activates it via `systemd-sysext`, copies it to your data pool,
and registers a PREINIT script so it survives reboots and TrueNAS updates.

A release from before per-train approval (`v2026.08.21-r11` and older) has an
`install.sh` without `--release`. For those, `get.sh` downloads the release's
`cli-tools.raw` itself, checks it against the release's `.sha256`, and hands
it to that `install.sh` as a local image.

Flags for the installer go after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/cli-tools/main/get.sh | sudo bash -s -- --pool=fast
```

## Options

`get.sh` accepts:

| Option | Description |
| --- | --- |
| `--release=TAG` | Use this release instead of the newest approved one (no approval check) |
| `--uninstall` | Run the release's `uninstall.sh` instead of `install.sh` |
| `--repo=OWNER/NAME` | Use a fork's releases (also via `CLI_TOOLS_REPO`) |

Everything else is passed to `install.sh`, which accepts:

| Option | Description |
| --- | --- |
| `--pool=NAME` | ZFS pool to store the persistent copy on (`/mnt/NAME/.config/cli-tools`) |
| `--persist-path=PATH` | Exact persistent path; must be `/mnt/<pool>/.config/cli-tools` |
| `--release=TAG` | Install this release. Without it (and without a local image), `install.sh` picks the newest release approved for this box's train, the same way `get.sh` does |
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
sudo ./install.sh --release=v2026.08.21-r11
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
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/cli-tools/main/get.sh | sudo bash -s -- --uninstall
```

This runs the `uninstall.sh` of the newest release approved for this box's
train, with that release's `restore.sh` and `cli-tools-lib.sh` beside it. A
release's `uninstall.sh` piped to bash on its own fetches `restore.sh` and
`cli-tools-lib.sh` from the newest approved release the same way.

`uninstall.sh` is a thin alias for `restore.sh`. It unmerges the sysext,
re-merges any other active sysexts, deregisters the PREINIT script, and removes
`/mnt/*/.config/cli-tools`. Tools that ship with TrueNAS itself are untouched.
