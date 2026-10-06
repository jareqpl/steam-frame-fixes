#!/usr/bin/env bash
# Steam Frame fixes installer: Proton ARM64 with the ntdll fix and a Turnip build for running the
# native ARM64 World of Warcraft client on Steam Frame. Run it in desktop mode as your normal user.
#
# Usage: bash install.sh [options]
#   (no options)             install or update to the latest release and print the remaining steps
#   --version TAG            install a specific release (e.g. v1-exp-20260917b)
#   --from-dir DIR           install from release files in DIR instead of downloading them
#   --set-launch-options     also add the Turnip variables to the launch options of matching
#                            non-Steam shortcuts (Steam must be closed)
#   --set-compat-tool        also select the Frame fixes Proton for matching shortcuts (Steam must be closed)
#   --match TEXT             shortcut exe/name to match for the two options above (repeatable;
#                            default: "ARM64.exe" and "World of Warcraft")
#   --yes                    do not ask for confirmation
#   --uninstall              remove everything this script installed and undo its shortcut changes
#   --doctor                 show the installation state and what the last Proton logs say
#   -h, --help               show this help
#
# Nothing here modifies game files. Steam settings are only changed with --set-launch-options or
# --set-compat-tool, after a backup, and --uninstall undoes those changes.

set -euo pipefail

REPO="${FRAME_FIXES_REPO:-jareqpl/steam-frame-fixes}"
BASE_URL="${FRAME_FIXES_BASE_URL:-https://github.com/$REPO/releases}"
TOOL_DIR_NAME="proton-frame-fixes"
INTERNAL_TOOL_NAME=proton_frame_fixes
DEFAULT_MATCH=("ARM64.exe" "World of Warcraft")

STEAM_DIR="${STEAM_DIR:-$HOME/.local/share/Steam}"
TOOL_DIR="$STEAM_DIR/compatibilitytools.d/$TOOL_DIR_NAME"
DATA_DIR="$HOME/.local/share/steam-frame-fixes"
TURNIP_DIR="$DATA_DIR/turnip"
ICD_FILE="$TURNIP_DIR/freedreno_icd.aarch64.json"
SHORTCUTS_TOOL="$DATA_DIR/steam_shortcuts.py"
INSTALLER_COPY="$DATA_DIR/install.sh"
STATE_FILE="$DATA_DIR/state"
HOST_DRIVER=/run/host/usr/lib/libvulkan_freedreno.so

usage() {
    sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    echo "error: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

version=""
from_dir=""
set_launch=0
set_compat=0
uninstall=0
doctor=0
yes=0
match=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="${2:?--version needs a value}"; shift ;;
        --from-dir) from_dir="${2:?--from-dir needs a value}"; shift ;;
        --set-launch-options) set_launch=1 ;;
        --set-compat-tool) set_compat=1 ;;
        --match) match+=("${2:?--match needs a value}"); shift ;;
        --yes) yes=1 ;;
        --uninstall) uninstall=1 ;;
        --doctor) doctor=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
done
[[ ${#match[@]} -gt 0 ]] || match=("${DEFAULT_MATCH[@]}")

launch_line() {
    echo "VK_ICD_FILENAMES=$ICD_FILE VK_DRIVER_FILES=$ICD_FILE %command%"
}

# --- State file (key=value lines; "compat <appid> <previous tool>" lines for compat changes) -----

state_get() {
    [[ -f "$STATE_FILE" ]] || return 0
    sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1
}

state_set() {
    mkdir -p "$DATA_DIR"
    local tmp="$STATE_FILE.tmp"
    { [[ -f "$STATE_FILE" ]] && grep -v "^$1=" "$STATE_FILE" || true; echo "$1=$2"; } > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

state_add_line() {
    mkdir -p "$DATA_DIR"
    if [[ ! -f "$STATE_FILE" ]] || ! grep -qxF "$1" "$STATE_FILE"; then
        echo "$1" >> "$STATE_FILE"
    fi
}

# --- Checks --------------------------------------------------------------------------------------

check_system() {
    if [[ "${FRAME_FIXES_SKIP_ARCH_CHECK:-0}" != 1 && "$(uname -m)" != aarch64 ]]; then
        die "this is $(uname -m); these builds are for ARM64 devices such as Steam Frame"
    fi
    [[ -d "$STEAM_DIR" ]] || die "Steam directory not found: $STEAM_DIR (start Steam once first)"
    if ! grep -qs '^ID=steamos' /etc/os-release; then
        echo "warning: this does not look like SteamOS; continuing anyway" >&2
    fi
    command -v python3 >/dev/null || die "python3 is required"
}

steam_running() {
    pgrep -x steam >/dev/null 2>&1 || pgrep -x steamwebhelper >/dev/null 2>&1
}

require_steam_closed() {
    if steam_running; then
        die "Steam is running. Exit Steam completely (Steam menu > Exit, or switch to desktop mode and quit it), then run this again."
    fi
}

# --- Download and verify -------------------------------------------------------------------------

# fetch <file> <dest dir>: copy from --from-dir or download from the release
fetch() {
    local name="$1" dest="$2"
    if [[ -n "$from_dir" ]]; then
        [[ -f "$from_dir/$name" ]] || die "$name not found in $from_dir"
        cp "$from_dir/$name" "$dest/$name"
    else
        local url
        if [[ -n "$version" ]]; then
            url="$BASE_URL/download/$version/$name"
        else
            url="$BASE_URL/latest/download/$name"
        fi
        curl -fL --retry 3 --progress-bar -o "$dest/$name" "$url" || die "download failed: $url"
    fi
}

# Sets release_version from the asset names in SHA256SUMS.
resolve_version() {
    local sums="$1" proton
    proton="$(grep -o 'proton-frame-[A-Za-z0-9._-]*\.tar\.xz' "$sums" | head -n1)"
    [[ -n "$proton" ]] || die "SHA256SUMS does not list a proton-frame-*.tar.xz archive"
    release_version="${proton#proton-frame-}"
    release_version="${release_version%.tar.xz}"
    if [[ -n "$version" && "$version" != "$release_version" ]]; then
        die "release $version contains files for $release_version"
    fi
}

verify() {
    local dir="$1"
    shift
    local f
    for f in "$@"; do
        grep -qE "^[0-9a-f]{64}  $f\$" "$dir/SHA256SUMS" || die "$f is not listed in SHA256SUMS"
    done
    (cd "$dir" && grep -E "  ($(IFS='|'; echo "${*//./\\.}"))\$" SHA256SUMS | sha256sum -c --quiet -) \
        || die "checksum mismatch, the download is damaged or was tampered with"
}

# --- Install -------------------------------------------------------------------------------------

display_name() {
    sed -nE 's/^[[:space:]]*"display_name"[[:space:]]+"([^"]*)".*/\1/p' "$TOOL_DIR/compatibilitytool.vdf" 2>/dev/null | head -n1
}

json_escape() {
    local s="${1//\\/\\\\}"
    printf '%s' "${s//\"/\\\"}"
}

do_install() {
    local tmp
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT

    info "Fetching release information"
    fetch SHA256SUMS "$tmp"
    resolve_version "$tmp/SHA256SUMS"
    local proton_tar="proton-frame-$release_version.tar.xz"
    local turnip_tar="turnip-frame-$release_version.tar.xz"

    if [[ "$(state_get version)" == "$release_version" && -f "$TOOL_DIR/proton" && -f "$ICD_FILE" \
          && -f "$SHORTCUTS_TOOL" && -f "$INSTALLER_COPY" ]]; then
        info "Release $release_version is already installed"
        return 0
    fi

    info "Fetching release $release_version"
    fetch "$proton_tar" "$tmp"
    fetch "$turnip_tar" "$tmp"
    fetch steam_shortcuts.py "$tmp"
    fetch install.sh "$tmp"
    info "Verifying checksums"
    verify "$tmp" "$proton_tar" "$turnip_tar" steam_shortcuts.py install.sh

    info "Installing Proton to $TOOL_DIR"
    mkdir -p "$STEAM_DIR/compatibilitytools.d"
    local staging="$STEAM_DIR/compatibilitytools.d/.$TOOL_DIR_NAME.new"
    rm -rf "$staging"
    mkdir -p "$staging"
    tar -xJf "$tmp/$proton_tar" -C "$staging"
    [[ -f "$staging/$TOOL_DIR_NAME/proton" ]] || die "$proton_tar does not contain $TOOL_DIR_NAME/proton"
    rm -rf "$TOOL_DIR"
    mv "$staging/$TOOL_DIR_NAME" "$TOOL_DIR"
    rm -rf "$staging"

    info "Installing Turnip to $TURNIP_DIR"
    mkdir -p "$DATA_DIR"
    rm -rf "$DATA_DIR/.turnip.new"
    mkdir -p "$DATA_DIR/.turnip.new"
    tar -xJf "$tmp/$turnip_tar" -C "$DATA_DIR/.turnip.new"
    local new="$DATA_DIR/.turnip.new/turnip"
    [[ -f "$new/libvulkan_freedreno.so" && -f "$new/freedreno_icd.aarch64.json.in" ]] \
        || die "$turnip_tar does not contain the driver and its ICD template"
    local template
    template="$(<"$new/freedreno_icd.aarch64.json.in")"
    printf '%s\n' "${template//@LIBPATH@/$(json_escape "$TURNIP_DIR/libvulkan_freedreno.so")}" \
        > "$new/freedreno_icd.aarch64.json"
    rm -rf "$TURNIP_DIR"
    mv "$new" "$TURNIP_DIR"
    rm -rf "$DATA_DIR/.turnip.new"

    install -m 0755 "$tmp/steam_shortcuts.py" "$SHORTCUTS_TOOL"
    install -m 0755 "$tmp/install.sh" "$INSTALLER_COPY"
    state_set version "$release_version"
    info "Installed release $release_version"
}

# --- Steam shortcut changes ----------------------------------------------------------------------

shortcut_files() {
    compgen -G "$STEAM_DIR/userdata/*/config/shortcuts.vdf" || true
}

match_args() {
    local m
    for m in "${match[@]}"; do
        printf '%s\0%s\0' --match "$m"
    done
}

do_set_launch_options() {
    require_steam_closed
    local files f found=0 extra=()
    mapfile -t files < <(shortcut_files)
    [[ ${#files[@]} -gt 0 ]] || die "no non-Steam shortcuts found (add the game as a non-Steam game first)"
    [[ $yes -eq 1 ]] && extra+=(--yes)
    local margs=()
    mapfile -d '' -t margs < <(match_args)
    for f in "${files[@]}"; do
        info "Launch options in $f"
        local rc=0
        python3 "$SHORTCUTS_TOOL" set-launch-options --shortcuts "$f" "${margs[@]}" \
            --env "VK_ICD_FILENAMES=$ICD_FILE" --env "VK_DRIVER_FILES=$ICD_FILE" "${extra[@]}" || rc=$?
        case $rc in
            0) found=1; state_add_line "launch $f" ;;
            3) echo "    no matching shortcuts" ;;
            *) die "could not update $f" ;;
        esac
    done
    [[ $found -eq 1 ]] || die "no shortcut matches: ${match[*]} (use --match)"
    state_set match "$(printf '%s\x1f' "${match[@]}")"
}

do_set_compat_tool() {
    require_steam_closed
    local config="$STEAM_DIR/config/config.vdf"
    [[ -f "$config" ]] || die "$config not found"
    local files f appids=() margs=()
    mapfile -t files < <(shortcut_files)
    mapfile -d '' -t margs < <(match_args)
    for f in "${files[@]}"; do
        mapfile -t -O "${#appids[@]}" appids < <(python3 "$SHORTCUTS_TOOL" list --shortcuts "$f" "${margs[@]}" --format appid || true)
    done
    [[ ${#appids[@]} -gt 0 ]] || die "no shortcut matches: ${match[*]} (use --match)"
    local args=(set-compat-tool --config "$config" --tool "$INTERNAL_TOOL_NAME") a out
    for a in "${appids[@]}"; do
        args+=(--appid "$a")
    done
    [[ $yes -eq 1 ]] && args+=(--yes)
    info "Compatibility tool in $config"
    out="$(python3 "$SHORTCUTS_TOOL" "${args[@]}")" || { echo "$out"; die "could not update $config"; }
    echo "$out"
    # "  appid N: previous=X new=Y" -> remember X to restore it on uninstall
    local appid previous
    while read -r appid previous; do
        if ! grep -q "^compat $appid " "$STATE_FILE" 2>/dev/null; then
            state_add_line "compat $appid ${previous:--}"
        fi
    done < <(sed -nE 's/^  appid ([0-9]+): previous=([^ ]*) new=.*/\1 \2/p' <<<"$out")
}

# --- Uninstall -----------------------------------------------------------------------------------

do_uninstall() {
    local needs_steam_closed=0
    grep -qE '^(launch|compat) ' "$STATE_FILE" 2>/dev/null && needs_steam_closed=1
    [[ $needs_steam_closed -eq 1 ]] && require_steam_closed

    if [[ $needs_steam_closed -eq 1 && -f "$SHORTCUTS_TOOL" ]]; then
        local saved line f margs=() m
        saved="$(state_get match)"
        if [[ -n "$saved" ]]; then
            IFS=$'\x1f' read -r -a match <<<"$saved"
        fi
        for m in "${match[@]}"; do margs+=(--match "$m"); done
        while read -r line; do
            f="${line#launch }"
            [[ -f "$f" ]] || continue
            info "Removing launch options in $f"
            python3 "$SHORTCUTS_TOOL" unset-launch-options --shortcuts "$f" "${margs[@]}" \
                --env VK_ICD_FILENAMES --env VK_DRIVER_FILES --yes || echo "warning: could not update $f" >&2
        done < <(grep '^launch ' "$STATE_FILE" || true)

        local config="$STEAM_DIR/config/config.vdf" appid previous
        if [[ -f "$config" ]]; then
            while read -r _ appid previous; do
                info "Restoring the compatibility tool of appid $appid"
                python3 "$SHORTCUTS_TOOL" unset-compat-tool --config "$config" --appid "$appid" \
                    --tool "$INTERNAL_TOOL_NAME" --yes || echo "warning: could not update $config" >&2
                if [[ "$previous" != "-" ]]; then
                    python3 "$SHORTCUTS_TOOL" set-compat-tool --config "$config" --appid "$appid" \
                        --tool "$previous" --yes --no-backup || echo "warning: could not restore $previous" >&2
                fi
            done < <(grep '^compat ' "$STATE_FILE" || true)
        fi
    fi

    info "Removing $TOOL_DIR and $DATA_DIR"
    rm -rf "$TOOL_DIR" "$DATA_DIR"
    echo
    echo "Uninstalled. Restart Steam. Backups of changed Steam files (*.frame-fixes-*.bak) were kept."
    echo "Games that used \"$INTERNAL_TOOL_NAME\" fall back to Steam's default compatibility tool."
}

# --- Doctor --------------------------------------------------------------------------------------

ntdll_count() {
    python3 -c 'import sys; print(open(sys.argv[1], "rb").read().count(bytes.fromhex("0010fe7f00000000")))' "$1"
}

do_doctor() {
    echo "Release:        $(state_get version || true)"
    if [[ -f "$TOOL_DIR/proton" ]]; then
        echo "Proton:         $TOOL_DIR (\"$(display_name)\")"
        local ntdll="$TOOL_DIR/files/lib/wine/aarch64-windows/ntdll.dll"
        [[ -f "$ntdll" ]] && echo "                ntdll.dll fix literal: $(ntdll_count "$ntdll") (should be hundreds)"
    else
        echo "Proton:         not installed"
    fi
    if [[ -f "$TURNIP_DIR/libvulkan_freedreno.so" && -f "$ICD_FILE" ]]; then
        echo "Turnip:         $TURNIP_DIR"
        grep -q "\"$TURNIP_DIR/libvulkan_freedreno.so\"" "$ICD_FILE" \
            && echo "                ICD points to the installed driver" \
            || echo "                WARNING: $ICD_FILE does not point to $TURNIP_DIR/libvulkan_freedreno.so"
    else
        echo "Turnip:         not installed"
    fi
    echo "Launch options: $(launch_line)"
    if [[ -f "$STATE_FILE" ]] && grep -qE '^(launch|compat) ' "$STATE_FILE"; then
        echo "Changed by this installer:"
        sed -nE 's/^launch (.*)/  launch options in \1/p; s/^compat ([0-9]+) (.*)/  compatibility tool of appid \1 (previously: \2)/p' "$STATE_FILE"
    fi

    local appid pfx_ntdll
    while read -r _ appid _; do
        pfx_ntdll="$STEAM_DIR/steamapps/compatdata/$appid/pfx/drive_c/windows/system32/ntdll.dll"
        [[ -f "$pfx_ntdll" ]] && echo "Prefix $appid:   ntdll.dll fix literal: $(ntdll_count "$pfx_ntdll")"
    done < <(grep '^compat ' "$STATE_FILE" 2>/dev/null || true)

    local logs=()
    # newest first; the names are steam-<appid>.log, so ls output is safe to parse
    # shellcheck disable=SC2012
    mapfile -t logs < <(ls -t "$HOME"/steam-*.log 2>/dev/null | head -n 3)
    if [[ ${#logs[@]} -eq 0 ]]; then
        echo
        echo "No Proton logs (~/steam-<appid>.log). Add PROTON_LOG=1 in front of the launch options to create one."
        return 0
    fi
    local log driver
    for log in "${logs[@]}"; do
        echo
        echo "Log $log ($(date -r "$log" '+%F %T')):"
        driver="$(grep -o 'Using "[^"]*" with driver: "[^"]*"' "$log" | tail -n1 || true)"
        if [[ -z "$driver" ]]; then
            echo "  no Vulkan loader line (the game may not have created a Vulkan device yet)"
        elif [[ "$driver" == *"$HOST_DRIVER"* ]]; then
            echo "  PROBLEM: the system driver is used: $driver"
            echo "  Check the launch options: $(launch_line)"
        else
            echo "  OK: $driver"
        fi
        if grep -q 'compile failed!' "$log"; then
            echo "  PROBLEM: shader compilation failures (\"compile failed!\") found"
        fi
    done
}

# --- Main ----------------------------------------------------------------------------------------

if [[ $doctor -eq 1 ]]; then
    do_doctor
    exit 0
fi

if [[ $uninstall -eq 1 ]]; then
    do_uninstall
    exit 0
fi

check_system
do_install
[[ $set_launch -eq 1 ]] && do_set_launch_options
[[ $set_compat -eq 1 ]] && do_set_compat_tool

name="$(display_name)"
cat <<EOF

Done. Remaining steps:
  1. Restart Steam (Steam menu > Exit, then start it again).
EOF
if [[ $set_compat -eq 1 ]]; then
    echo "  2. Compatibility tool: already set to \"$name\" for the matching shortcuts."
else
    echo "  2. In the game's shortcut: Properties > Compatibility > force \"$name\"."
fi
if [[ $set_launch -eq 1 ]]; then
    echo "  3. Launch options: already set for the matching shortcuts."
else
    echo "  3. In the game's shortcut: Properties > General > Launch options, enter exactly:"
    echo
    echo "     $(launch_line)"
fi
cat <<EOF

Check the setup (after starting the game once with PROTON_LOG=1):  bash $INSTALLER_COPY --doctor
Remove everything:                                                   bash $INSTALLER_COPY --uninstall
EOF
