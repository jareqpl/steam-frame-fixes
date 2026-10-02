#!/usr/bin/env bash
# Verify that the patches in patches/ apply cleanly to the pinned upstream commits.
#
# Fetches only the pinned commits (shallow), so it runs on any architecture in a few minutes.
# Usage: scripts/check-patches.sh [--keep] [wine|mesa ...]
#   --keep   keep the checkouts in $WORK_DIR (default: removed on exit)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WINE_URL="${WINE_URL:-https://github.com/ValveSoftware/wine.git}"
WINE_COMMIT="${WINE_COMMIT:-debeec01b20ce07a0abc9a1876aa372259335d74}"
MESA_URL="${MESA_URL:-https://gitlab.freedesktop.org/mesa/mesa.git}"
MESA_COMMIT="${MESA_COMMIT:-e3a986f0167aa7d1c5cfd62a63362c65f5339373}"

usage() {
    sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

keep=0
components=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) keep=1 ;;
        -h|--help) usage; exit 0 ;;
        wine|mesa) components+=("$1") ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
[[ ${#components[@]} -gt 0 ]] || components=(wine mesa)

WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
if [[ $keep -eq 0 ]]; then
    trap 'rm -rf "$WORK_DIR"' EXIT
else
    echo "Keeping checkouts in $WORK_DIR"
fi

# fetch_commit <dir> <url> <commit>: shallow checkout of a single commit
fetch_commit() {
    local dir="$1" url="$2" commit="$3"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "$url" "$commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    local head
    head="$(git -C "$dir" rev-parse HEAD)"
    if [[ "$head" != "$commit" ]]; then
        echo "error: $url: expected $commit, got $head" >&2
        return 1
    fi
}

check_wine() {
    echo "==> Wine @ $WINE_COMMIT"
    fetch_commit "$WORK_DIR/wine" "$WINE_URL" "$WINE_COMMIT"
    git -C "$WORK_DIR/wine" apply --check -v "$REPO_ROOT"/patches/wine/*.patch
}

check_mesa() {
    echo "==> Mesa @ $MESA_COMMIT"
    fetch_commit "$WORK_DIR/mesa" "$MESA_URL" "$MESA_COMMIT"
    git -C "$WORK_DIR/mesa" -c user.name=check -c user.email=check@localhost \
        am -q "$REPO_ROOT"/patches/mesa/*.patch
    git -C "$WORK_DIR/mesa" log --format='    applied: %s (%an)' "$MESA_COMMIT"..HEAD
}

for c in "${components[@]}"; do
    "check_$c"
done
echo "All patches apply cleanly."
