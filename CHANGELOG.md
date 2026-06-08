# Changelog

All notable changes to this project are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Releases are versioned by build date and CI run (`v<YYYY.MM.DD>-r<run>`) rather
than a semantic version, because the artifact is a moving bundle of upstream
tools rather than a single versioned product. The exact tool versions in each
release are listed in that release's notes.

## [Unreleased]

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
