# Troubleshooting

Start with the built-in probe — it reports most of the issues below:

```bash
sudo ./install.sh --check
```

## A tool isn't on `PATH`

1. Is the sysext merged? `systemd-sysext list` should show `cli-tools`.
2. If not, re-merge: `sudo systemd-sysext refresh` (or reboot — the PREINIT
   script does this automatically).
3. Confirm the command is actually in the bundle:
   `cat /usr/lib/cli-tools/manifest.txt`. Tools that already ship with TrueNAS
   are intentionally not included.

## The tools disappear after a reboot

The PREINIT script re-activates the sysext on boot. If they're gone:

1. `sudo ./install.sh --check` — look at the "PREINIT script registered" and
   "PREINIT completed successfully this boot" lines.
2. Inspect the boot log: `journalctl -b -t cli-tools-preinit`.
3. Confirm the persistent copy exists: `ls /mnt/*/.config/cli-tools/`.
4. If the registration is missing, re-run `install.sh`.

## The tools disappear after a TrueNAS update

This is expected mid-update (`/usr` is reset) and the PREINIT script restores
them on the next boot. If they don't come back, re-run `install.sh` — the
persistent copy on the data pool is unaffected by updates.

## `install.sh` can't pick a pool

With multiple data pools and no existing config, the installer needs to be told
where to persist:

```bash
sudo ./install.sh --pool=<your-pool>
```

The path must be `/mnt/<pool>/.config/cli-tools` (what the boot-time PREINIT
script scans). `--persist-path` enforces this shape.

## A bundled tool fails to start with a library error

The apt-sourced tools carry their own libraries under
`/usr/lib/cli-tools/lib` with an `rpath`, so this should not happen. If it
does, it usually means the tool was built against a glibc newer than the
host's. Check `debian.suite` in `tracked-versions.json` — it should be the
*oldest* Debian base among the TrueNAS versions you run. Verify with:

```bash
ldd /usr/bin/<tool>     # nothing should say "not found"
```

## A new build won't publish / `check-releases` fails to push

Pushing `tracked-versions.json` back to `main` needs the `CHECK_BUILDS` secret
(a PAT allowed to bypass the branch ruleset). See [build.md](build.md#automated-updates).
