#!/usr/bin/env bash
# Bundle an apt-installed package's binaries into the cli-tools sysext tree,
# made self-contained so it runs on TrueNAS without installing anything there.
#
# Strategy (the "private-lib + rpath" pattern):
#   * Copy every ELF executable the package ships under {,/usr}/{bin,sbin}
#     into the sysext, normalizing /bin -> /usr/bin and /sbin -> /usr/sbin
#     (systemd-sysext only merges /usr, so binaries must live there).
#   * For each binary, walk its shared-library closure (ldd) and copy every
#     non-glibc library into a PRIVATE dir, /usr/lib/cli-tools/lib, then set
#     an rpath so the binary loads those copies instead of (possibly missing
#     or mismatched) host libraries. We deliberately do NOT bundle the glibc
#     core or the dynamic loader -- those are resolved from the host, which
#     is why the build runs on the oldest supported Debian base (forward-
#     compatible glibc).
#   * rpath is set on the binary ($ORIGIN/../lib/cli-tools/lib) AND on each
#     bundled library ($ORIGIN) so transitive deps resolve regardless of
#     whether the loader honors DT_RPATH or DT_RUNPATH semantics.
#   * Copy package-owned data under /usr/share (minus docs/man/locale) so
#     tools with runtime data files (e.g. nmap's nmap-services) work.
#
# Usage: bundle-apt-tool.sh <sysext_root> <package> <manifest_file>
# Must run on a Debian system matching the target (the package must already
# be apt-installed). Appends realized command names to <manifest_file>.

set -euo pipefail

SYSEXT_ROOT="${1:?usage: bundle-apt-tool.sh <sysext_root> <package> <manifest_file>}"
PACKAGE="${2:?missing package}"
MANIFEST="${3:?missing manifest file}"

PRIV_LIB_REL="usr/lib/cli-tools/lib"
PRIV_LIB="${SYSEXT_ROOT}/${PRIV_LIB_REL}"
mkdir -p "$PRIV_LIB"

# glibc core + dynamic loader: resolved from the host TrueNAS, never bundled.
# Bundling a second libc/loader risks an ABI split against the host loader.
is_glibc_core() {
    case "$1" in
        ld-linux-x86-64.so.*|ld-linux.so.*|libc.so.*|libm.so.*|libdl.so.*|\
        libpthread.so.*|librt.so.*|libresolv.so.*|libutil.so.*|libnss_*.so.*|\
        libBrokenLocale.so.*|libanl.so.*|linux-vdso.so.*) return 0 ;;
        *) return 1 ;;
    esac
}

is_elf() {
    # Read the 4-byte ELF magic without depending on `file`.
    local magic
    magic=$(head -c4 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n') || return 1
    [ "$magic" = "7f454c46" ]
}

# Bundle the shared-library closure of one ELF binary into the private dir.
bundle_libs_for() {
    local elf="$1" soname libpath
    # ldd prints "<soname> => <path> (0x...)" for resolved libs and
    # "<path> (0x...)" (no =>) for the loader/vdso. We only want the former.
    while read -r soname _arrow libpath _rest; do
        [ "$_arrow" = "=>" ] || continue
        [ -n "$libpath" ] || continue
        [ "$libpath" = "not" ] && continue   # "not found" -- surfaced below
        is_glibc_core "$soname" && continue
        if [ ! -e "${PRIV_LIB}/${soname}" ]; then
            # Deref the soname symlink to the real file, install under the
            # soname the binary actually requests (its DT_NEEDED entry).
            cp -L "$libpath" "${PRIV_LIB}/${soname}"
            chmod 0644 "${PRIV_LIB}/${soname}"
            # Siblings live in the same dir; $ORIGIN makes transitive deps
            # resolve without the executable's rpath being inherited.
            patchelf --set-rpath '$ORIGIN' "${PRIV_LIB}/${soname}"
        fi
    done < <(ldd "$elf" 2>/dev/null || true)

    # Loud failure if anything is unresolved against this build's libraries.
    if ldd "$elf" 2>/dev/null | grep -q 'not found'; then
        echo "::error title=bundle::${elf} has unresolved libraries:" >&2
        ldd "$elf" 2>/dev/null | grep 'not found' >&2 || true
        return 1
    fi
}

echo "=== Bundling package: ${PACKAGE} ==="

# Realize package file list. dpkg -L lists files and dirs the package owns.
mapfile -t PKG_FILES < <(dpkg -L "$PACKAGE" 2>/dev/null || true)
if [ "${#PKG_FILES[@]}" -eq 0 ]; then
    echo "::error title=bundle::dpkg -L ${PACKAGE} returned nothing (package not installed?)" >&2
    exit 1
fi

bin_count=0
for f in "${PKG_FILES[@]}"; do
    [ -f "$f" ] || continue
    case "$f" in
        /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*)
            # Normalize the usr-merge symlink roots to real /usr locations.
            rel="${f#/}"
            rel="${rel/#bin\//usr/bin/}"
            rel="${rel/#sbin\//usr/sbin/}"
            dest="${SYSEXT_ROOT}/${rel}"
            mkdir -p "$(dirname "$dest")"
            if is_elf "$f"; then
                cp "$f" "$dest"
                chmod 0755 "$dest"
                bundle_libs_for "$dest"
                # Point the binary at the private lib dir. $ORIGIN is /usr/bin
                # (or /usr/sbin); one ../ reaches /usr, then lib/cli-tools/lib.
                patchelf --set-rpath '$ORIGIN/../lib/cli-tools/lib' "$dest"
            else
                # Non-ELF (wrapper script): copy verbatim.
                cp "$f" "$dest"
                chmod 0755 "$dest"
            fi
            cmd="$(basename "$dest")"
            echo "$cmd" >> "$MANIFEST"
            echo "  bin: ${rel}"
            bin_count=$((bin_count+1))
            ;;
        /usr/share/*)
            # Runtime data files (e.g. nmap-services). Skip human-only payloads.
            case "$f" in
                /usr/share/doc/*|/usr/share/man/*|/usr/share/locale/*|\
                /usr/share/lintian/*|/usr/share/bash-completion/*|\
                /usr/share/zsh/*|/usr/share/info/*|/usr/share/menu/*) continue ;;
            esac
            rel="${f#/}"
            dest="${SYSEXT_ROOT}/${rel}"
            mkdir -p "$(dirname "$dest")"
            cp "$f" "$dest"
            ;;
    esac
done

if [ "$bin_count" -eq 0 ]; then
    echo "::error title=bundle::${PACKAGE} shipped no binaries under bin/sbin" >&2
    exit 1
fi
echo "  bundled ${bin_count} binary/binaries from ${PACKAGE}"
