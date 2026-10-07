#!/usr/bin/env bash
# Test of install-min.sh and uninstall-min.sh in a fake $HOME with fake release files and synthetic
# Steam files (built by tests/vdf.py). Usage: tests/test_install_min.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}
ok() {
    echo "ok - $*"
}

VERSION="$(sed -n 's/^VER=//p' "$REPO_ROOT/install-min.sh")"

# py [args] <<'EOF' ... EOF: python with tests/vdf.py importable as "vdf"
py() {
    PYTHONPATH="$REPO_ROOT/tests" python3 - "$@"
}

# --- Fake release files, named for the version install-min.sh expects ---------------------------

out="$T/out"
mkdir -p "$out/proton/proton-frame-fixes" "$out/turnip"
echo '#!/usr/bin/env python3' > "$out/proton/proton-frame-fixes/proton"
echo "component: proton" > "$out/proton/BUILDINFO"
echo "fake driver" > "$out/turnip/libvulkan_freedreno.so"
echo '{"ICD": {"api_version": "1.4.363", "library_path": "@LIBPATH@"}, "file_format_version": "1.0.1"}' \
    > "$out/turnip/freedreno_icd.aarch64.json.in"
echo "license" > "$out/turnip/LICENSE"
echo "component: turnip" > "$out/turnip/BUILDINFO"
"$REPO_ROOT/scripts/package.sh" --version "$VERSION" --out-dir "$out" --dist-dir "$T/dist" --no-wine-src >/dev/null 2>&1 \
    || fail "package.sh failed"
cmp -s "$REPO_ROOT/install-min.sh" "$T/dist/install-min.sh" || fail "packaged install-min.sh differs"
[[ -x "$T/dist/uninstall-min.sh" ]] || fail "uninstall-min.sh not packaged"
(cd "$T/dist" && sha256sum -c --quiet SHA256SUMS) || fail "SHA256SUMS"
ok "package.sh publishes the archives, install-min.sh and uninstall-min.sh"

# --- Fake home with Steam files ------------------------------------------------------------------

H="$T/home"
STEAM="$H/.local/share/Steam"
DATA="$H/.local/share/steam-frame-fixes"
ICD="$DATA/turnip/freedreno_icd.aarch64.json"
mkdir -p "$STEAM/userdata/1234/config" "$STEAM/userdata/5678/config" "$STEAM/config"
py "$STEAM" <<'EOF'
import sys, vdf
steam = sys.argv[1]
open(steam + "/userdata/1234/config/shortcuts.vdf", "wb").write(vdf.sample_shortcuts())
open(steam + "/userdata/5678/config/shortcuts.vdf", "wb").write(vdf.empty_shortcuts())
open(steam + "/config/config.vdf", "w").write(vdf.CONFIG_VDF)
EOF
cp "$STEAM/userdata/5678/config/shortcuts.vdf" "$T/other.orig"

run_min() {
    (cd "$T/dist" && HOME="$H" bash "$T/dist/install-min.sh")
}

check_installed() {
    py "$STEAM" "$ICD" "$DATA" <<'EOF'
import json, sys, vdf
steam, icd, data = sys.argv[1:]
assert json.load(open(icd))["ICD"]["library_path"] == data + "/turnip/libvulkan_freedreno.so"
sc = vdf.read_shortcuts(steam + "/userdata/1234/config/shortcuts.vdf")
assert sc["WoW Forever"]["LaunchOptions"] == f"VK_ICD_FILENAMES={icd} VK_DRIVER_FILES={icd} %command%", sc["WoW Forever"]
assert sc["Battle.net"]["LaunchOptions"] == "" and sc["Gra żółw"]["LaunchOptions"] == "-windowed"
mapping = vdf.compat_mapping(steam + "/config/config.vdf")
assert mapping[str(vdf.WOW_APPID)]["name"] == "proton_frame_fixes", mapping
assert mapping["0"]["name"] == "proton_experimental"
assert open(steam + "/config/config.vdf").read().count(f'"{vdf.WOW_APPID}"') == 1
EOF
}

# --- install-min.sh ------------------------------------------------------------------------------

run_min > "$T/log" 2>&1 || { cat "$T/log"; fail "install-min.sh"; }
[[ -f "$STEAM/compatibilitytools.d/proton-frame-fixes/proton" ]] || fail "Proton not installed"
check_installed || fail "Steam files after install"
cmp -s "$T/other.orig" "$STEAM/userdata/5678/config/shortcuts.vdf" || fail "other user's shortcuts changed"
grep -q "Restart Steam" "$T/log" || fail "no restart message"
ok "installs Proton and Turnip and sets up the shortcut named \"WoW Forever\""

run_min > "$T/log" 2>&1 || { cat "$T/log"; fail "second run"; }
check_installed || fail "Steam files after the second run"
ok "running it again gives the same result"

# --- Standalone: only the script, everything downloaded and verified ---------------------------

new_home() {
    mkdir -p "$1/.local/share/Steam/userdata/1234/config" "$1/.local/share/Steam/config"
    py "$1/.local/share/Steam" <<'EOF'
import sys, vdf
steam = sys.argv[1]
open(steam + "/userdata/1234/config/shortcuts.vdf", "wb").write(vdf.sample_shortcuts())
open(steam + "/config/config.vdf", "w").write(vdf.CONFIG_VDF)
EOF
}

H2="$T/home2"
new_home "$H2"
mkdir -p "$T/alone"
cp "$T/dist/install-min.sh" "$T/alone/"
(cd "$T/alone" && HOME="$H2" FRAME_FIXES_URL="file://$T/dist" bash install-min.sh) > "$T/log" 2>&1 \
    || { cat "$T/log"; fail "standalone install"; }
grep -q "Downloading proton-frame-$VERSION.tar.xz" "$T/log" || fail "did not download"
[[ -f "$H2/.local/share/Steam/compatibilitytools.d/proton-frame-fixes/proton" ]] || fail "standalone: Proton not installed"
compgen -G "$H2/.local/share/steam-frame-fixes/.download.*" >/dev/null && fail "download directory left behind"
ok "standalone: downloads the archives, verifies them and installs"

H3="$T/home3"
new_home "$H3"
cp -r "$T/dist" "$T/tampered"
printf 'X' | dd of="$T/tampered/turnip-frame-$VERSION.tar.xz" bs=1 seek=100 conv=notrunc 2>/dev/null
if (cd "$T/alone" && HOME="$H3" FRAME_FIXES_URL="file://$T/tampered" bash install-min.sh) > "$T/log" 2>&1; then
    fail "installed a tampered archive"
fi
grep -q "Checksum error" "$T/log" || fail "no checksum message"
[[ ! -e "$H3/.local/share/Steam/compatibilitytools.d/proton-frame-fixes" ]] || fail "installed before verifying"
ok "standalone: refuses an archive with a wrong checksum"

# --- uninstall-min.sh: the user added PROTON_LOG=1 and renamed the shortcut ---------------------

py "$STEAM/userdata/1234/config/shortcuts.vdf" <<'EOF'
import sys
p = sys.argv[1]
d = open(p, "rb").read()
d = d.replace(b"VK_ICD_FILENAMES=", b"PROTON_LOG=1 VK_ICD_FILENAMES=", 1).replace(b"WoW Forever", b"My WoW")
open(p, "wb").write(d)
EOF
HOME="$H" bash "$T/dist/uninstall-min.sh" > "$T/log" 2>&1 || { cat "$T/log"; fail "uninstall-min.sh"; }
[[ ! -e "$STEAM/compatibilitytools.d/proton-frame-fixes" && ! -e "$DATA" ]] || fail "files left after uninstall"
py "$STEAM" <<'EOF' || fail "Steam files after uninstall"
import sys, vdf
steam = sys.argv[1]
sc = vdf.read_shortcuts(steam + "/userdata/1234/config/shortcuts.vdf")
assert sc["My WoW"]["LaunchOptions"] == "PROTON_LOG=1 %command%", sc["My WoW"]
assert sc["Battle.net"]["LaunchOptions"] == "" and sc["Gra żółw"]["LaunchOptions"] == "-windowed"
assert list(vdf.compat_mapping(steam + "/config/config.vdf")) == ["0"]
assert "proton_frame_fixes" not in open(steam + "/config/config.vdf").read()
EOF
grep -q "Restart Steam" "$T/log" || fail "no restart message"
cmp -s "$T/other.orig" "$STEAM/userdata/5678/config/shortcuts.vdf" || fail "other user's shortcuts changed"
ok "uninstall-min.sh removes the files, our launch options (also after a rename) and the Proton mapping"

cp "$STEAM/config/config.vdf" "$T/config.after"
HOME="$H" bash "$T/dist/uninstall-min.sh" > "$T/log" 2>&1 || fail "second uninstall"
cmp -s "$T/config.after" "$STEAM/config/config.vdf" || fail "second uninstall changed config.vdf"
ok "uninstall-min.sh can run again"

# --- No shortcut named "WoW Forever" -------------------------------------------------------------

cp "$T/other.orig" "$STEAM/userdata/1234/config/shortcuts.vdf"
if run_min > "$T/log" 2>&1; then
    fail "succeeded without a shortcut named WoW Forever"
fi
grep -q 'No non-Steam shortcut named "WoW Forever"' "$T/log" || fail "no missing-shortcut message"
ok "explains a missing \"WoW Forever\" shortcut"

echo "All tests passed."
