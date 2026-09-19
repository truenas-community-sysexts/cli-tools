# CLI Tools Sysext for TrueNAS

A [systemd-sysext](https://www.freedesktop.org/software/systemd/man/systemd-sysext.html) package that adds a curated set of common command-line utilities to TrueNAS - the tools you reach for over SSH that aren't in the stock image - without modifying the immutable root filesystem.

Everything is merged into `/usr` at boot and survives reboots and TrueNAS updates. Because these are plain userspace binaries (not kernel modules), **one release works on every TrueNAS version**, and a hardware test on each TrueNAS train approves it for that train (see [Releases](#releases)).

## Documentation

| Doc | Contents |
| --- | --- |
| [Quick Start](#quick-start) | Install, verify, uninstall |
| [Releases](#releases) | Per-train approval, pinning a release |
| [docs/install.md](docs/install.md) | Install options, persistence, scripts reference |
| [docs/build.md](docs/build.md) | Build process, adding a tool, automated updates |
| [docs/architecture.md](docs/architecture.md) | sysext layout, self-contained binary bundling, read-only constraints |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common issues |

## What's Included

The exact set is defined in [`.github/tracked-versions.json`](.github/tracked-versions.json). Today:

| Tool | Source | Purpose |
| --- | --- | --- |
| `btop` | upstream static | Resource monitor (CPU/mem/net/disk) |
| `ncdu` | upstream static | Disk usage analyzer |
| `yq` | upstream static | YAML/JSON processor |
| `iotop` | Debian (`iotop-c`) | Per-process disk I/O monitor |
| `iftop` | Debian | Per-connection bandwidth monitor |
| `nethogs` | Debian | Per-process bandwidth monitor |
| `tree` | Debian | Recursive directory listing |
| `mtr` | Debian (`mtr-tiny`) | Combined traceroute + ping |
| `nmap` | Debian | Network/port scanner |

Tools that already ship with TrueNAS (e.g. `htop`, `smartctl`, `nvme`, `tcpdump`, `iperf3`, `rsync`, `rclone`, `restic`, `jq`, `git`, `vim`, `tmux`) are intentionally **not** bundled.

## Quick Start

### Prerequisites

- TrueNAS 25.10 or newer
- Root/sudo access
- A data pool (for persistent storage) and internet access (to download the release)

### Install

Installs the newest release a hardware test approved for your TrueNAS train and sets up persistence:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/cli-tools/main/get.sh | sudo bash
```

With an explicit pool for persistence (flags for the installer go after `bash -s --`):

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/cli-tools/main/get.sh | sudo bash -s -- --pool=fast
```

### Verify

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/cli-tools/main/get.sh | sudo bash -s -- --check
```

Or just run one of the tools: `btop`, `tree`, `nmap --version`.

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/cli-tools/main/get.sh | sudo bash -s -- --uninstall
```

## Releases

**Each release is approved per TrueNAS train.** The train is the major version from 26 on (every 26.x, betas included, is train `26`) and major.minor before that (`25.10`). A release starts as a pre-release with one hardware-test issue per supported train, and closing a train's issue as completed approves it for that train's boxes only. `get.sh` runs the install scripts of the newest release approved for your train, and that release's `install.sh` downloads its own `cli-tools.raw`. Full releases from before per-train approval count for every train. If no release is approved for your train yet, it stops and points at the open hardware tests instead of installing anything untested.

To install one exact release (this skips the approval check, which is how a tester installs a release under test):

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/cli-tools/main/get.sh | sudo bash -s -- --release=v2026.08.21-r11
```

## How It Works

- The tools are packed into a squashfs image (`cli-tools.raw`) with an `extension-release` marked `ID=_any`, and merged into `/usr` by `systemd-sysext`.
- The image lives on your data pool at `/mnt/<pool>/.config/cli-tools/`. A **PREINIT** script (registered with the TrueNAS middleware) re-activates it on every boot, so it survives reboots and the `/usr` wipe that comes with TrueNAS updates.
- apt-sourced tools are bundled with their shared libraries in a private directory (`/usr/lib/cli-tools/lib`) and an `rpath`, so they're fully self-contained and never shadow the host's system libraries. See [docs/architecture.md](docs/architecture.md).

## License

**MIT** ([LICENSE](LICENSE)) for all code in this repository (scripts, workflows).

The bundled tools are redistributed under their own upstream open-source licenses (GPL, MIT, BSD, etc.). This repository ships no proprietary binaries.

## Credits

Project structure, build pipeline, and install/persistence scripts adapted from the other [truenas-community-sysexts](https://github.com/truenas-community-sysexts) repos (coral-pcie-support, hailo8-support).
