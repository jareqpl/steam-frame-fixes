"""Test helpers: build synthetic Steam files and read them back (binary shortcuts.vdf, text config.vdf)."""

import os
import re
import struct

# --- Building a binary shortcuts.vdf -----------------------------------------------------------


def s(key, value):
    return b"\x01" + key.encode() + b"\0" + value.encode() + b"\0"


def i32(key, value):
    return b"\x02" + key.encode() + b"\0" + struct.pack("<i", value)


def u64(key, value):
    return b"\x07" + key.encode() + b"\0" + struct.pack("<Q", value)


def m(key, *items):
    return b"\x00" + key.encode() + b"\0" + b"".join(items) + b"\x08"


def shortcut(index, appid, name, exe, launch="", tags=(), extra=b""):
    return m(str(index),
             i32("appid", appid),
             s("AppName", name),
             s("Exe", exe),
             s("StartDir", '"' + os.path.dirname(exe.strip('"')) + '/"'),
             s("icon", ""),
             s("ShortcutPath", ""),
             s("LaunchOptions", launch),
             i32("IsHidden", 0),
             i32("AllowDesktopConfig", 1),
             i32("AllowOverlay", 1),
             i32("OpenVR", 0),
             i32("Devkit", 0),
             s("DevkitGameID", ""),
             i32("DevkitOverrideAppID", 0),
             i32("LastPlayTime", 1758000000),
             s("FlatpakAppID", ""),
             s("sortas", ""),
             extra,
             m("tags", *[s(str(i), t) for i, t in enumerate(tags)]))


WOW_APPID = (-1294003210) & 0xFFFFFFFF  # 3000964086
BNET_EXE = '"/home/steamos/Games/Battle.net/Battle.net Launcher.exe"'
WOW_EXE = ('"/home/steamos/.local/share/Steam/steamapps/compatdata/3000000000/pfx/drive_c/'
           'Program Files (x86)/World of Warcraft/_classic_beta_/WowB-ARM64.exe"')


def sample_shortcuts(wow_name="WoW Forever"):
    return m(
        "shortcuts",
        shortcut(0, -1951453210, "Battle.net", BNET_EXE, tags=("Favorites",)),
        shortcut(1, -1294003210, wow_name, WOW_EXE, launch="PROTON_LOG=1 %command% -console",
                 extra=u64("Unknown64", 2**63 + 5)),
        shortcut(2, 123456789, "Gra żółw", '"/home/steamos/żółw.sh"', launch="-windowed"),
    ) + b"\x08"


def empty_shortcuts():
    return m("shortcuts") + b"\x08"


# config.vdf where the WoW shortcut is already mapped to another Proton
CONFIG_VDF = f""""InstallConfigStore"
{{
\t"Software"
\t{{
\t\t"Valve"
\t\t{{
\t\t\t"Steam"
\t\t\t{{
\t\t\t\t"AutoUpdateWindowEnabled"\t\t"0"
\t\t\t\t"CompatToolMapping"
\t\t\t\t{{
\t\t\t\t\t"0"
\t\t\t\t\t{{
\t\t\t\t\t\t"name"\t\t"proton_experimental"
\t\t\t\t\t\t"config"\t\t""
\t\t\t\t\t\t"priority"\t\t"75"
\t\t\t\t\t}}
\t\t\t\t\t"{WOW_APPID}"
\t\t\t\t\t{{
\t\t\t\t\t\t"name"\t\t"proton_10"
\t\t\t\t\t\t"config"\t\t""
\t\t\t\t\t\t"priority"\t\t"250"
\t\t\t\t\t}}
\t\t\t\t}}
\t\t\t\t"SteamDefaultDialog"\t\t"#app_store"
\t\t\t}}
\t\t}}
\t}}
}}
"""

# --- Reading back --------------------------------------------------------------------------------


def _parse_bin(d, i):
    out = []
    while d[i] != 8:
        t, j = d[i], d.index(b"\0", i + 1)
        k, i = d[i + 1:j].decode(), j + 1
        if t == 0:
            v, i = _parse_bin(d, i)
        elif t == 1:
            j = d.index(b"\0", i)
            v, i = d[i:j].decode(), j + 1
        else:
            n = {2: 4, 3: 4, 7: 8}[t]
            v, i = d[i:i + n], i + n
            if t == 2:
                v = struct.unpack("<i", v)[0] & 0xFFFFFFFF
        out.append((k, v))
    return out, i + 1


def read_shortcuts(path):
    """{AppName: {field: value}} of a shortcuts.vdf; fails on anything that is not well-formed."""
    with open(path, "rb") as f:
        data = f.read()
    root, end = _parse_bin(data, 0)
    assert end == len(data), "trailing bytes"
    return {dict(sc)["AppName"]: dict(sc) for _, sc in root[0][1]}


def read_text_vdf(path):
    """Nested dicts of a text VDF file; fails on unbalanced braces or a key without a value."""
    with open(path) as f:
        tokens = re.findall(r'"((?:\\.|[^"\\])*)"|([{}])', f.read())
    pos = 0

    def block(closing):
        nonlocal pos
        d = {}
        while pos < len(tokens):
            key, brace = tokens[pos]
            pos += 1
            if brace == "}":
                assert closing, "unexpected }"
                return d
            assert not brace, "unexpected {"
            value, vbrace = tokens[pos]
            pos += 1
            assert vbrace != "}", "key without value"
            d[key] = block(True) if vbrace == "{" else value
        assert not closing, "missing }"
        return d

    return block(False)


def compat_mapping(path):
    return read_text_vdf(path)["InstallConfigStore"]["Software"]["Valve"]["Steam"]["CompatToolMapping"]
