# Build Guide

All builds happen in GitHub Actions. There's no local build step (the tools are
fetched/packaged, not compiled here), though you can reproduce it locally with
Docker if you want.

## The pipeline

`.github/workflows/build.yml` has three jobs:

1. **resolve** — reads `debian.suite` and the `mark_latest` input from
   `.github/tracked-versions.json` / workflow inputs.
2. **build** — runs in a `debian:<suite>-slim` container and:
   - fetches the prebuilt static tools (`source: github` / `source: url`),
   - `apt-get install`s the Debian tools (`source: apt`) and bundles each one
     self-contained via `.github/scripts/bundle-apt-tool.sh`,
   - writes the `extension-release`, the command `manifest.txt`, and a
     `versions.txt`, and bundles `cli-tools-preinit.sh`,
   - packs `cli-tools.raw` with `mksquashfs … -comp zstd -all-root`,
   - smoke-tests the image (extension-release valid, preinit present, every
     manifest command is an executable, best-effort `--version`),
   - uploads the artifact.
3. **release** — publishes a GitHub release with `cli-tools.raw`, its
   `.sha256`, and the install scripts. `make_latest` is controlled by the
   `mark_latest` input.

Trigger a build manually from the Actions tab (**Build cli-tools Sysext** →
*Run workflow*). Leave `mark_latest=true` for a verified manual build.

## The source of truth: `tracked-versions.json`

```jsonc
{
  "debian": { "suite": "bookworm" },     // apt tools are built against this
  "tools": {
    "btop": { "source": "github", "repo": "aristocratos/btop",
              "version": "v1.4.4", "asset": "btop-x86_64-linux-musl.tbz",
              "extract": "btop/bin/btop", "bin": "btop" },
    "ncdu": { "source": "url", "version": "2.6",
              "url": "https://dev.yorhel.nl/download/ncdu-2.6-linux-x86_64.tar.gz",
              "extract": "ncdu", "bin": "ncdu" },
    "tree": { "source": "apt", "package": "tree", "bin": "tree" }
  }
}
```

Source types:

| `source` | Required fields | How it's fetched |
| --- | --- | --- |
| `github` | `repo`, `version`, `asset`, `bin`; optional `extract` | `https://github.com/<repo>/releases/download/<version>/<asset>` |
| `url` | `version`, `url`, `bin`; optional `extract` | direct download of `url` |
| `apt` | `package`, `bin` | `apt-get install` in the suite container, then bundled |

If `extract` is omitted, the downloaded file *is* the binary. Otherwise it's an
archive (`.tbz`/`.tar.gz`/`.tar.xz`/`.zip`) and `extract` is the path of the
binary inside it.

The shape is enforced by `.github/scripts/validate-tracked-versions.sh` in the
lint workflow.

## Adding a tool

1. Confirm it isn't already in TrueNAS (`command -v <tool>` on the box).
2. Add an entry to `tracked-versions.json`:
   - **Prefer `github`/`url`** if upstream ships a static amd64 binary.
   - Otherwise use `apt` with the Debian package name (note the package name
     may differ from the command, e.g. `iotop-c` provides `iotop`,
     `mtr-tiny` provides `mtr`).
3. Run the lint workflow (or `validate-tracked-versions.sh`) to check the shape.
4. Trigger a build and verify on hardware.

Some apt packages ship more than one binary (e.g. `mtr-tiny` also installs
`mtr-packet`). The bundler copies every binary the package owns and adds each to
the manifest, so they all end up on `PATH`.

## Automated updates

`.github/workflows/check-releases.yml` runs daily. For each `github` tool it
queries the latest upstream release; if newer than tracked, it bumps
`tracked-versions.json`, pushes the change, and dispatches `build.yml` with
`mark_latest=false`. That build publishes a release but does **not** mark it
latest, and opens a `hardware-test` issue. After verifying on real hardware,
promote the release to *Latest* and close the issue.

- `apt` tools are **not** polled — they float with the pinned Debian suite and
  refresh on every rebuild.
- `url` tools (no release API) are bumped manually.

Pushing to `main` from this workflow requires a `CHECK_BUILDS` repository secret
(a PAT for an actor allowed to bypass the branch ruleset); the default
`GITHUB_TOKEN` is used for read-only API calls.
