# CLI Tools Sysext for TrueNAS SCALE

A [systemd-sysext](https://www.freedesktop.org/software/systemd/man/systemd-sysext.html) package that adds a curated set of common command-line utilities to TrueNAS SCALE — the tools you reach for over SSH that aren't in the stock image — without modifying the immutable root filesystem.

Everything is merged into `/usr` at boot and survives reboots and TrueNAS updates. Because these are plain userspace binaries (not kernel modules), **one release works on every TrueNAS version**.

## Documentation

| Doc | Contents |
| --- | --- |
| [Quick Start](#quick-start) | Install, verify, uninstall |
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

Tools that already ship with TrueNAS SCALE (e.g. `htop`, `smartctl`, `nvme`, `tcpdump`, `iperf3`, `rsync`, `rclone`, `restic`, `jq`, `git`, `vim`, `tmux`) are intentionally **not** bundled.

## Quick Start

### Prerequisites

- TrueNAS SCALE 25.10 or newer
- Root/sudo access
- A data pool (for persistent storage) and internet access (to download the release)

### Install

Downloads the latest release and sets up persistence:

```bash
curl -fsSL https://github.com/truenas-community-sysexts/cli-tools/releases/latest/download/install.sh | sudo bash
```

With an explicit pool for persistence:

```bash
curl -fsSL https://github.com/truenas-community-sysexts/cli-tools/releases/latest/download/install.sh -o install.sh
sudo bash install.sh --pool=fast
```

### Verify

```bash
curl -fsSL https://github.com/truenas-community-sysexts/cli-tools/releases/latest/download/install.sh | sudo bash -s -- --check
```

Or just run one of the tools: `btop`, `tree`, `nmap --version`.

### Uninstall

```bash
curl -fsSL https://github.com/truenas-community-sysexts/cli-tools/releases/latest/download/uninstall.sh | sudo bash
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
