#!/bin/bash
# Minimal setup: Proton (Frame fixes) + Turnip for the non-Steam shortcut named "WoW Forever".
set -euo pipefail
VER=v0.1-exp-20260917b
URL=https://github.com/jareqpl/steam-frame-fixes/releases/download/$VER
STEAM=~/.local/share/Steam
DIR=~/.local/share/steam-frame-fixes
ICD=$DIR/turnip/freedreno_icd.aarch64.json

pgrep -x steam >/dev/null && { echo "Exit Steam first (Steam > Exit)."; exit 1; }
get() { if [ -f "$1" ]; then cat "$1"; else curl -fL "$URL/$1"; fi; }  # local file or download

# 1. Proton -> compatibility tool
mkdir -p "$STEAM/compatibilitytools.d" "$DIR"
get "proton-frame-$VER.tar.xz" | tar -xJ -C "$STEAM/compatibilitytools.d"

# 2. Turnip + Vulkan ICD file pointing to it
get "turnip-frame-$VER.tar.xz" | tar -xJ -C "$DIR"
sed "s|@LIBPATH@|$DIR/turnip/libvulkan_freedreno.so|" "$ICD.in" > "$ICD"

# 3. Shortcut "WoW Forever": launch options (shortcuts.vdf) and compatibility tool (config.vdf)
python3 - "$STEAM" "VK_ICD_FILENAMES=$ICD VK_DRIVER_FILES=$ICD %command%" <<'EOF'
import glob, re, struct, sys
steam, opts = sys.argv[1], sys.argv[2].encode()

def parse(d, i):  # binary VDF map -> [[type, key, value], ...]
    m = []
    while d[i] != 8:
        t, j = d[i], d.index(b"\0", i + 1)
        k, i = d[i + 1:j], j + 1
        if t == 0: v, i = parse(d, i)
        elif t == 1: j = d.index(b"\0", i); v, i = d[i:j], j + 1
        else: n = {2: 4, 3: 4, 7: 8}[t]; v, i = d[i:i + n], i + n
        m.append([t, k, v])
    return m, i + 1

def dump(m):
    return b"".join(bytes([t]) + k + b"\0" + (dump(v) if t == 0 else v + b"\0" if t == 1 else v)
                    for t, k, v in m) + b"\x08"

appids = []
for path in glob.glob(steam + "/userdata/*/config/shortcuts.vdf"):
    root, _ = parse(open(path, "rb").read(), 0)
    found = len(appids)
    for sc in root[0][2]:
        f = {e[1].lower(): e for e in sc[2]}
        if f.get(b"appname", [0, 0, b""])[2].strip().lower() == b"wow forever":
            appids.append(struct.unpack("<i", f[b"appid"][2])[0] & 0xFFFFFFFF)
            if b"launchoptions" in f: f[b"launchoptions"][2] = opts
            else: sc[2].append([1, b"LaunchOptions", opts])
    if len(appids) > found: open(path, "wb").write(dump(root))
if not appids:
    sys.exit('No non-Steam shortcut named "WoW Forever". Rename the game in Steam and run this again.')

path = steam + "/config/config.vdf"
text = open(path).read()
for a in appids:
    text = re.sub(r'\s*"%d"\s*\{[^{}]*\}' % a, "", text)  # drop an old mapping of this shortcut
    text, n = re.subn(r'("CompatToolMapping"\s*\{)',
                      r'\1 "%d" { "name" "proton_frame_fixes" "config" "" "priority" "250" }' % a, text)
    if not n: sys.exit("CompatToolMapping not found in " + path)
open(path, "w").write(text)
EOF

echo "Done. Start Steam and launch \"WoW Forever\"."
