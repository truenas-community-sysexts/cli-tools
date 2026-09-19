#!/usr/bin/env bash
# Installs the pre-built cli-tools.raw sysext on a running TrueNAS system.
# The sysext bundles a set of common CLI utilities (htop-style monitors,
# network tools, etc.) that aren't shipped in the stock TrueNAS image, and
# merges them into /usr so they land on PATH.
#
# All assembly happens on GitHub Actions; this script only downloads and
# activates the pre-built cli-tools.raw. Because the tools are plain userspace
# binaries (not kernel modules), one release works on every TrueNAS version,
# but a hardware test approves it per TrueNAS train. Without --release (or a
# local image) the installer downloads the newest release approved for this
# box's train, and stops if there is none.
#
# Usage: curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/cli-tools/main/get.sh | sudo bash
#        (get.sh picks the approved release and runs its install.sh)
#    or: sudo ./install.sh [path-to-cli-tools.raw]
#    or: sudo ./install.sh --release=v2026.08.21-r11
#    or: sudo ./install.sh --pool=fast
#    or: sudo ./install.sh --check          (probe an existing install)
#    or: sudo ./install.sh --dry-run        (validate without modifying)
# See --help for the full option list.

set -euo pipefail

# do_check: read-only probe of an existing install. Exits 0 if all checks
# pass (warnings allowed), 1 if any check fails. Used by --check.
do_check() {
    local pass=0 warn=0 fail=0
    local mark_ok="OK" mark_warn="!!" mark_fail="XX"
    local -a status_lines=()
    local -a hint_lines=()

    record_pass() { status_lines+=("  [${mark_ok}] $1"); pass=$((pass+1)); }
    record_warn() {
        status_lines+=("  [${mark_warn}] $1"); warn=$((warn+1))
        [ -n "${2:-}" ] && hint_lines+=("    -> $2")
    }
    record_fail() {
        status_lines+=("  [${mark_fail}] $1"); fail=$((fail+1))
        [ -n "${2:-}" ] && hint_lines+=("    -> $2")
    }

    echo "=== cli-tools install status ==="
    echo ""

    # 1. Activation symlink present and resolves to an image. It lives on tmpfs
    # (/run/extensions), so the PREINIT script recreates it on every boot; a
    # missing symlink is a warning, not a hard failure.
    if [ -L /run/extensions/cli-tools.raw ] && [ -f /run/extensions/cli-tools.raw ]; then
        record_pass "Activation symlink /run/extensions/cli-tools.raw resolves to an image"
    else
        record_warn "Activation symlink /run/extensions/cli-tools.raw missing or dangling" \
            "the PREINIT script recreates it on boot; reboot or re-run install.sh"
    fi

    # 2. Sysext merged into /usr
    if systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx cli-tools; then
        record_pass "Sysext merged into /usr"
    else
        record_warn "Sysext not currently merged" \
            "the PREINIT script merges it on boot; check 'systemctl status systemd-sysext'"
    fi

    # 3. Bundled tools on PATH. The build writes a manifest listing every
    # command in the sysext; verify each resolves now that /usr is merged.
    local manifest="/usr/lib/cli-tools/manifest.txt"
    if [ -f "$manifest" ]; then
        local missing="" tool
        while IFS= read -r tool; do
            [ -z "$tool" ] && continue
            command -v "$tool" >/dev/null 2>&1 || missing="${missing:+${missing}, }${tool}"
        done < "$manifest"
        if [ -z "$missing" ]; then
            record_pass "All bundled tools resolve on PATH"
        else
            record_fail "Tools not found on PATH: ${missing}" \
                "is the sysext merged? check 'systemd-sysext status'"
        fi
    else
        record_warn "Manifest /usr/lib/cli-tools/manifest.txt not found" \
            "the sysext may not be merged, or predates the manifest; reboot or re-run install.sh"
    fi

    # 4. Persistent config dir (same resolver as install path)
    local persist_dir=""
    if resolve_persist_dir; then
        persist_dir="$PERSIST_DIR"
        record_pass "Persistent config at ${persist_dir}"
    else
        record_fail "No persistent config resolved" \
            "re-run install.sh with --pool=NAME or --persist-path=PATH"
    fi

    # 5. Backup cli-tools.raw on persistent pool
    if [ -n "$persist_dir" ] && [ -f "${persist_dir}/cli-tools.raw" ]; then
        record_pass "Backup ${persist_dir}/cli-tools.raw present"
    elif [ -n "$persist_dir" ]; then
        record_fail "Backup cli-tools.raw missing in ${persist_dir}" "re-run install.sh"
    fi

    # 6. PREINIT script on disk
    if [ -n "$persist_dir" ] && [ -x "${persist_dir}/cli-tools-preinit.sh" ]; then
        record_pass "PREINIT script ${persist_dir}/cli-tools-preinit.sh present and executable"
    elif [ -n "$persist_dir" ]; then
        record_fail "PREINIT script missing or not executable in ${persist_dir}" "re-run install.sh"
    fi

    # 7. PREINIT registered with TrueNAS middleware (read-only midclt query)
    if command -v midclt >/dev/null 2>&1; then
        local lookup script_when script_enabled
        lookup=$(cli_tools_init_script_lookup)
        case "$lookup" in
            error)
                record_warn "Could not query TrueNAS middleware" \
                    "run with sudo on TrueNAS SCALE"
                ;;
            "")
                record_fail "No init script registered for cli-tools" "re-run install.sh"
                ;;
            *)
                IFS='|' read -r _ script_when script_enabled <<<"$lookup"
                if [ "$script_when" = "PREINIT" ] && [ "$script_enabled" = "True" ]; then
                    record_pass "PREINIT script registered with TrueNAS middleware (PREINIT, enabled)"
                else
                    record_warn "Init script registered but not as enabled PREINIT" \
                        "re-run install.sh to fix"
                fi
                ;;
        esac
    else
        record_warn "midclt not available, skipping middleware check" \
            "this script must run on TrueNAS SCALE"
    fi

    # 8. PREINIT script result on last boot.
    if ! command -v journalctl >/dev/null 2>&1; then
        record_warn "journalctl not available, cannot read PREINIT result" \
            "this script must run on TrueNAS SCALE"
    else
        local preinit_log preinit_last
        preinit_log=$(journalctl -b -t cli-tools-preinit --no-pager -o cat 2>/dev/null || true)
        if [ -z "$preinit_log" ]; then
            record_warn "No cli-tools-preinit entries this boot" \
                "PREINIT may not be registered yet; reboot after install, or re-run install.sh"
        elif printf '%s' "$preinit_log" | grep -q '^WARNING:'; then
            preinit_last=$(printf '%s' "$preinit_log" | grep '^WARNING:' | head -1)
            record_warn "PREINIT logged a warning this boot: ${preinit_last}" \
                "see full log: journalctl -b -t cli-tools-preinit"
        else
            preinit_last=$(printf '%s' "$preinit_log" | tail -1)
            if [ "$preinit_last" = "Done" ]; then
                record_pass "PREINIT completed successfully this boot"
            else
                record_warn "PREINIT ran but did not log the Done sentinel (last: ${preinit_last})" \
                    "review full log: journalctl -b -t cli-tools-preinit"
            fi
        fi
    fi

    printf '%s\n' "${status_lines[@]}"
    echo ""
    if [ "${#hint_lines[@]}" -gt 0 ]; then
        printf '%s\n' "${hint_lines[@]}"
        echo ""
    fi
    printf 'Summary: %d ok, %d warn, %d fail\n' "$pass" "$warn" "$fail"

    [ "$fail" -gt 0 ] && return 1
    return 0
}

# if_real: run a command unless --dry-run is set, in which case print what
# would have been run. For redirections and heredocs, gate the entire block
# manually since the shell evaluates redirections before the command runs.
if_real() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '[dry-run] would: %s\n' "$*"
    else
        "$@"
    fi
}

# resolve_persist_dir: determine where persistent config lives.
# Priority: --persist-path > --pool > existing config dir > only-data-pool
#         > interactive prompt (multi-pool) > error (no tty + ambiguous)
# Sets PERSIST_DIR on success; prints to stderr and returns 1 on failure.
resolve_persist_dir() {
    PERSIST_DIR=""
    local d p
    local -a existing=() pools=() choices=()
    local header n i

    if [ -n "${PERSIST_PATH:-}" ]; then
        PERSIST_DIR="$PERSIST_PATH"
        return 0
    fi
    if [ -n "${POOL_NAME:-}" ]; then
        PERSIST_DIR="/mnt/${POOL_NAME}/.config/cli-tools"
        return 0
    fi

    shopt -s nullglob
    for d in /mnt/*/.config/cli-tools; do
        [ -d "$d" ] && existing+=("$d")
    done
    shopt -u nullglob

    if [ "${#existing[@]}" -eq 1 ]; then
        PERSIST_DIR="${existing[0]}"
        echo "Re-using existing config: $PERSIST_DIR"
        return 0
    fi

    while IFS= read -r p; do
        [ -n "$p" ] && [ "$p" != "boot-pool" ] && pools+=("$p")
    done < <(zpool list -H -o name 2>/dev/null)

    if [ "${#existing[@]}" -eq 0 ] && [ "${#pools[@]}" -eq 0 ]; then
        echo "ERROR: No ZFS pool found (excluding boot-pool). Cannot set up persistence." >&2
        echo "  Re-run with --pool=<name> or --persist-path=/mnt/<pool>/<path>" >&2
        return 1
    fi

    if [ "${#existing[@]}" -eq 0 ] && [ "${#pools[@]}" -eq 1 ]; then
        PERSIST_DIR="/mnt/${pools[0]}/.config/cli-tools"
        echo "Auto-selected pool: ${pools[0]} -> $PERSIST_DIR"
        return 0
    fi

    if [ "${#existing[@]}" -gt 1 ]; then
        header="Found existing cli-tools configs on multiple pools:"
        choices=("${existing[@]}")
    else
        header="Multiple data pools available (no existing config):"
        for p in "${pools[@]}"; do
            choices+=("/mnt/${p}/.config/cli-tools")
        done
    fi

    if ! { : </dev/tty; } 2>/dev/null; then
        echo "ERROR: $header" >&2
        echo "  No controlling terminal. Pass --pool=<name> or --persist-path=<path>." >&2
        return 1
    fi

    echo "$header"
    for i in "${!choices[@]}"; do
        echo "  [$((i+1))] ${choices[$i]}"
    done
    while true; do
        printf 'Pick one (1-%d): ' "${#choices[@]}"
        read -r n </dev/tty || return 1
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#choices[@]}" ]; then
            PERSIST_DIR="${choices[$((n-1))]}"
            echo "Selected: $PERSIST_DIR"
            return 0
        fi
        echo "  Invalid. Enter 1-${#choices[@]}."
    done
}

# BEGIN approved-release (a verbatim copy lives in get.sh, scripts/install.sh
# and scripts/uninstall.sh, each a self-contained curl|bash script;
# tests/test_release_selection.py fails CI when the copies differ)

# TrueNAS version of this box, read from the middleware. Retried: midclt can
# be briefly unavailable right after boot.
detect_truenas_version() {
    local v i
    for i in 1 2 3; do
        v=$(midclt call system.info 2>/dev/null | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin)["version"])
except Exception:
    pass' 2>/dev/null) || true
        if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
        [ "$i" -lt 3 ] && sleep 1
    done
    return 1
}

# Train key of a TrueNAS version: the major version from 26 on (26.0.0-BETA.3
# and 26.1.2 are both train 26), major.minor before that (25.10.7 is 25.10,
# 25.04.2.6 is 25.04). Fails on anything else.
truenas_train_key() {
    local v="$1" major minor
    major="${v%%.*}"
    case "$major" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$major" -ge 26 ]; then
        printf '%s\n' "$major"
        return 0
    fi
    case "$v" in *.*) ;; *) return 1 ;; esac
    minor="${v#*.}"
    minor="${minor%%[!0-9]*}"
    [ -n "$minor" ] || return 1
    printf '%s.%s\n' "$major" "$minor"
}

# Every page of the repo's releases, appended to $1 as one JSON array per
# page. Only a full page can have more behind it; anything else (short page,
# API error object) ends the loop, and the selection reports API errors.
fetch_release_pages() {
    local out="$1" page=1 page_json page_len
    : > "$out"
    while :; do
        page_json=$(curl -sS --max-time 30 "https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}") \
            || { echo "ERROR: Failed to query GitHub releases" >&2; return 1; }
        printf '%s\n' "$page_json" >> "$out"
        page_len=$(printf '%s' "$page_json" | python3 -c "
import sys, json
try:
    doc = json.load(sys.stdin)
except Exception:
    print(0)
else:
    print(len(doc) if isinstance(doc, list) else 0)
")
        [ "$page_len" -eq 100 ] || break
        page=$((page + 1))
    done
}

# Newest release approved for train $2 on a box running TrueNAS $1, chosen
# from the release pages in $3. Prints its tag; explains on stderr and fails
# when there is none.
select_approved_release() {
    VERSION="$1" TRAIN="$2" REPO="$REPO" python3 -c "
# BEGIN release-selection (extracted verbatim by tests/test_release_selection.py;
# single-quoted strings only, \x60 stands for backtick, no dollar signs: this
# code lives inside a double-quoted bash string)
import sys, json, os, re
# stdin carries one JSON array per fetched API page, concatenated.
decoder = json.JSONDecoder()
text = sys.stdin.read()
data = []
pos = 0
while pos < len(text):
    if text[pos].isspace():
        pos += 1
        continue
    try:
        doc, pos = decoder.raw_decode(text, pos)
    except ValueError:
        print('Failed to parse GitHub API response', file=sys.stderr)
        sys.exit(1)
    if isinstance(doc, dict) and 'message' in doc:
        msg = doc['message']
        if 'rate limit' in msg.lower():
            print('GitHub API rate limit exceeded (60 requests/hour for unauthenticated calls).', file=sys.stderr)
            print('Wait a few minutes and try again.', file=sys.stderr)
        else:
            print(f'GitHub API error: {msg}', file=sys.stderr)
        sys.exit(1)
    elif isinstance(doc, list):
        data.extend(doc)
    else:
        print('Failed to parse GitHub API response', file=sys.stderr)
        sys.exit(1)
if not text.strip():
    print('Failed to parse GitHub API response', file=sys.stderr)
    sys.exit(1)
version = os.environ['VERSION']
train = os.environ['TRAIN']
repo = os.environ.get('REPO', '')
# The channel (preview on a BETA/RC box, else stable) no longer decides what
# installs: every box takes the newest release approved for its train. It
# only picks which hardware-test issues the no-match message points at.
vu = version.upper()
is_preview = ('-BETA' in vu) or ('-RC' in vu)
def preview_release(release):
    # This repo's v<date>-r<run> tags carry no BETA/RC marker (one release
    # serves every train), so this never fires here; it keeps the approval
    # gate below the same expression as in the per-kernel repos (coral,
    # hailo, memryx).
    tu = release.get('tag_name', '').upper()
    return ('-BETA' in tu) or ('-RC' in tu)
# Approval gate. promote.yml writes one verified-train line into the notes
# for each train whose hardware test signed the release off. A release with a
# line for this train is approved here; lines for other trains only are not.
# A full release with no line at all predates per-train sign-off and is
# grandfathered for every train. Nothing else qualifies: there is no fallback
# to an unverified build, on stable or preview boxes.
vt_re = re.compile(r'^[ \t]*<!--\s*verified-train:\s*([^\s>]+?)\s*-->', re.M)
def verified_trains(release):
    return set(vt_re.findall(release.get('body') or ''))
def approved(release):
    trains = verified_trains(release)
    if trains:
        return train in trains
    return not release.get('prerelease') and not preview_release(release)
def published(release):
    return release.get('published_at') or release.get('created_at') or ''
candidates = [r for r in data
              if not r.get('draft')
              and approved(r)]
if not candidates:
    print(f'No release is approved for TrueNAS train {train} yet (this box runs {version}).', file=sys.stderr)
    print('A hardware test on a train approves a release for that train only, and nothing', file=sys.stderr)
    print('unapproved is installed.', file=sys.stderr)
    pending = sorted([r for r in data if not r.get('draft')], key=published, reverse=True)
    if pending:
        print('Newest releases waiting for a hardware test on this train:', file=sys.stderr)
        for r in pending[:5]:
            t = r.get('tag_name', '?')
            mark = ' (prerelease)' if r.get('prerelease') else ''
            print(f'  {t}{mark}', file=sys.stderr)
    label = 'preview-hardware-test' if is_preview else 'hardware-test'
    print('Open hardware tests (each issue title names its train):', file=sys.stderr)
    print(f'  https://github.com/{repo}/issues?q=is%3Aissue+is%3Aopen+label%3A{label}', file=sys.stderr)
    sys.exit(1)
candidates.sort(key=published, reverse=True)
print(candidates[0]['tag_name'], end='')
# END release-selection
" < "$3"
}

# The release to use on this box when none is pinned with --release: the
# newest one approved for its train. Prints the tag.
approved_release_tag() {
    local version train pages tag
    version=$(detect_truenas_version) || {
        echo "ERROR: could not read the TrueNAS version (midclt call system.info)." >&2
        echo "       Run this as root on TrueNAS, or pin a release with --release=TAG." >&2
        return 1
    }
    train=$(truenas_train_key "$version") || {
        echo "ERROR: cannot derive a TrueNAS train from version '${version}'" >&2
        return 1
    }
    pages=$(mktemp) || return 1
    if fetch_release_pages "$pages" && tag=$(select_approved_release "$version" "$train" "$pages"); then
        rm -f "$pages"
        echo "TrueNAS ${version} (train ${train}): newest approved release is ${tag}" >&2
        printf '%s\n' "$tag"
        return 0
    fi
    rm -f "$pages"
    return 1
}
# END approved-release

# REPO can be overridden via --repo=OWNER/NAME or CLI_TOOLS_REPO env var.
REPO="${CLI_TOOLS_REPO:-truenas-community-sysexts/cli-tools}"
RELEASE_TAG=""        # --release=TAG; empty = newest release approved for this train
RESOLVED_TAG=""       # set by resolve_release_for_install
RELEASE_DL_BASE=""    # that release's asset download URL

# Decide which release supplies cli-tools.raw (and, when it is not beside
# this script, cli-tools-lib.sh). Sets RESOLVED_TAG and RELEASE_DL_BASE, once.
# An explicit --release is trusted verbatim; otherwise use the newest release
# a hardware test approved for this box's TrueNAS train, and stop when there
# is none (never an unapproved release, and never GitHub's Latest).
resolve_release_for_install() {
    [ -z "$RESOLVED_TAG" ] || return 0
    if [ -n "$RELEASE_TAG" ]; then
        RESOLVED_TAG="$RELEASE_TAG"
    else
        RESOLVED_TAG=$(approved_release_tag) || exit 1
    fi
    RELEASE_DL_BASE="https://github.com/${REPO}/releases/download/${RESOLVED_TAG}"
    echo "Release: ${RESOLVED_TAG}" >&2
}

# --- Parse CLI arguments ---
LOCAL_RAW=""
POOL_NAME=""
PERSIST_PATH=""
CHECK_MODE=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --repo=*)
            REPO="${arg#*=}"
            [ -n "$REPO" ] || { echo "ERROR: --repo= requires a non-empty value (e.g., --repo=owner/name)" >&2; exit 2; }
            ;;
        --pool=*)
            POOL_NAME="${arg#*=}"
            [ -n "$POOL_NAME" ] || { echo "ERROR: --pool= requires a non-empty value" >&2; exit 2; }
            ;;
        --persist-path=*)
            PERSIST_PATH="${arg#*=}"
            [ -n "$PERSIST_PATH" ] || { echo "ERROR: --persist-path= requires a non-empty value" >&2; exit 2; }
            ;;
        --release=*)
            RELEASE_TAG="${arg#*=}"
            [ -n "$RELEASE_TAG" ] || { echo "ERROR: --release= requires a tag (e.g., --release=v2026.08.21-r11)" >&2; exit 2; }
            ;;
        --check) CHECK_MODE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --help)
            echo "Usage: sudo ./install.sh [OPTIONS] [path-to-cli-tools.raw]"
            echo ""
            echo "Options:"
            echo "  --repo=OWNER/NAME             GitHub repo to download release from (default: truenas-community-sysexts/cli-tools)"
            echo "                                Can also be set via CLI_TOOLS_REPO env var."
            echo "  --pool=NAME                   ZFS pool for persistent config (e.g., fast)"
            echo "  --persist-path=PATH           Exact path for persistent config"
            echo "  --release=TAG                 Install this release (default: the newest release a hardware"
            echo "                                test approved for this box's TrueNAS train)"
            echo "  --check                       Probe an existing install (read-only) and report status"
            echo "  --dry-run                     Validate everything (downloads, checksums, network) without modifying the system"
            echo "  --help                        Show this help"
            echo ""
            echo "Examples:"
            echo "  sudo ./install.sh --pool=fast"
            echo "  sudo ./install.sh --check"
            echo "  sudo ./install.sh --dry-run"
            echo "  sudo ./install.sh /tmp/cli-tools.raw"
            echo "  sudo ./install.sh --release=v2026.08.21-r11"
            echo "  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/get.sh | sudo bash"
            exit 0
            ;;
        *)
            # A `curl | sudo bash` user who typos `--pol=fast` or `/tmp/typ.raw`
            # silently gets auto-detect / a release download. Refuse rather
            # than guess.
            if [ -f "$arg" ]; then
                LOCAL_RAW="$arg"
            elif [[ "$arg" == -* ]]; then
                echo "ERROR: unknown option: $arg (see --help)" >&2
                exit 2
            else
                echo "ERROR: positional argument is not an existing file: $arg" >&2
                echo "  Pass --help for usage." >&2
                exit 2
            fi
            ;;
    esac
done

if [ "$CHECK_MODE" = "1" ] && [ "$DRY_RUN" = "1" ]; then
    echo "ERROR: --check and --dry-run are mutually exclusive" >&2
    exit 2
fi

# Every mode past --help touches privileged state: writes under the data pool,
# midclt, systemd-sysext. Fail fast with a clear message.
if [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "ERROR: must run as root (use sudo)" >&2
    exit 1
fi

# Persistence only works if --persist-path is the exact location the boot-time
# PREINIT script scans: /mnt/<pool>/.config/cli-tools, a single pool component
# under /mnt. cli-tools-preinit.sh re-derives the dir by globbing
# /mnt/*/.config/cli-tools, so any other path silently breaks persistence after
# the next reboot or TrueNAS update.
if [ -n "$PERSIST_PATH" ]; then
    PERSIST_PATH_REAL=$(realpath -m "$PERSIST_PATH" 2>/dev/null || echo "$PERSIST_PATH")
    if [[ ! "$PERSIST_PATH_REAL" =~ ^/mnt/[^/]+/\.config/cli-tools/?$ ]]; then
        echo "ERROR: --persist-path must be /mnt/<pool>/.config/cli-tools (got: ${PERSIST_PATH})" >&2
        echo "  The boot-time PREINIT script only scans /mnt/*/.config/cli-tools for the backup," >&2
        echo "  so any other location silently breaks persistence after a reboot or update." >&2
        echo "  Pass --pool=<name> instead (it resolves to /mnt/<name>/.config/cli-tools)." >&2
        exit 2
    fi
fi

# Source shared library (provides cli_tools_init_script_lookup).
# Try the sibling file first (checkout, extracted release, or get.sh, which
# puts the release's copy there); fall back to downloading it from the
# release this install uses for the curl|bash case.
_source_cli_tools_lib() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || dir=""
    if [ -n "$dir" ] && [ -f "${dir}/cli-tools-lib.sh" ]; then
        # shellcheck source=scripts/cli-tools-lib.sh
        source "${dir}/cli-tools-lib.sh"
        return 0
    fi
    local tmp
    resolve_release_for_install
    tmp=$(mktemp /tmp/cli-tools-lib.XXXXXXXXXX)
    if curl -fsSL --max-time 30 \
           "${RELEASE_DL_BASE}/cli-tools-lib.sh" \
           -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        # shellcheck source=scripts/cli-tools-lib.sh
        source "$tmp"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}
_source_cli_tools_lib || {
    echo "ERROR: Could not load cli-tools-lib.sh (not found locally, download failed)." >&2
    echo "  Run from the release directory, or ensure network access to GitHub." >&2
    exit 1
}

if [ "$CHECK_MODE" = "1" ]; then
    do_check
    exit $?
fi

WORK_DIR=$(mktemp -d /tmp/cli-tools-install.XXXXXXXXXX)

cleanup() {
    [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# If a local path is provided, use it; otherwise download the release this
# install uses (--release, or the newest one approved for this train).
if [ -n "$LOCAL_RAW" ]; then
    # Reject input path == staging path: cp would refuse with "are the same
    # file" and the EXIT trap would then rm -rf the work dir, deleting the
    # user's input. Detect and refuse rather than risk data loss.
    LOCAL_REAL=$(realpath "$LOCAL_RAW" 2>/dev/null || echo "$LOCAL_RAW")
    STAGE_REAL=$(realpath -m "${WORK_DIR}/cli-tools.raw" 2>/dev/null || echo "${WORK_DIR}/cli-tools.raw")
    if [ "$LOCAL_REAL" = "$STAGE_REAL" ]; then
        echo "ERROR: input file collides with the installer's staging path." >&2
        echo "  Move or copy it to a different path and re-run." >&2
        exit 2
    fi
    echo "Using local cli-tools.raw: $LOCAL_RAW"
    cp "$LOCAL_RAW" "${WORK_DIR}/cli-tools.raw"
else
    # The tools are kernel-independent, so there is no kernel to match, but
    # the release must be one a hardware test approved for this train.
    resolve_release_for_install
    echo "Downloading cli-tools.raw from ${REPO} release ${RESOLVED_TAG}..."
    curl -fSL --max-time 600 "${RELEASE_DL_BASE}/cli-tools.raw" -o "${WORK_DIR}/cli-tools.raw" \
        || { echo "ERROR: Failed to download cli-tools.raw"; exit 1; }
    curl -fSL --max-time 600 "${RELEASE_DL_BASE}/cli-tools.raw.sha256" -o "${WORK_DIR}/cli-tools.raw.sha256" \
        || { echo "ERROR: Failed to download checksum"; exit 1; }

    [ -s "${WORK_DIR}/cli-tools.raw" ] || { echo "ERROR: cli-tools.raw is empty"; exit 1; }
    [ -s "${WORK_DIR}/cli-tools.raw.sha256" ] || { echo "ERROR: checksum file is empty"; exit 1; }

    echo "Verifying checksum..."
    # The .sha256 from the release names the file as built (cli-tools.raw),
    # which matches our staging filename, so `sha256sum -c` resolves it.
    if ! (cd "$WORK_DIR" && sha256sum -c cli-tools.raw.sha256); then
        echo "ERROR: Checksum verification failed!"
        exit 1
    fi
    echo "Checksum OK"
fi

# --- Extract PREINIT script from sysext ---
# The sysext bundles cli-tools-preinit.sh at usr/lib/cli-tools/cli-tools-preinit.sh.
# Extract it via unsquashfs (read-only) so the release artifact is self-contained.
echo ""
echo "=== Extracting PREINIT script from cli-tools.raw ==="

if ! command -v unsquashfs &>/dev/null; then
    echo "ERROR: unsquashfs not found, cannot extract PREINIT script from sysext"
    echo "  Install squashfs-tools: apt-get install squashfs-tools"
    exit 1
fi

unsquashfs -q -d "${WORK_DIR}/cli-tools-unpack" "${WORK_DIR}/cli-tools.raw" \
    usr/lib/cli-tools/cli-tools-preinit.sh

BUNDLED_PREINIT="${WORK_DIR}/cli-tools-unpack/usr/lib/cli-tools/cli-tools-preinit.sh"
if [ ! -f "$BUNDLED_PREINIT" ]; then
    echo "ERROR: cli-tools-preinit.sh not found in sysext at /usr/lib/cli-tools/cli-tools-preinit.sh" >&2
    echo "  Re-run the one-liner: curl -fsSL https://raw.githubusercontent.com/${REPO}/main/get.sh | sudo bash" >&2
    exit 1
fi
cp "$BUNDLED_PREINIT" "${WORK_DIR}/cli-tools-preinit.sh"
chmod +x "${WORK_DIR}/cli-tools-preinit.sh"
rm -rf "${WORK_DIR}/cli-tools-unpack"
echo "PREINIT script extracted"

echo ""
echo "=== Installing cli-tools.raw ==="

# --- Detect persistent storage pool ---
# The sysext image lives only on the data pool; /run/extensions points at it
# directly. Resolve the pool first so the blob is in place before we activate.
if ! resolve_persist_dir; then
    echo "ERROR: No persistent storage pool found; cannot install." >&2
    exit 1
fi
echo "Persistent config directory: ${PERSIST_DIR}"
if_real mkdir -p "$PERSIST_DIR"
CLI_TOOLS_RAW="${PERSIST_DIR}/cli-tools.raw"

# Write the sysext image to the data pool. This is the single copy we activate
# and the one that survives reboots and TrueNAS updates (no boot-pool copy).
echo "Installing cli-tools.raw to ${CLI_TOOLS_RAW}..."
if_real cp "${WORK_DIR}/cli-tools.raw" "${CLI_TOOLS_RAW}"

# Remove cli-tools from sysext before modifying. If nothing is currently merged,
# unmerge exits non-zero with "No extensions found" on stderr, which is fine.
# A real failure (overlay held open) must not be swallowed.
echo "Removing old cli-tools sysext symlink..."
if_real rm -f /run/extensions/cli-tools.raw
if [ "$DRY_RUN" != "1" ]; then
    UNMERGE_ERR=$(systemd-sysext unmerge 2>&1) || {
        if printf '%s' "$UNMERGE_ERR" | grep -qi "no extensions"; then
            true  # nothing was merged, harmless
        else
            echo "ERROR: systemd-sysext unmerge failed: ${UNMERGE_ERR}" >&2
            echo "  Another process may be holding the overlay open." >&2
            exit 1
        fi
    }
else
    echo "[dry-run] would: systemd-sysext unmerge"
fi

# Activate sysext via symlink + refresh (TrueNAS middleware pattern).
echo "Activating cli-tools sysext..."
if_real mkdir -p /run/extensions
if_real ln -sf "${CLI_TOOLS_RAW}" /run/extensions/cli-tools.raw
if_real systemd-sysext refresh
if_real ldconfig

echo ""
echo "=== Installation complete ==="

# ==========================================================================
# Persistence setup: survives reboots and TrueNAS updates
# ==========================================================================

echo ""
echo "=== Setting up persistence ==="

# Save source repo so future tooling can point users at the right releases page.
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would: write \$REPO (${REPO}) to ${PERSIST_DIR}/.cli-tools-repo"
else
    printf '%s' "$REPO" > "${PERSIST_DIR}/.cli-tools-repo"
fi

# --- Install PREINIT script to persistent storage ---
echo "Installing PREINIT script..."
if_real cp "${WORK_DIR}/cli-tools-preinit.sh" "${PERSIST_DIR}/cli-tools-preinit.sh"
if_real chmod +x "${PERSIST_DIR}/cli-tools-preinit.sh"

# --- Register PREINIT script via midclt ---
PREINIT_SCRIPT="${PERSIST_DIR}/cli-tools-preinit.sh"
echo "Registering PREINIT script..."

# A midclt lookup error is NOT the same as not-found: refuse rather than
# risk a duplicate registration that restore.sh's first-match cleanup
# won't fully undo.
EXISTING_LOOKUP=$(cli_tools_init_script_lookup)
if [ "$EXISTING_LOOKUP" = "error" ]; then
    echo "ERROR: Could not query TrueNAS middleware to check for existing init scripts." >&2
    echo "  Refusing to register without a clean lookup, risks duplicate PREINIT entries." >&2
    echo "  Run 'midclt call initshutdownscript.query' to confirm middleware health, then re-run." >&2
    exit 1
fi
EXISTING_ID="${EXISTING_LOOKUP%%|*}"

# Build the payload via python3 -> json.dumps so PREINIT_SCRIPT is escaped
# correctly even if the path ever grows JSON-special characters.
PREINIT_PAYLOAD=$(PREINIT_SCRIPT="$PREINIT_SCRIPT" python3 -c '
import json, os
print(json.dumps({
    "type": "COMMAND",
    "command": os.environ["PREINIT_SCRIPT"],
    "when": "PREINIT",
    "enabled": True,
    "timeout": 30,
    "comment": "Activate cli-tools sysext before apps start",
}))
')

if [ -n "$EXISTING_ID" ]; then
    echo "cli-tools init script already registered (id: ${EXISTING_ID}), updating to PREINIT..."
    if ! if_real midclt call initshutdownscript.update "$EXISTING_ID" "$PREINIT_PAYLOAD"; then
        echo "ERROR: Failed to update init script (id: ${EXISTING_ID})." >&2
        echo "ERROR: Without a registered PREINIT script the sysext will NOT survive a reboot." >&2
        echo "ERROR: Check 'midclt call initshutdownscript.query' and re-run the installer." >&2
        exit 1
    fi
else
    if ! if_real midclt call initshutdownscript.create "$PREINIT_PAYLOAD"; then
        echo "ERROR: Failed to register PREINIT script via midclt." >&2
        echo "ERROR: Without a registered PREINIT script the sysext will NOT survive a reboot." >&2
        echo "ERROR: Check that the TrueNAS middleware is reachable (midclt call core.ping) and re-run." >&2
        exit 1
    fi
    echo "PREINIT script registered"
fi

echo ""
echo "=== Persistence setup complete ==="
echo ""
echo "Persistent config: ${PERSIST_DIR}/"
echo "  cli-tools.raw            - sysext backup"
echo "  cli-tools-preinit.sh     - runs before apps start (registered as PREINIT)"
echo ""

# List the tools now available, read from the merged manifest.
if [ "$DRY_RUN" != "1" ] && [ -f /usr/lib/cli-tools/manifest.txt ]; then
    echo "Tools now on PATH:"
    paste -sd ' ' /usr/lib/cli-tools/manifest.txt | sed 's/^/  /'
    echo ""
fi
echo "The bundled tools will survive TrueNAS updates and reboots."

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "=== Dry-run complete ==="
    echo "No changes were made to the system."
    echo ""
    echo "Would have installed:"
    echo "  Sysext image:      ${CLI_TOOLS_RAW}"
    echo "  Persistent dir:    ${PERSIST_DIR}"
fi
