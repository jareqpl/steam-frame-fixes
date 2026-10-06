#!/usr/bin/env bash
# Test of install-min.sh in a fake $HOME with fake release files and synthetic Steam files.
# Usage: tests/test_install_min.sh

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
WOW_APPID=3000964086

# Fake release files, named for the version install-min.sh expects
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

H="$T/home"
STEAM="$H/.local/share/Steam"
mkdir -p "$STEAM/userdata/1234/config" "$STEAM/userdata/5678/config" "$STEAM/config"
python3 - "$STEAM" "$WOW_APPID" <<EOF
import sys
sys.path.insert(0, "$REPO_ROOT/tools/tests")
import test_steam_shortcuts as t
steam, wow = sys.argv[1], sys.argv[2]
data = t.sample_shortcuts().replace(b"World of Warcraft Classic Beta (ARM64)", b"WoW Forever")
open(steam + "/userdata/1234/config/shortcuts.vdf", "wb").write(data)
open(steam + "/userdata/5678/config/shortcuts.vdf", "wb").write(t.m("shortcuts") + b"\x08")
open(steam + "/config/config.vdf", "w").write(t.CONFIG_VDF.replace("2343328086", wow))
EOF
cp "$STEAM/userdata/5678/config/shortcuts.vdf" "$T/other.orig"

run_min() {
    (cd "$T/dist" && HOME="$H" bash "$REPO_ROOT/install-min.sh")
}

check() {
    python3 - "$STEAM" "$H/.local/share/steam-frame-fixes" "$WOW_APPID" <<EOF
import json, sys
sys.path.insert(0, "$REPO_ROOT/tools")
import steam_shortcuts as ss
steam, data, wow = sys.argv[1], sys.argv[2], int(sys.argv[3])
icd = data + "/turnip/freedreno_icd.aarch64.json"
assert json.load(open(icd))["ICD"]["library_path"] == data + "/turnip/libvulkan_freedreno.so"
sc = {s.name: s for s in ss.shortcuts_of(ss.parse_binary_vdf(open(steam + "/userdata/1234/config/shortcuts.vdf", "rb").read()))}
assert sc["WoW Forever"].launch_options == f"VK_ICD_FILENAMES={icd} VK_DRIVER_FILES={icd} %command%", sc["WoW Forever"].launch_options
assert sc["Battle.net"].launch_options == "" and sc["Gra żółw"].launch_options == "-windowed"
mapping = ss._steam_node(ss.parse_text_vdf(open(steam + "/config/config.vdf").read())).child("CompatToolMapping")
entries = [c for c in mapping.value if c.key == str(wow)]
assert len(entries) == 1 and entries[0].child("name").value == "proton_frame_fixes", [c.key for c in mapping.value]
assert mapping.child("0").child("name").value == "proton_experimental"
EOF
}

run_min > "$T/log" 2>&1 || { cat "$T/log"; fail "install-min.sh"; }
[[ -f "$STEAM/compatibilitytools.d/proton-frame-fixes/proton" ]] || fail "Proton not installed"
check || fail "Steam files"
cmp -s "$T/other.orig" "$STEAM/userdata/5678/config/shortcuts.vdf" || fail "other user's shortcuts changed"
ok "installs Proton and Turnip and sets up the shortcut named \"WoW Forever\""

run_min > "$T/log" 2>&1 || { cat "$T/log"; fail "second run"; }
check || fail "Steam files after the second run"
ok "running it again gives the same result"

mkdir -p "$T/fakebin"
cat > "$T/fakebin/pgrep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/fakebin/pgrep"
if (cd "$T/dist" && PATH="$T/fakebin:$PATH" HOME="$H" bash "$REPO_ROOT/install-min.sh") > "$T/log" 2>&1; then
    fail "ran while Steam was running"
fi
grep -q "Exit Steam first" "$T/log" || fail "no Steam running message"
ok "refuses to run while Steam is running"

cp "$T/other.orig" "$STEAM/userdata/1234/config/shortcuts.vdf"
if run_min > "$T/log" 2>&1; then
    fail "succeeded without a shortcut named WoW Forever"
fi
grep -q 'No non-Steam shortcut named "WoW Forever"' "$T/log" || fail "no missing-shortcut message"
ok "explains a missing \"WoW Forever\" shortcut"

echo "All install-min.sh tests passed."
