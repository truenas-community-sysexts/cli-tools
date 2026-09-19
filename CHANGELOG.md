# Changelog

All notable changes to this project are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Releases are versioned by build date and CI run (`v<YYYY.MM.DD>-r<run>`) rather
than a semantic version, because the artifact is a moving bundle of upstream
tools rather than a single versioned product. The exact tool versions in each
release are listed in that release's notes.

## [Unreleased]

### Changed
- **Releases are approved per TrueNAS train, and nothing unapproved is
  installed.** The new one-liner is `curl -fsSL .../main/get.sh | sudo bash`
  (uninstall: `... | sudo bash -s -- --uninstall`). It derives the train from
  the TrueNAS version (the major from 26 on, so every 26.x including betas is
  `26`; major.minor before that, e.g. `25.10`), picks the newest release
  approved for that train, and runs that release's `install.sh` (or
  `uninstall.sh`) with the release's `cli-tools-lib.sh` (and `restore.sh`)
  beside it. Approved means the release notes carry
  `<!-- verified-train: <train> -->`, or it is a full release with no such
  marker (every release from before this change, so `v2026.08.21-r11` stays
  the release on both 25.10 and 26 until a newer one is approved). With
  nothing approved for the train it stops and links the open hardware tests.
  `--release=TAG` pins any release.
- **`install.sh` has a `--release=TAG` flag**, and without it (and without a
  local image) downloads `cli-tools.raw` and `cli-tools-lib.sh` from the
  newest release approved for the box's train instead of GitHub's Latest.
  `get.sh` passes `--release=<tag>`; for a release whose `install.sh` predates
  the flag (r11 and older) it downloads and checks that release's
  `cli-tools.raw` itself and hands it over as a local image.
- **`uninstall.sh` piped to bash** fetches `restore.sh` and
  `cli-tools-lib.sh` from the newest approved release instead of Latest, and a
  failed lib download now stops it.
- **One hardware-test issue per train.** `build.yml` opens an issue per train
  in `tracked-versions.json` (`hardware-test` for TrueNAS 25.10,
  `preview-hardware-test` for the TrueNAS 26 beta), each naming its train in
  the title and body, with test steps that install through `get.sh
  --release=<tag>`. Closing one as completed approves the release for that
  train only (`promote.yml` adds the marker); the first approval also turns
  the pre-release into a full release and appends the changelog. GitHub's
  "Latest" now follows the newest release approved for a stable train and is
  cosmetic. Issues from before this change (no train marker) promote exactly
  as before.
- **`build.yml` no longer has the `mark_latest` input** (and `check-releases.yml`
  no longer passes it). A full release without markers is approved for every
  train, so publishing one straight to Latest would reach every box untested.
  Every release now starts as a pre-release.
- `tracked-versions.json` lists the supported `trains`;
  `validate-tracked-versions.sh` checks them. Lint runs unit tests for the
  release selection, `get.sh`, `promote.yml` and the hardware-test issues.

### Added
- Initial scaffold of the `cli-tools` sysext.
- Build pipeline (`build.yml`) that assembles a `cli-tools.raw` sysext from a
  mix of upstream prebuilt static binaries (`btop`, `ncdu`, `yq`) and
  Debian-packaged tools (`iotop`, `iftop`, `nethogs`, `tree`, `mtr`, `nmap`),
  with apt tools made self-contained via private-lib + `rpath` bundling.
- Daily upstream-version check (`check-releases.yml`) that auto-bumps
  github-sourced tools and triggers an unverified build for hardware testing.
- `install.sh` / `uninstall.sh` / `restore.sh` with `--check` and `--dry-run`,
  data-pool persistence, and PREINIT registration via `midclt`.
- Lint workflow: shellcheck, actionlint, and tracked-versions schema validation.
- Docs: install, build, architecture, troubleshooting.
