#!/usr/bin/env bash
# Package build outputs as release assets and write SHA256SUMS.
#
# Usage: scripts/package.sh --version VER [options]
#   --version VER        release version, e.g. v1-exp-20260917b (default: exact git tag of HEAD)
#   --out-dir DIR        build outputs (default: ./out), as produced by build-proton.sh and build-turnip.sh
#   --dist-dir DIR       where to write the assets (default: ./dist)
#   --wine-src DIR       existing Wine checkout at $WINE_COMMIT to package (default: fetch it)
#   --no-wine-src        do not create the Wine source tarball
#   -h, --help           show this help
#
# Assets (each one is created only if its input exists):
#   proton-frame-<ver>.tar.xz           out/proton/proton-frame-fixes/ (+ BUILDINFO)
#   turnip-frame-<ver>.tar.xz           out/turnip/ as turnip/
#   wine-src-<commit>-patched.tar.xz    Wine sources with patches/wine applied (LGPL compliance)
#   proton-src-<ver>.tar.xz             Proton with all submodules as built (out/proton/sources, see build-proton.sh)
#   proton-src-downloads-<ver>.tar      other source archives used by the Proton build (wine-mono, wine-gecko, ...)
#   install-min.sh                      minimal installer (its VER= line set to this version)
#   uninstall-min.sh                    removes what install-min.sh installed
#   SHA256SUMS

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WINE_URL="${WINE_URL:-https://github.com/ValveSoftware/wine.git}"
WINE_COMMIT="${WINE_COMMIT:-debeec01b20ce07a0abc9a1876aa372259335d74}"
TOOL_DIR_NAME="proton-frame-fixes"

usage() {
    sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    echo "error: $*" >&2
    exit 1
}

version=""
out_dir="$REPO_ROOT/out"
dist_dir="$REPO_ROOT/dist"
wine_src=""
wine_tarball=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="$2"; shift ;;
        --out-dir) out_dir="$2"; shift ;;
        --dist-dir) dist_dir="$2"; shift ;;
        --wine-src) wine_src="$2"; shift ;;
        --no-wine-src) wine_tarball=0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

if [[ -z "$version" ]]; then
    version="$(git -C "$REPO_ROOT" describe --tags --exact-match HEAD 2>/dev/null)" \
        || die "--version not given and HEAD has no tag"
fi
[[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid version: $version"

# Reproducible tarballs: fixed order, owner and timestamps.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO_ROOT" log -1 --format=%ct)}"
TAR_OPTS=(--sort=name --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" --format=gnu)

# make_tarball <output.tar.xz> <base dir> <entry>...
make_tarball() {
    local output="$1" base="$2"
    shift 2
    echo "==> $(basename "$output")"
    tar -C "$base" "${TAR_OPTS[@]}" -cf - "$@" | xz -T0 -6 > "$output.tmp"
    mv "$output.tmp" "$output"
}

mkdir -p "$dist_dir"
dist_dir="$(cd "$dist_dir" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

assets=()

# --- Proton ------------------------------------------------------------------------------------

if [[ -d "$out_dir/proton/$TOOL_DIR_NAME" ]]; then
    [[ -f "$out_dir/proton/BUILDINFO" ]] || die "$out_dir/proton/BUILDINFO missing"
    cp -a "$out_dir/proton/$TOOL_DIR_NAME" "$tmp/$TOOL_DIR_NAME"
    cp "$out_dir/proton/BUILDINFO" "$tmp/$TOOL_DIR_NAME/BUILDINFO"
    make_tarball "$dist_dir/proton-frame-$version.tar.xz" "$tmp" "$TOOL_DIR_NAME"
    rm -rf "${tmp:?}/$TOOL_DIR_NAME"
    assets+=("proton-frame-$version.tar.xz")
else
    echo "warning: no Proton build in $out_dir/proton, skipping" >&2
fi

# --- Turnip ------------------------------------------------------------------------------------

if [[ -f "$out_dir/turnip/libvulkan_freedreno.so" ]]; then
    for f in freedreno_icd.aarch64.json.in LICENSE BUILDINFO; do
        [[ -f "$out_dir/turnip/$f" ]] || die "$out_dir/turnip/$f missing"
    done
    mkdir "$tmp/turnip"
    cp -a "$out_dir/turnip/." "$tmp/turnip/"
    make_tarball "$dist_dir/turnip-frame-$version.tar.xz" "$tmp" turnip
    rm -rf "${tmp:?}/turnip"
    assets+=("turnip-frame-$version.tar.xz")
else
    echo "warning: no Turnip build in $out_dir/turnip, skipping" >&2
fi

# --- Proton corresponding source -----------------------------------------------------------------

if [[ -f "$out_dir/proton/sources/proton-source.tar.xz" ]]; then
    echo "==> proton-src-$version.tar.xz"
    size="$(stat -c %s "$out_dir/proton/sources/proton-source.tar.xz")"
    (( size < 2000000000 )) || die "proton-source.tar.xz is larger than a GitHub release file may be"
    cp "$out_dir/proton/sources/proton-source.tar.xz" "$dist_dir/proton-src-$version.tar.xz"
    assets+=("proton-src-$version.tar.xz")
    echo "==> proton-src-downloads-$version.tar"
    tar -C "$out_dir/proton/sources" "${TAR_OPTS[@]}" -cf "$dist_dir/proton-src-downloads-$version.tar" downloads
    assets+=("proton-src-downloads-$version.tar")
elif [[ -d "$out_dir/proton/$TOOL_DIR_NAME" ]]; then
    echo "warning: no Proton sources in $out_dir/proton/sources (build-proton.sh --no-sources?)" >&2
fi

# --- Wine sources (LGPL) -----------------------------------------------------------------------

if [[ $wine_tarball -eq 1 ]]; then
    if [[ -z "$wine_src" ]]; then
        echo "==> Fetching Wine $WINE_COMMIT"
        wine_src="$tmp/wine-git"
        git init -q "$wine_src"
        git -C "$wine_src" fetch -q --depth 1 "$WINE_URL" "$WINE_COMMIT"
    fi
    name="wine-src-$WINE_COMMIT-patched"
    # Export the pristine commit (ignores local changes in --wine-src), then apply the patches.
    mkdir "$tmp/$name"
    git -C "$wine_src" archive "$WINE_COMMIT" | tar -C "$tmp/$name" -xf -
    for p in "$REPO_ROOT"/patches/wine/*.patch; do
        (cd "$tmp/$name" && patch -s -p1 < "$p")
    done
    mkdir "$tmp/$name/frame-fixes-patches"
    cp "$REPO_ROOT"/patches/wine/*.patch "$tmp/$name/frame-fixes-patches/"
    make_tarball "$dist_dir/$name.tar.xz" "$tmp" "$name"
    rm -rf "${tmp:?}/$name"
    assets+=("$name.tar.xz")
fi

# --- Installer and checksums -------------------------------------------------------------------

# Releases carry the minimal install and uninstall scripts.
sed "s/^VER=.*/VER=$version/" "$REPO_ROOT/install-min.sh" > "$dist_dir/install-min.sh"
grep -qx "VER=$version" "$dist_dir/install-min.sh" || die "could not set VER= in install-min.sh"
install -m 0755 "$REPO_ROOT/uninstall-min.sh" "$dist_dir/uninstall-min.sh"
chmod 0755 "$dist_dir/install-min.sh"
assets+=(install-min.sh uninstall-min.sh)

[[ ${#assets[@]} -gt 0 ]] || die "nothing to package"

(cd "$dist_dir" && sha256sum "${assets[@]}" > SHA256SUMS)
echo
echo "Assets in $dist_dir:"
(cd "$dist_dir" && ls -l "${assets[@]}" SHA256SUMS && sha256sum -c --quiet SHA256SUMS)
