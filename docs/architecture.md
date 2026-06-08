# Architecture

## What a sysext is

A systemd system extension (sysext) is a disk image whose `/usr` (and `/opt`)
tree is overlaid onto the running system's `/usr` via an `overlayfs` mount, set
up by `systemd-sysext`. It's the supported way to add software to an immutable
OS like TrueNAS SCALE without touching the read-only root.

A sysext is recognized by a marker file,
`usr/lib/extension-release.d/extension-release.<name>`. We set its contents to
`ID=_any` so the extension is accepted regardless of the host's `os-release`
`ID` (TrueNAS's ID is not `debian`).

> **Only `/usr` and `/opt` are merged.** Files a sysext places under `/etc`,
> `/var`, `/bin`, or `/lib` are ignored. Everything we ship therefore lives
> under `/usr` — binaries in `/usr/bin` and `/usr/sbin`, private libraries and
> data under `/usr/lib/cli-tools` and `/usr/share`.

## Layout of `cli-tools.raw`

```
usr/
├── bin/                         # headline tools (btop, ncdu, yq, tree, mtr, nmap, ...)
├── sbin/                        # tools Debian ships in sbin (iotop, iftop, nethogs)
├── lib/
│   ├── cli-tools/
│   │   ├── lib/                 # private shared libs for the apt-sourced tools
│   │   ├── cli-tools-preinit.sh # bundled so install.sh can extract it
│   │   ├── manifest.txt         # one command name per line (used by --check)
│   │   └── versions.txt         # human-readable tool/version record
│   └── extension-release.d/
│       └── extension-release.cli-tools   # ID=_any
└── share/                       # runtime data files some tools need (e.g. nmap)
```

## Two kinds of tools

### Prebuilt static binaries (`btop`, `ncdu`, `yq`)

Downloaded from the upstream project's own release as a static (musl/Zig/Go)
binary and dropped straight into `/usr/bin`. No libraries to bundle — they
have no external dynamic dependencies.

### Debian-packaged tools (`iotop`, `iftop`, `nethogs`, `tree`, `mtr`, `nmap`)

These are dynamically linked, so we make them self-contained at build time
(`.github/scripts/bundle-apt-tool.sh`):

1. The package is `apt-get install`ed inside a Debian container whose release
   is pinned in `tracked-versions.json` (`debian.suite`).
2. Every ELF binary the package ships under `bin`/`sbin` is copied into the
   sysext (normalizing the usr-merge symlink roots to real `/usr/bin`,
   `/usr/sbin`).
3. Each binary's shared-library closure (`ldd`) is copied into a **private**
   directory, `/usr/lib/cli-tools/lib`, **excluding the glibc core and the
   dynamic loader** — those are resolved from the host.
4. An `rpath` is set so the binary loads its bundled libraries:
   - on the binary: `$ORIGIN/../lib/cli-tools/lib`
   - on each bundled library: `$ORIGIN` (so transitive deps resolve regardless
     of `DT_RPATH` vs `DT_RUNPATH` loader semantics)
5. Package-owned runtime data under `/usr/share` (e.g. `nmap`'s service/OS
   databases) is copied in; docs/man/locale are skipped.

### Why the private-lib + rpath approach

Dropping these libraries into the standard `/usr/lib/x86_64-linux-gnu` would
**shadow the host's own libraries** through the overlay and could destabilize
base TrueNAS tools that link the same sonames. Isolating them under a private
directory with an `rpath` means only our bundled tools see them; the host is
untouched.

### Why build on the *oldest* supported Debian base

We never bundle glibc or the dynamic loader (doing so risks an ABI split with
the host loader). The bundled binaries therefore link against the host's glibc
at runtime. A binary built against an older glibc runs fine on a newer one, but
not the reverse — so we pin `debian.suite` to the oldest Debian base among
supported TrueNAS versions. This is also why a single release is
kernel/version-independent and `install.sh` always fetches "latest".

## Boot-time activation

`/run/extensions` is tmpfs and `/usr` is reset on TrueNAS updates, so the
persistent copy lives on the data pool and a PREINIT script re-activates it
every boot. See [install.md](install.md#persistence-model).

## Build & release pipeline

See [build.md](build.md). In short: `resolve` reads the tracked suite →
`build` assembles the tree in a Debian container and smoke-tests the squashfs →
`release` publishes the GitHub release. A daily job bumps upstream tool
versions and triggers an unverified build gated behind a hardware-test issue.
