#!/usr/bin/env bash
# Build Proton (ARM64) with patches/wine/*.patch applied, as a Steam compatibility tool.
#
# Needs an arm64 host with docker (or podman); Proton's own build runs in the Steam Runtime 4 SDK image.
# A full build takes several hours and 30-40 GB of disk. Re-running resumes an interrupted build.
#
# Usage: scripts/build-proton.sh [options]
#   --work-dir DIR       sources and build tree (default: ./build/proton)
#   --out-dir DIR        output directory (default: ./out/proton)
#   --display-name NAME  name shown in Steam (default: "Proton Experimental ARM64 (Frame fixes)")
#   --ccache             use ccache ($CCACHE_DIR, default ~/.ccache)
#   --clean              remove the previous build tree first
#   --skip-build         only copy and verify the result of a previous build (any host)
#   -h, --help           show this help
#
# Environment overrides: PROTON_URL, PROTON_TAG, WINE_COMMIT, CONTAINER_ENGINE (docker|podman), CCACHE_DIR.
#
# Output: <out-dir>/proton-frame-fixes/ (compatibility tool directory, the result of `make redist`)
#         <out-dir>/BUILDINFO

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROTON_URL="${PROTON_URL:-https://github.com/ValveSoftware/Proton.git}"
PROTON_TAG="${PROTON_TAG:-experimental-11.0-20260917b}"
WINE_COMMIT="${WINE_COMMIT:-debeec01b20ce07a0abc9a1876aa372259335d74}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"

# Directory name in compatibilitytools.d, build name and internal tool name (CompatToolMapping "name")
TOOL_DIR_NAME="proton-frame-fixes"
BUILD_NAME="proton-frame-fixes"
INTERNAL_TOOL_NAME=proton_frame_fixes

# The fix puts the syscall dispatcher pointer at 0x7ffe1000; every syscall thunk in ntdll.dll
# then contains this little-endian 64-bit literal (one per syscall, several hundred in total).
FIXED_ADDRESS_HEX=0010fe7f00000000
MIN_FIXED_ADDRESS_COUNT=100

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    echo "error: $*" >&2
    exit 1
}

work_dir="$REPO_ROOT/build/proton"
out_dir="$REPO_ROOT/out/proton"
display_name="Proton Experimental ARM64 (Frame fixes)"
ccache=0
clean=0
skip_build=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --work-dir) work_dir="$2"; shift ;;
        --out-dir) out_dir="$2"; shift ;;
        --display-name) display_name="$2"; shift ;;
        --ccache) ccache=1 ;;
        --clean) clean=1 ;;
        --skip-build) skip_build=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

if [[ $skip_build -eq 0 ]]; then
    [[ "$(uname -m)" == aarch64 ]] || die "Proton ARM64 must be built on an arm64 host (this is $(uname -m))"
    command -v "$CONTAINER_ENGINE" >/dev/null || die "$CONTAINER_ENGINE not found"
fi
[[ "$display_name" != *[\"\\\|\&]* ]] || die "--display-name must not contain \", \\, | or &"

# ntdll_fixed_address_count <ntdll.dll>: number of 0x7ffe1000 literals
ntdll_fixed_address_count() {
    python3 -c 'import sys; print(open(sys.argv[1], "rb").read().count(bytes.fromhex(sys.argv[2])))' \
        "$1" "$FIXED_ADDRESS_HEX"
}

mkdir -p "$work_dir"
work_dir="$(cd "$work_dir" && pwd)"
src="$work_dir/Proton"
build="$work_dir/build"

if [[ $skip_build -eq 1 ]]; then
    [[ -d "$src/.git" && -d "$build/redist" ]] || die "--skip-build needs an existing build in $work_dir"
elif [[ $clean -eq 1 ]]; then
    echo "==> Removing previous build tree"
    rm -rf "$build"
fi

# --- Sources -----------------------------------------------------------------------------------

if [[ $skip_build -eq 0 && ! -d "$src/.git" ]]; then
    echo "==> Cloning Proton $PROTON_TAG with submodules"
    if ! git clone -q --depth 1 --branch "$PROTON_TAG" --recurse-submodules --shallow-submodules \
            -c advice.detachedHead=false "$PROTON_URL" "$src"; then
        echo "    shallow submodule clone failed, retrying with full submodule history"
        rm -rf "$src"
        git clone -q --depth 1 --branch "$PROTON_TAG" -c advice.detachedHead=false "$PROTON_URL" "$src"
        git -C "$src" submodule update -q --init --recursive
    fi
fi

# Proton's Makefile runs `git describe` in these submodules to get version strings (FEX fails without
# it), which needs their history and tags; the shallow clone above has neither.
DESCRIBE_SUBMODULES=(FEX dxvk vkd3d-proton)
if [[ $skip_build -eq 0 ]]; then
    for m in "${DESCRIBE_SUBMODULES[@]}"; do
        if [[ "$(git -C "$src/$m" rev-parse --is-shallow-repository)" == true ]]; then
            echo "==> Fetching history and tags of $m (needed for its version string)"
            git -C "$src/$m" fetch -q --unshallow --tags --no-recurse-submodules
        fi
    done
fi

actual_tag="$(git -C "$src" describe --tags --exact-match HEAD 2>/dev/null || true)"
[[ "$actual_tag" == "$PROTON_TAG" ]] || die "$src is at '${actual_tag:-$(git -C "$src" rev-parse HEAD)}', expected $PROTON_TAG (use a clean --work-dir)"

# The commit recorded in Proton for the wine submodule (works without a submodule checkout)
wine_head="$(git -C "$src" rev-parse HEAD:wine)"
[[ "$wine_head" == "$WINE_COMMIT" ]] || die "Proton $PROTON_TAG pins wine $wine_head, expected $WINE_COMMIT"

apply_wine_patches() {
    local wine_checkout
    wine_checkout="$(git -C "$src/wine" rev-parse HEAD)"
    [[ "$wine_checkout" == "$WINE_COMMIT" ]] || die "wine submodule is checked out at $wine_checkout, expected $WINE_COMMIT"

    echo "==> Applying Wine patches"
    local p
    for p in "$REPO_ROOT"/patches/wine/*.patch; do
        if git -C "$src/wine" apply --reverse --check "$p" 2>/dev/null; then
            echo "    already applied: $(basename "$p")"
        else
            git -C "$src/wine" apply "$p"
            echo "    applied: $(basename "$p")"
        fi
    done
}

# --- Build -------------------------------------------------------------------------------------

build_proton() {
    mkdir -p "$build"
    if [[ ! -f "$build/Makefile" ]]; then
        echo "==> Configuring"
        local configure_args=(--target-arch=arm64 "--container-engine=$CONTAINER_ENGINE" "--build-name=$BUILD_NAME")
        [[ $ccache -eq 1 ]] && configure_args+=(--enable-ccache)
        (cd "$build" && "$src/configure.sh" "${configure_args[@]}")
    fi

    echo "==> make redist (this takes hours)"
    local start=$SECONDS
    make -C "$build" redist
    echo "==> Build finished in $(( (SECONDS - start) / 60 )) min"
}

if [[ $skip_build -eq 0 ]]; then
    apply_wine_patches
    build_proton
fi

# --- Output ------------------------------------------------------------------------------------

redist="$build/redist"
[[ -f "$redist/proton" && -f "$redist/compatibilitytool.vdf" ]] || die "make redist did not produce $redist"

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
tool="$out_dir/$TOOL_DIR_NAME"
echo "==> Copying the compatibility tool to $tool"
rm -rf "$tool"
cp -a "$redist" "$tool"

sed -i -E \
    -e "s|^([[:space:]]*)\"$BUILD_NAME-proton\"|\1\"$INTERNAL_TOOL_NAME\"|" \
    -e "s|^([[:space:]]*\"display_name\"[[:space:]]+)\"[^\"]*\"|\1\"$display_name\"|" \
    "$tool/compatibilitytool.vdf"

for f in LICENSE LICENSE.proton dist.LICENSE; do
    [[ -f "$tool/$f" ]] || cp "$src/$f" "$tool/"
done

# --- Verification ------------------------------------------------------------------------------

echo "==> Verifying"
ntdll="$tool/files/lib/wine/aarch64-windows/ntdll.dll"
[[ -f "$ntdll" ]] || die "$ntdll not found"
count="$(ntdll_fixed_address_count "$ntdll")"
(( count >= MIN_FIXED_ADDRESS_COUNT )) || die "ntdll.dll contains the 0x7ffe1000 literal $count times (expected >= $MIN_FIXED_ADDRESS_COUNT), the Wine patch is missing"
echo "    ntdll.dll: 0x7ffe1000 literal found $count times"

cmp -s "$tool/toolmanifest.vdf" "$src/toolmanifest_arm64.vdf" || die "toolmanifest.vdf does not match toolmanifest_arm64.vdf"
echo "    toolmanifest.vdf: arm64"

actual_name="$(sed -nE 's/^[[:space:]]*"display_name"[[:space:]]+"([^"]*)".*/\1/p' "$tool/compatibilitytool.vdf")"
[[ "$actual_name" == "$display_name" ]] || die "display_name in compatibilitytool.vdf is '$actual_name'"
grep -qF "\"$INTERNAL_TOOL_NAME\"" "$tool/compatibilitytool.vdf" || die "internal tool name was not set in compatibilitytool.vdf"
echo "    compatibilitytool.vdf: $INTERNAL_TOOL_NAME, \"$display_name\""

{
    echo "component: proton"
    echo "proton_url: $PROTON_URL"
    echo "proton_tag: $PROTON_TAG"
    echo "proton_commit: $(git -C "$src" rev-parse HEAD)"
    echo "wine_commit: $wine_head"
    echo "patches:"
    for p in "$REPO_ROOT"/patches/wine/*.patch; do
        echo "  - $(basename "$p") sha256:$(sha256sum "$p" | cut -d' ' -f1)"
    done
    echo "tool_dir: $TOOL_DIR_NAME"
    echo "internal_tool_name: $INTERNAL_TOOL_NAME"
    echo "display_name: $display_name"
    echo "ntdll_fixed_address_count: $count"
    echo "version: $(cat "$tool/version" 2>/dev/null || echo unknown)"
} > "$out_dir/BUILDINFO"

echo
cat "$out_dir/BUILDINFO"
echo
echo "Proton build OK: $tool"
