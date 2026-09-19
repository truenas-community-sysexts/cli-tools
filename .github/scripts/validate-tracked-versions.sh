#!/usr/bin/env bash
# Validate that .github/tracked-versions.json has the shape the rest of the
# CI machinery assumes: build.yml and check-releases.yml read `debian` and
# `tools`; build.yml and promote.yml read the `trains` list.
#
# Run locally:
#   .github/scripts/validate-tracked-versions.sh
# Exits non-zero with a `::error::` annotation on any shape violation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="${REPO_ROOT}/.github/tracked-versions.json"

if [ ! -f "$FILE" ]; then
  echo "::error title=tracked-versions::file not found: ${FILE}" >&2
  exit 1
fi

python3 - "$FILE" <<'PY'
import json
import re
import sys

path = sys.argv[1]

def fail(msg):
    print(f"::error title=tracked-versions::{msg}", file=sys.stderr)
    sys.exit(1)

try:
    with open(path) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    fail(f"invalid JSON in {path}: {e}")

if not isinstance(data, dict):
    fail("top-level value must be an object")

# --- debian.suite: the Debian release the apt-sourced tools are pulled from.
# Pin to the OLDEST Debian base among supported TrueNAS versions: a binary
# built against an older glibc runs on newer glibc, but not vice versa.
debian = data.get("debian")
if not isinstance(debian, dict):
    fail("'debian' key missing or not an object")
suite = debian.get("suite")
suite_re = re.compile(r"^[a-z]+$")
if not isinstance(suite, str) or not suite_re.match(suite):
    fail(f"'debian.suite' missing or malformed (got {suite!r}); expected a Debian codename e.g. bookworm")

# --- trains: every TrueNAS train a release supports. build.yml opens one
# hardware-test issue per train for each release, and promote.yml writes
# `verified-train: <key>` into the release notes when one closes as completed.
trains = data.get("trains")
if not isinstance(trains, list) or not trains:
    fail("'trains' missing or not a non-empty list")
keys, names = set(), set()
for i, t in enumerate(trains):
    where = f"trains[{i}]"
    if not isinstance(t, dict):
        fail(f"{where} is not an object")
    key = t.get("key")
    # Shape only. That each key is one get.sh's truenas_train_key can
    # produce is tested against the shell function itself
    # (tests/test_release_selection.py), so the rule lives in one place.
    if not isinstance(key, str) or not re.match(r"^\d+(\.\d+)?$", key):
        fail(f"{where}.key missing or malformed (got {key!r}); expected e.g. 25.10 or 26")
    if key in keys:
        fail(f"{where}.key {key!r} is listed twice")
    keys.add(key)
    name = t.get("name")
    if not isinstance(name, str) or not name.strip():
        fail(f"{where}.name missing or empty (got {name!r}); expected e.g. 'TrueNAS 25.10'")
    if name in names:
        fail(f"{where}.name {name!r} is listed twice (issue titles and the duplicate check use it)")
    names.add(name)
    channel = t.get("channel")
    if channel not in ("stable", "preview"):
        fail(f"{where}.channel must be 'stable' or 'preview' (got {channel!r})")

# --- tools: map of tool-name -> source descriptor.
tools = data.get("tools")
if not isinstance(tools, dict) or not tools:
    fail("'tools' key missing, not an object, or empty")

VALID_SOURCES = {"github", "url", "apt"}
name_re = re.compile(r"^[a-z0-9][a-z0-9-]*$")

for name, spec in tools.items():
    if not name_re.match(name):
        fail(f"tool name {name!r} malformed; expected lowercase [a-z0-9-]")
    if not isinstance(spec, dict):
        fail(f"tool {name!r}: value must be an object")

    source = spec.get("source")
    if source not in VALID_SOURCES:
        fail(f"tool {name!r}: 'source' must be one of {sorted(VALID_SOURCES)} (got {source!r})")

    binname = spec.get("bin")
    if not isinstance(binname, str) or not binname.strip():
        fail(f"tool {name!r}: 'bin' (resulting command name) missing or empty")

    if source == "github":
        for key in ("repo", "version", "asset"):
            val = spec.get(key)
            if not isinstance(val, str) or not val.strip():
                fail(f"tool {name!r}: github source requires non-empty '{key}'")
        if "/" not in spec["repo"]:
            fail(f"tool {name!r}: 'repo' must be owner/name (got {spec['repo']!r})")
    elif source == "url":
        for key in ("version", "url"):
            val = spec.get(key)
            if not isinstance(val, str) or not val.strip():
                fail(f"tool {name!r}: url source requires non-empty '{key}'")
        if not spec["url"].startswith("https://"):
            fail(f"tool {name!r}: 'url' must be https (got {spec['url']!r})")
    elif source == "apt":
        pkg = spec.get("package")
        if not isinstance(pkg, str) or not pkg.strip():
            fail(f"tool {name!r}: apt source requires non-empty 'package'")

    # Optional 'links': extra command-name symlinks {linkname: target}.
    links = spec.get("links")
    if links is not None:
        if not isinstance(links, dict) or not links:
            fail(f"tool {name!r}: 'links' must be a non-empty object of name->target")
        for ln, tgt in links.items():
            if not isinstance(ln, str) or not ln.strip() or not isinstance(tgt, str) or not tgt.strip():
                fail(f"tool {name!r}: 'links' entries must be non-empty strings (got {ln!r}: {tgt!r})")

n = len(tools)
apt = sum(1 for s in tools.values() if s.get("source") == "apt")
dl = n - apt
summary = ", ".join(f"{t['key']} ({t['channel']})" for t in trains)
print(f"tracked-versions OK: {n} tools ({dl} prebuilt, {apt} apt) on Debian {suite}; trains {summary}")
PY
