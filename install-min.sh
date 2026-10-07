#!/bin/bash
# Steam Frame fixes for World of Warcraft (ARM64): downloads Proton (Frame fixes) and Turnip from the release,
# verifies them and sets them up for the non-Steam shortcut named "WoW Forever". Usage: bash install-min.sh
set -euo pipefail
VER=v0.1-exp-20260917b
URL=${FRAME_FIXES_URL:-https://github.com/jareqpl/steam-frame-fixes/releases/download/$VER}
STEAM=~/.local/share/Steam
DIR=~/.local/share/steam-frame-fixes
ICD=$DIR/turnip/freedreno_icd.aarch64.json
PROTON=proton-frame-$VER.tar.xz
TURNIP=turnip-frame-$VER.tar.xz

grep -qia "wow forever" "$STEAM"/userdata/*/config/shortcuts.vdf 2>/dev/null \
    || { echo 'No non-Steam shortcut named "WoW Forever". Rename the game in Steam and run this again.'; exit 1; }

# 1. Download (files next to the script are used instead, if present) and verify
mkdir -p "$STEAM/compatibilitytools.d" "$DIR"
TMP=$(mktemp -d "$DIR/.download.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
for f in SHA256SUMS "$PROTON" "$TURNIP"; do
    if [ -f "$f" ]; then cp "$f" "$TMP/"; else echo "Downloading $f"; curl -fL --retry 3 -o "$TMP/$f" "$URL/$f"; fi
done
(cd "$TMP" && grep -E "  ($PROTON|$TURNIP)\$" SHA256SUMS > sums && [ "$(wc -l < sums)" = 2 ] && sha256sum -c --quiet sums) \
    || { echo "Checksum error, try again."; exit 1; }

# 2. Proton -> compatibility tool
tar -xJf "$TMP/$PROTON" -C "$STEAM/compatibilitytools.d"

# 3. Turnip + Vulkan ICD file pointing to it
tar -xJf "$TMP/$TURNIP" -C "$DIR"
sed "s|@LIBPATH@|$DIR/turnip/libvulkan_freedreno.so|" "$ICD.in" > "$ICD"

# 4. Shortcut "WoW Forever": launch options (shortcuts.vdf) and compatibility tool (config.vdf)
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

echo "Done. Restart Steam, then launch \"WoW Forever\"."
