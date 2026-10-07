#!/bin/bash
# Undo install-min.sh: remove Proton (Frame fixes), Turnip, and the launch options and compatibility tool it set.
set -euo pipefail
STEAM=~/.local/share/Steam
DIR=~/.local/share/steam-frame-fixes

# 1. Shortcuts using our driver (found by their launch options, so renamed shortcuts are found too)
#    and compatibility tool mappings to the Frame fixes Proton
python3 - "$STEAM" "$DIR" <<'EOF'
import glob, re, sys
steam, ours = sys.argv[1], sys.argv[2].encode()

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

for path in glob.glob(steam + "/userdata/*/config/shortcuts.vdf"):
    root, _ = parse(open(path, "rb").read(), 0)
    changed = False
    for sc in root[0][2]:
        for e in sc[2]:
            if e[1].lower() == b"launchoptions" and ours in e[2]:
                opts = re.sub(rb"(VK_ICD_FILENAMES|VK_DRIVER_FILES)=\S*steam-frame-fixes\S*\s*", b"", e[2]).strip()
                e[2], changed = (b"" if opts == b"%command%" else opts), True
    if changed: open(path, "wb").write(dump(root))

path = steam + "/config/config.vdf"
text = open(path).read()
text = re.sub(r'\s*"\d+"\s*\{[^{}]*"name"\s*"proton_frame_fixes"[^{}]*\}', "", text)
open(path, "w").write(text)
EOF

# 2. Installed files
rm -rf "$STEAM/compatibilitytools.d/proton-frame-fixes" "$DIR"

echo "Done. Restart Steam."
