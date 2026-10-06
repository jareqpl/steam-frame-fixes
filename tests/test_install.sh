#!/usr/bin/env bash
# End-to-end test of install.sh in a fake $HOME with fake release files and synthetic Steam files.
# Runs on any architecture; needs bash, python3, xz, git. Usage: tests/test_install.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
ok() {
    pass=$((pass + 1))
    echo "ok - $*"
}

VERSION=v0-test
WOW_APPID=3000964086  # appid -1294003210 of the WoW shortcut in the synthetic shortcuts.vdf

# --- Fake build outputs and release files ------------------------------------------------------

out="$T/out"
tool="$out/proton/proton-frame-fixes"
mkdir -p "$tool/files/lib/wine/aarch64-windows" "$out/turnip"
printf '#!/usr/bin/env python3\n' > "$tool/proton"
cat > "$tool/compatibilitytool.vdf" <<'EOF'
"compatibilitytools"
{
  "compat_tools"
  {
    "proton_frame_fixes" // Internal name of this tool
    {
      "install_path" "."
      "display_name" "Proton Experimental ARM64 (Frame fixes)"
      "from_oslist"  "windows"
      "to_oslist"    "linux"
    }
  }
}
EOF
python3 -c "import sys; open(sys.argv[1], 'wb').write(b'MZ' + bytes.fromhex('0010fe7f00000000') * 300)" \
    "$tool/files/lib/wine/aarch64-windows/ntdll.dll"
echo "component: proton" > "$out/proton/BUILDINFO"
printf '\177ELF fake driver' > "$out/turnip/libvulkan_freedreno.so"
cat > "$out/turnip/freedreno_icd.aarch64.json.in" <<'EOF'
{
    "ICD": {
        "api_version": "1.4.363",
        "library_arch": "64",
        "library_path": "@LIBPATH@"
    },
    "file_format_version": "1.0.1"
}
EOF
echo "Mesa license" > "$out/turnip/LICENSE"
echo "component: turnip" > "$out/turnip/BUILDINFO"

"$REPO_ROOT/scripts/package.sh" --version "$VERSION" --out-dir "$out" --dist-dir "$T/dist" --no-wine-src >/dev/null 2>&1 \
    || fail "package.sh failed"

# Release layout for downloads through file:// URLs
mkdir -p "$T/releases/latest/download" "$T/releases/download/$VERSION"
cp "$T"/dist/* "$T/releases/latest/download/"
cp "$T"/dist/* "$T/releases/download/$VERSION/"

# --- Fake home with Steam files ----------------------------------------------------------------

new_home() {
    local h="$1"
    mkdir -p "$h/.local/share/Steam/userdata/1234/config" "$h/.local/share/Steam/userdata/5678/config" \
             "$h/.local/share/Steam/config"
    python3 - "$h/.local/share/Steam" "$WOW_APPID" <<EOF
import sys
sys.path.insert(0, "$REPO_ROOT/tools/tests")
import test_steam_shortcuts as t
steam, wow = sys.argv[1], sys.argv[2]
open(steam + "/userdata/1234/config/shortcuts.vdf", "wb").write(t.sample_shortcuts())
open(steam + "/userdata/5678/config/shortcuts.vdf", "wb").write(t.m("shortcuts") + b"\x08")
# the WoW shortcut is already mapped to another Proton, which uninstall must restore
open(steam + "/config/config.vdf", "w").write(t.CONFIG_VDF.replace("2343328086", wow))
EOF
}

run_install() {
    HOME="$1" FRAME_FIXES_SKIP_ARCH_CHECK=1 FRAME_FIXES_BASE_URL="file://$T/releases" \
        bash "$REPO_ROOT/install.sh" "${@:2}"
}

H="$T/home"
new_home "$H"
STEAM="$H/.local/share/Steam"
SHORTCUTS="$STEAM/userdata/1234/config/shortcuts.vdf"
CONFIG="$STEAM/config/config.vdf"
cp "$SHORTCUTS" "$T/shortcuts.orig"
cp "$CONFIG" "$T/config.orig"
DATA="$H/.local/share/steam-frame-fixes"
ICD="$DATA/turnip/freedreno_icd.aarch64.json"
LAUNCH="VK_ICD_FILENAMES=$ICD VK_DRIVER_FILES=$ICD %command%"

# --- Tests -------------------------------------------------------------------------------------

if [[ "$(uname -m)" != aarch64 ]]; then
    if HOME="$H" bash "$REPO_ROOT/install.sh" --from-dir "$T/dist" > "$T/log" 2>&1; then
        fail "installed on a non-ARM64 host"
    fi
    grep -q "these builds are for ARM64" "$T/log" || fail "no architecture message"
    ok "refuses non-ARM64 hosts"
fi

run_install "$H" --from-dir "$T/dist" > "$T/log" 2>&1 || { cat "$T/log"; fail "install --from-dir"; }
[[ -f "$STEAM/compatibilitytools.d/proton-frame-fixes/proton" ]] || fail "Proton not installed"
[[ -f "$DATA/turnip/libvulkan_freedreno.so" ]] || fail "Turnip not installed"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['ICD']['library_path']==sys.argv[2], d" \
    "$ICD" "$DATA/turnip/libvulkan_freedreno.so" || fail "ICD library_path"
grep -qF "$LAUNCH" "$T/log" || fail "launch options line not printed"
grep -qF 'force "Proton Experimental ARM64 (Frame fixes)"' "$T/log" || fail "display name not printed"
[[ -x "$DATA/install.sh" && -f "$DATA/steam_shortcuts.py" ]] || fail "installer copy / helper missing"
cmp -s "$SHORTCUTS" "$T/shortcuts.orig" || fail "shortcuts.vdf changed without being asked"
cmp -s "$CONFIG" "$T/config.orig" || fail "config.vdf changed without being asked"
ok "install --from-dir installs Proton, Turnip and the ICD, prints the next steps"

run_install "$H" --from-dir "$T/dist" > "$T/log" 2>&1 || fail "second install"
grep -q "already installed" "$T/log" || fail "second install is not a no-op"
ok "install is idempotent"

H2="$T/home2"
new_home "$H2"
run_install "$H2" > "$T/log" 2>&1 || { cat "$T/log"; fail "install latest from URL"; }
grep -q "Installed release $VERSION" "$T/log" || fail "latest version not resolved"
H3="$T/home3"
new_home "$H3"
run_install "$H3" --version "$VERSION" > "$T/log" 2>&1 || { cat "$T/log"; fail "install --version"; }
ok "downloads the latest or a given release"

H4="$T/home4"
new_home "$H4"
cp -r "$T/dist" "$T/tampered"
printf 'X' | dd of="$T/tampered/turnip-frame-$VERSION.tar.xz" bs=1 seek=100 conv=notrunc 2>/dev/null
if run_install "$H4" --from-dir "$T/tampered" > "$T/log" 2>&1; then
    fail "installed a tampered archive"
fi
grep -q "checksum mismatch" "$T/log" || fail "no checksum message"
[[ ! -e "$H4/.local/share/steam-frame-fixes" ]] || fail "partial install after checksum failure"
ok "refuses archives with a wrong checksum"

mkdir -p "$T/fakebin"
cat > "$T/fakebin/pgrep" <<'EOF'
#!/bin/sh
# pretend that "steam" is running
[ "$2" = steam ] && exit 0
exit 1
EOF
chmod +x "$T/fakebin/pgrep"
if PATH="$T/fakebin:$PATH" run_install "$H" --from-dir "$T/dist" --set-launch-options --yes > "$T/log" 2>&1; then
    fail "changed shortcuts while Steam was running"
fi
grep -q "Steam is running" "$T/log" || fail "no Steam running message"
cmp -s "$SHORTCUTS" "$T/shortcuts.orig" || fail "shortcuts changed while Steam was running"
ok "refuses to change Steam files while Steam is running"

run_install "$H" --from-dir "$T/dist" --set-launch-options --set-compat-tool --yes > "$T/log" 2>&1 \
    || { cat "$T/log"; fail "--set-launch-options --set-compat-tool"; }
opts="$(python3 "$DATA/steam_shortcuts.py" list --shortcuts "$SHORTCUTS" --match ARM64.exe --format json \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["launch_options"])')"
[[ "$opts" == "VK_ICD_FILENAMES=$ICD VK_DRIVER_FILES=$ICD PROTON_LOG=1 %command% -console" ]] \
    || fail "launch options: $opts"
grep -A2 "\"$WOW_APPID\"" "$CONFIG" | grep -q '"proton_frame_fixes"' || fail "compat tool not set"
grep -q "^compat $WOW_APPID proton_10$" "$DATA/state" || fail "previous compat tool not recorded"
grep -qF "already set for the matching shortcuts" "$T/log" || fail "summary does not mention the launch options"
ok "--set-launch-options and --set-compat-tool update the matching shortcut"

run_install "$H" --from-dir "$T/dist" --set-launch-options --set-compat-tool --yes > "$T/log" 2>&1 || fail "repeat"
[[ "$(grep -c "^compat $WOW_APPID " "$DATA/state")" -eq 1 ]] || fail "state recorded twice"
grep -q "^compat $WOW_APPID proton_10$" "$DATA/state" || fail "previous tool overwritten by repeat"
ok "repeating the shortcut changes keeps the original previous tool"

cat > "$H/steam-$WOW_APPID.log" <<'EOF'
info:  Using "Turnip Adreno (TM) 750" with driver: "/run/host/usr/lib/libvulkan_freedreno.so"
MESA: error: compile failed! ((null):(null))
EOF
HOME="$H" bash "$DATA/install.sh" --doctor > "$T/log" 2>&1 || fail "--doctor"
grep -q "ICD points to the installed driver" "$T/log" || fail "doctor: ICD"
grep -q "ntdll.dll fix literal: 300" "$T/log" || fail "doctor: ntdll"
grep -q "PROBLEM: the system driver is used" "$T/log" || fail "doctor: host driver"
grep -q "compile failed" "$T/log" || fail "doctor: compile failed"
echo "info:  Using \"Turnip Adreno (TM) 750\" with driver: \"$DATA/turnip/libvulkan_freedreno.so\"" > "$H/steam-$WOW_APPID.log"
HOME="$H" bash "$DATA/install.sh" --doctor > "$T/log" 2>&1 || fail "--doctor"
grep -q "OK: Using" "$T/log" || fail "doctor: our driver"
ok "--doctor reports the installation and the driver used in the Proton log"

HOME="$H" bash "$DATA/install.sh" --uninstall > "$T/log" 2>&1 || { cat "$T/log"; fail "--uninstall"; }
[[ ! -e "$STEAM/compatibilitytools.d/proton-frame-fixes" && ! -e "$DATA" ]] || fail "files left after uninstall"
cmp -s "$SHORTCUTS" "$T/shortcuts.orig" || fail "shortcuts.vdf not restored"
cmp -s "$CONFIG" "$T/config.orig" || { diff "$T/config.orig" "$CONFIG" || true; fail "config.vdf not restored"; }
ls "$SHORTCUTS".frame-fixes-*.bak >/dev/null 2>&1 || fail "backup not kept"
ok "--uninstall removes the files and restores shortcuts.vdf and config.vdf exactly"

HOME="$H2" bash "$REPO_ROOT/install.sh" --uninstall > "$T/log" 2>&1 || fail "uninstall without Steam changes"
[[ ! -e "$H2/.local/share/steam-frame-fixes" ]] || fail "uninstall left files"
ok "--uninstall works when no Steam files were changed"

echo "All $pass tests passed."
