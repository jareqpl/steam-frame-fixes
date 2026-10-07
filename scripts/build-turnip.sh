#!/usr/bin/env bash
# Build Turnip (Mesa Vulkan driver for Adreno) from upstream Mesa plus patches/mesa/*.patch,
# inside the Steam Runtime 4 arm64 SDK container, so the result runs on SteamOS (Steam Frame).
#
# Usage: scripts/build-turnip.sh [options]
#   --work-dir DIR   checkout and build tree (default: ./build/turnip)
#   --out-dir DIR    output directory (default: ./out/turnip)
#   --jobs N         parallel build jobs (default: nproc)
#   --emulate        allow building on a non-arm64 host through qemu-user (slow)
#   --no-container   build directly on this host (use when already running inside the SDK image)
#   -h, --help       show this help
#
# Environment overrides: MESA_URL, MESA_COMMIT, SDK_IMAGE, CONTAINER_ENGINE (docker|podman), CCACHE_DIR.
#
# Output (in --out-dir):
#   libvulkan_freedreno.so            the driver
#   freedreno_icd.aarch64.json.in     Vulkan ICD manifest, "library_path" is "@LIBPATH@"
#   LICENSE                           Mesa license overview (docs/license.rst)
#   licenses/                         full license texts referenced by the Mesa sources
#   BUILDINFO                         commits, patches, image and glibc requirements

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MESA_URL="${MESA_URL:-https://gitlab.freedesktop.org/mesa/mesa.git}"
MESA_COMMIT="${MESA_COMMIT:-e3a986f0167aa7d1c5cfd62a63362c65f5339373}"
SDK_IMAGE="${SDK_IMAGE:-registry.gitlab.steamos.cloud/proton/steamrt4/sdk/arm64-llvm:4.0.20260714.251823-0}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"

MESON_OPTIONS=(
    -Dbuildtype=release
    -Db_ndebug=true
    -Dvulkan-drivers=freedreno
    -Dfreedreno-kmds=msm
    -Dgallium-drivers=
    '-Dplatforms=x11,wayland'
    -Dopengl=false
    -Dgles1=disabled
    -Dgles2=disabled
    -Dglx=disabled
    -Degl=disabled
    -Dgbm=disabled
    -Dllvm=disabled
    -Dvideo-codecs=
    -Dtools=
    -Dvalgrind=disabled
    -Dlibunwind=disabled
    -Dlmsensors=disabled
    -Dbuild-tests=false
    # Only download what the driver needs (otherwise meson also builds libarchive for the unused tools).
    -Dwrap_mode=nofallback
    -Dforce_fallback_for=wayland-protocols
)

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    echo "error: $*" >&2
    exit 1
}

work_dir="$REPO_ROOT/build/turnip"
out_dir="$REPO_ROOT/out/turnip"
jobs="$(nproc)"
emulate=0
container=1
inside=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --work-dir) work_dir="$2"; shift ;;
        --out-dir) out_dir="$2"; shift ;;
        --jobs) jobs="$2"; shift ;;
        --emulate) emulate=1 ;;
        --no-container) container=0 ;;
        --inside) inside=1 ;;  # internal: re-executed inside the container
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

# --- Build step, runs inside the SDK container (or directly with --no-container) ---------------

build_inside() {
    local src="$work_dir/mesa" build="$work_dir/mesa-build" stage="$work_dir/stage"

    [[ "$(uname -m)" == aarch64 ]] || die "the build step must run on aarch64 (got $(uname -m))"

    # The pinned SDK image ships everything Mesa needs. Newer Mesa or older images may need a newer
    # meson or python modules; install them privately (the SDK has no ensurepip, so no venv).
    if ! python3 -c 'import mako, yaml' 2>/dev/null || ! meson_ok; then
        echo "==> Installing build tools into $work_dir/pylib"
        python3 -m pip --version >/dev/null 2>&1 || die "meson/mako/pyyaml missing or too old, and pip is not available"
        python3 -m pip install -q --target "$work_dir/pylib" --upgrade meson mako pyyaml packaging
        export PYTHONPATH="$work_dir/pylib${PYTHONPATH:+:$PYTHONPATH}"
        export PATH="$work_dir/pylib/bin:$PATH"
    fi
    echo "==> meson $(meson --version), ninja $(ninja --version), $(cc --version | head -n1)"

    if [[ -n "${CCACHE_DIR:-}" ]] && command -v ccache >/dev/null; then
        export CCACHE_DIR
        echo "==> Using ccache in $CCACHE_DIR"
    fi

    if [[ -f "$build/build.ninja" ]]; then
        meson setup --reconfigure "$build" "$src" --prefix=/usr "${MESON_OPTIONS[@]}"
    else
        meson setup "$build" "$src" --prefix=/usr "${MESON_OPTIONS[@]}"
    fi
    ninja -C "$build" -j "$jobs"

    rm -rf "$stage"
    meson install -C "$build" --destdir "$stage" --strip --quiet

    local lib icd
    lib="$(find "$stage" -name libvulkan_freedreno.so -type f | head -n1)"
    icd="$(find "$stage" -name 'freedreno_icd.*.json' -type f | head -n1)"
    [[ -n "$lib" && -n "$icd" ]] || die "meson install did not produce the driver and its ICD manifest"

    echo "==> Checking runtime dependencies"
    if ldd "$lib" | grep 'not found'; then
        die "unresolved libraries in $lib"
    fi
    local glibc
    glibc="$(objdump -T "$lib" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -n1)"

    mkdir -p "$out_dir"
    install -m 0755 "$lib" "$out_dir/libvulkan_freedreno.so"
    python3 - "$icd" "$out_dir/freedreno_icd.aarch64.json.in" <<'EOF'
import json, sys
with open(sys.argv[1]) as f:
    icd = json.load(f)
icd["ICD"]["library_path"] = "@LIBPATH@"
with open(sys.argv[2], "w") as f:
    json.dump(icd, f, indent=4)
    f.write("\n")
EOF
    install -m 0644 "$src/docs/license.rst" "$out_dir/LICENSE"
    cp -r "$src/licenses" "$out_dir/licenses"

    {
        echo "component: turnip"
        echo "mesa_url: $MESA_URL"
        echo "mesa_commit: $MESA_COMMIT"
        echo "mesa_version: $(cat "$src/VERSION")"
        echo "patches:"
        local p
        for p in "$REPO_ROOT"/patches/mesa/*.patch; do
            echo "  - $(basename "$p") sha256:$(sha256sum "$p" | cut -d' ' -f1)"
        done
        echo "sdk_image: $SDK_IMAGE"
        echo "compiler: $(cc --version | head -n1)"
        echo "max_glibc: $glibc"
        echo "meson_options: ${MESON_OPTIONS[*]}"
    } > "$out_dir/BUILDINFO"
}

meson_ok() {
    command -v meson >/dev/null || return 1
    local required
    required="$(sed -n "s/.*meson_version *: *'>= *\([0-9.]*\)'.*/\1/p" "$work_dir/mesa/meson.build" | head -n1)"
    [[ -z "$required" ]] && return 0
    printf '%s\n%s\n' "$required" "$(meson --version)" | sort -C -V
}

if [[ $inside -eq 1 ]]; then
    build_inside
    exit 0
fi

# --- Host side ---------------------------------------------------------------------------------

host_arch="$(uname -m)"
if [[ "$host_arch" != aarch64 ]]; then
    [[ $emulate -eq 1 ]] || die "host is $host_arch; Turnip must be built on arm64 (or pass --emulate to use qemu-user, slow)"
    [[ $container -eq 1 ]] || die "--no-container requires an arm64 host"
    [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] || die "--emulate needs qemu-user binfmt support (e.g. apt install qemu-user-static)"
fi

mkdir -p "$work_dir" "$out_dir"
work_dir="$(cd "$work_dir" && pwd)"
out_dir="$(cd "$out_dir" && pwd)"

echo "==> Fetching Mesa $MESA_COMMIT"
src="$work_dir/mesa"
if [[ ! -d "$src/.git" ]]; then
    git init -q "$src"
fi
if ! git -C "$src" cat-file -e "$MESA_COMMIT^{commit}" 2>/dev/null; then
    git -C "$src" fetch -q --depth 1 "$MESA_URL" "$MESA_COMMIT"
fi
# Start from a clean pinned tree on every run, so the patches are always applied exactly once.
git -C "$src" -c advice.detachedHead=false checkout -q -f "$MESA_COMMIT"
git -C "$src" clean -q -fdx

echo "==> Applying patches"
git -C "$src" -c user.name=build -c user.email=build@localhost am -q "$REPO_ROOT"/patches/mesa/*.patch
git -C "$src" log --format='    %s' "$MESA_COMMIT"..HEAD

rm -rf "$out_dir"
mkdir -p "$out_dir"

if [[ $container -eq 0 ]]; then
    build_inside
else
    echo "==> Building in $SDK_IMAGE"
    # The image's tini entrypoint fails under qemu-user (no PR_SET_CHILD_SUBREAPER); it is not needed here.
    run_args=(--rm --platform linux/arm64 --entrypoint ""
        -v "$REPO_ROOT:$REPO_ROOT:ro"
        -v "$work_dir:$work_dir"
        -v "$out_dir:$out_dir"
        -w "$REPO_ROOT"
        -e MESA_URL -e MESA_COMMIT -e SDK_IMAGE -e HOME=/tmp)
    if [[ "$CONTAINER_ENGINE" == docker ]]; then
        run_args+=(--user "$(id -u):$(id -g)")
    else
        run_args+=(--userns=keep-id)
    fi
    if [[ -n "${CCACHE_DIR:-}" ]]; then
        mkdir -p "$CCACHE_DIR"
        run_args+=(-v "$CCACHE_DIR:$CCACHE_DIR" -e CCACHE_DIR)
    fi
    "$CONTAINER_ENGINE" run "${run_args[@]}" "$SDK_IMAGE" \
        "$REPO_ROOT/scripts/build-turnip.sh" --inside --work-dir "$work_dir" --out-dir "$out_dir" --jobs "$jobs"
fi

# --- Verification ------------------------------------------------------------------------------

echo "==> Verifying $out_dir"
lib="$out_dir/libvulkan_freedreno.so"
file -b "$lib" | grep -q 'ELF 64-bit LSB shared object, ARM aarch64' || die "$lib is not an aarch64 shared object: $(file -b "$lib")"
for s in 'ir3_sched: deadlock' 'failed to compile %s shader'; do
    grep -aqF "$s" "$lib" || die "string '$s' not found in $lib, the patches are missing"
done
grep -q '"library_path": "@LIBPATH@"' "$out_dir/freedreno_icd.aarch64.json.in" || die "ICD template has no @LIBPATH@"
grep -q '"api_version"' "$out_dir/freedreno_icd.aarch64.json.in" || die "ICD template has no api_version"

echo
cat "$out_dir/BUILDINFO"
echo
echo "Turnip build OK: $out_dir"
