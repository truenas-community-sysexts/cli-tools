# Build Guide

All builds happen in GitHub Actions. There's no local build step (the tools are
fetched/packaged, not compiled here), though you can reproduce it locally with
Docker if you want.

## The pipeline

`.github/workflows/build.yml` has three jobs:

1. **resolve**: reads `debian.suite` from `.github/tracked-versions.json`
   (or the `suite` input).
2. **build**: runs in a `debian:<suite>-slim` container and:
   - fetches the prebuilt static tools (`source: github` / `source: url`),
   - `apt-get install`s the Debian tools (`source: apt`) and bundles each one
     self-contained via `.github/scripts/bundle-apt-tool.sh`,
   - writes the `extension-release`, the command `manifest.txt`, and a
     `versions.txt`, and bundles `cli-tools-preinit.sh`,
   - packs `cli-tools.raw` with `mksquashfs … -comp zstd -all-root`,
   - smoke-tests the image (extension-release valid, preinit present, every
     manifest command is an executable, best-effort `--version`),
   - uploads the artifact.
3. **release**: publishes a GitHub **pre-release** with `cli-tools.raw`, its
   `.sha256`, `install.sh`, `uninstall.sh`, `restore.sh` and
   `cli-tools-lib.sh` (everything `get.sh` downloads), then opens one
   hardware-test issue per TrueNAS train in `tracked-versions.json` (see
   [Per-train approval](#per-train-approval)).

Trigger a build manually from the Actions tab (**Build cli-tools Sysext** →
*Run workflow*). Every build, manual or automatic, starts as a pre-release:
there is no publish-straight-to-Latest option.

## Per-train approval

A hardware test on a TrueNAS train approves a release for that train's boxes
only. `tracked-versions.json` lists the supported trains:

```jsonc
"trains": [
  { "key": "25.10", "name": "TrueNAS 25.10", "channel": "stable" },
  { "key": "26", "name": "TrueNAS 26 beta", "channel": "preview" }
]
```

`key` is the train `get.sh` derives from the TrueNAS version (the major version
from 26 on, major.minor before that), `name` goes into issue titles, and
`channel` picks the label: `hardware-test` for a stable train,
`preview-hardware-test` for a preview one.

- **build.yml** opens one issue per train, titled e.g.
  `Hardware test: cli-tools <date> | any TrueNAS 25.10 system, no special hardware | <tag>`,
  with `<!-- release-tag -->` and `<!-- train -->` markers. It skips a train
  that already has an open issue for the tag.
- **promote.yml**: closing a train's issue as completed appends
  `<!-- verified-train: <key> -->` to the release notes. On the release's
  first approval the same update also turns the pre-release into a full
  release and appends the changelog. GitHub's "Latest" follows the newest
  release approved for a stable train, but nothing selects by it.
- **get.sh** (and `install.sh`/`uninstall.sh` run on their own) install the
  newest release whose notes carry the box's train, or a full release with no
  marker at all (from before per-train approval, so approved for every train).

Why there is no publish-straight-to-Latest option: a full release without
markers counts as approved for every train, so it would reach every box
untested.

When TrueNAS 26.0 ships, add `26` as a stable train and move the preview entry
on to the next beta.

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

The shape (including `trains`, see [Per-train approval](#per-train-approval))
is enforced by `.github/scripts/validate-tracked-versions.sh` in the lint
workflow.

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
`tracked-versions.json`, pushes the change, and dispatches `build.yml`. That
build publishes a pre-release and opens one hardware-test issue per train.
Closing a train's issue as completed after testing on that train approves the
release for it (promote.yml).

- `apt` tools are **not** polled - they float with the pinned Debian suite and
  refresh on every rebuild.
- `url` tools (no release API) are bumped manually.

Pushing to `main` from this workflow requires a `CHECK_BUILDS` repository secret
(a PAT for an actor allowed to bypass the branch ruleset); the default
`GITHUB_TOKEN` is used for read-only API calls.
