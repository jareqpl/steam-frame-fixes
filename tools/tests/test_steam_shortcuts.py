"""Tests for tools/steam_shortcuts.py. Run: python3 -m unittest discover -s tools/tests"""

import contextlib
import glob
import io
import os
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import steam_shortcuts as ss  # noqa: E402

# ------------------------------------------------------------------------------------------------
# Independent builder for binary VDF test data (does not use the module's writer)
# ------------------------------------------------------------------------------------------------


def s(key, value):
    return b"\x01" + key.encode() + b"\0" + value.encode() + b"\0"


def i32(key, value):
    return b"\x02" + key.encode() + b"\0" + struct.pack("<i", value)


def u64(key, value):
    return b"\x07" + key.encode() + b"\0" + struct.pack("<Q", value)


def m(key, *items):
    return b"\x00" + key.encode() + b"\0" + b"".join(items) + b"\x08"


def shortcut(index, appid, name, exe, launch="", tags=(), extra=b""):
    fields = []
    if appid is not None:
        fields.append(i32("appid", appid))
    fields += [
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
        m("tags", *[s(str(i), t) for i, t in enumerate(tags)]),
    ]
    return m(str(index), *fields)


WOW_EXE = '"/home/steamos/.local/share/Steam/steamapps/compatdata/3000000000/pfx/drive_c/Program Files (x86)/World of Warcraft/_classic_beta_/WowB-ARM64.exe"'
BNET_EXE = '"/home/steamos/Games/Battle.net/Battle.net Launcher.exe"'


def sample_shortcuts():
    return m(
        "shortcuts",
        shortcut(0, -1951453210, "Battle.net", BNET_EXE, tags=("Favorites",)),
        shortcut(1, -1294003210, "World of Warcraft Classic Beta (ARM64)", WOW_EXE,
                 launch="PROTON_LOG=1 %command% -console", extra=u64("Unknown64", 2**63 + 5)),
        shortcut(2, 123456789, "Gra żółw", '"/home/steamos/żółw.sh"', launch="-windowed"),
    ) + b"\x08"


CONFIG_VDF = """"InstallConfigStore"
{
\t"Software"
\t{
\t\t"Valve"
\t\t{
\t\t\t"Steam"
\t\t\t{
\t\t\t\t"AutoUpdateWindowEnabled"\t\t"0"
\t\t\t\t"CompatToolMapping"
\t\t\t\t{
\t\t\t\t\t"0"
\t\t\t\t\t{
\t\t\t\t\t\t"name"\t\t"proton_experimental"
\t\t\t\t\t\t"config"\t\t""
\t\t\t\t\t\t"priority"\t\t"75"
\t\t\t\t\t}
\t\t\t\t\t"2343328086"
\t\t\t\t\t{
\t\t\t\t\t\t"name"\t\t"proton_10"
\t\t\t\t\t\t"config"\t\t""
\t\t\t\t\t\t"priority"\t\t"250"
\t\t\t\t\t}
\t\t\t\t}
\t\t\t\t"SteamDefaultDialog"\t\t"#app_store"
\t\t\t}
\t\t}
\t}
\t"Music"
\t{
\t\t"LocalLibrary"\t\t"/home/steamos/Music \\"quoted\\""
\t}
}
"""

CONFIG_VDF_NO_MAPPING = """"InstallConfigStore"
{
\t"Software"
\t{
\t\t"valve"
\t\t{
\t\t\t"Steam"
\t\t\t{
\t\t\t\t"AutoUpdateWindowEnabled"\t\t"0"
\t\t\t}
\t\t}
\t}
}
"""

ENV = [("VK_ICD_FILENAMES", "/home/steamos/.local/share/steam-frame-fixes/turnip/freedreno_icd.aarch64.json"),
       ("VK_DRIVER_FILES", "/home/steamos/.local/share/steam-frame-fixes/turnip/freedreno_icd.aarch64.json")]
ENV_ARGS = [a for n, v in ENV for a in ("--env", f"{n}={v}")]
OURS = " ".join(f"{n}={v}" for n, v in ENV)


def run_cli(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = ss.main([str(a) for a in argv])
    return rc, out.getvalue(), err.getvalue()


# ------------------------------------------------------------------------------------------------


class BinaryVdfTest(unittest.TestCase):
    def test_round_trip_is_byte_identical(self):
        data = sample_shortcuts()
        self.assertEqual(ss.dump_binary_vdf(ss.parse_binary_vdf(data)), data)

    def test_empty_shortcuts(self):
        data = m("shortcuts") + b"\x08"
        root = ss.parse_binary_vdf(data)
        self.assertEqual(ss.shortcuts_of(root), [])
        self.assertEqual(ss.dump_binary_vdf(root), data)

    def test_fields_and_unsigned_appid(self):
        sc = ss.shortcuts_of(ss.parse_binary_vdf(sample_shortcuts()))
        self.assertEqual([x.index_key for x in sc], ["0", "1", "2"])
        self.assertEqual(sc[1].name, "World of Warcraft Classic Beta (ARM64)")
        self.assertEqual(sc[1].exe, WOW_EXE)
        self.assertEqual(sc[1].launch_options, "PROTON_LOG=1 %command% -console")
        self.assertEqual(sc[0].appid, (-1951453210) & 0xFFFFFFFF)
        self.assertEqual(sc[0].appid, 2343514086)
        self.assertEqual(sc[2].appid, 123456789)
        self.assertEqual(sc[2].name, "Gra żółw")

    def test_appid_fallback_without_field(self):
        data = m("shortcuts", shortcut(0, None, "Old", '"/x.exe"')) + b"\x08"
        sc = ss.shortcuts_of(ss.parse_binary_vdf(data))[0]
        self.assertEqual(sc.appid, zlib.crc32(b'"/x.exe"Old') | 0x80000000)

    def test_matching_is_case_insensitive_on_exe_and_name(self):
        sc = ss.shortcuts_of(ss.parse_binary_vdf(sample_shortcuts()))
        self.assertEqual([x.index_key for x in sc if x.matches(["arm64.exe"])], ["1"])
        self.assertEqual([x.index_key for x in sc if x.matches(["world of warcraft"])], ["1"])
        self.assertEqual([x.index_key for x in sc if x.matches(["nothing", "battle.net"])], ["0"])
        self.assertEqual(len([x for x in sc if x.matches([])]), 3)

    def test_rejects_broken_files(self):
        data = sample_shortcuts()
        for bad in (data[:-1], data[:-30], data + b"\x00", b"\x00shortcuts\x00\x09k\x00\x08\x08", b""):
            with self.assertRaises(ss.VdfError, msg=repr(bad[-10:])):
                ss.parse_binary_vdf(bad)

    def test_corrupted_input_only_raises_vdf_error(self):
        import random
        data = sample_shortcuts()
        rnd = random.Random(1)
        samples = [data[:n] for n in range(len(data))]
        for _ in range(2000):
            b = bytearray(data)
            for _ in range(rnd.randint(1, 4)):
                b[rnd.randrange(len(b))] = rnd.randrange(256)
            samples.append(bytes(b))
        for sample in samples:
            try:
                root = ss.parse_binary_vdf(sample)
            except ss.VdfError:
                continue
            self.assertEqual(ss.dump_binary_vdf(root), sample)

    def test_set_str_keeps_other_bytes(self):
        data = sample_shortcuts()
        root = ss.parse_binary_vdf(data)
        ss.shortcuts_of(root)[1].node.set_str("LaunchOptions", "X=1 %command%")
        out = ss.dump_binary_vdf(root)
        self.assertEqual(out, data.replace(b"PROTON_LOG=1 %command% -console", b"X=1 %command%"))


class LaunchOptionsTest(unittest.TestCase):
    def test_add_to_empty(self):
        self.assertEqual(ss.add_env_to_launch_options("", ENV), f"{OURS} %command%")

    def test_add_keeps_existing_variables_and_arguments(self):
        self.assertEqual(ss.add_env_to_launch_options("PROTON_LOG=1 %command% -console", ENV),
                         f"{OURS} PROTON_LOG=1 %command% -console")

    def test_add_without_command_treats_options_as_game_arguments(self):
        self.assertEqual(ss.add_env_to_launch_options("-windowed -nosound", ENV),
                         f"{OURS} %command% -windowed -nosound")

    def test_add_replaces_old_values_without_duplicates(self):
        old = "VK_ICD_FILENAMES=/old/icd.json DXVK_HUD=1 VK_DRIVER_FILES='/old dir/icd.json' %command%"
        self.assertEqual(ss.add_env_to_launch_options(old, ENV), f"{OURS} DXVK_HUD=1 %command%")

    def test_add_does_not_touch_similar_names(self):
        old = "MY_VK_ICD_FILENAMES=1 %command%"
        self.assertEqual(ss.add_env_to_launch_options(old, ENV), f"{OURS} MY_VK_ICD_FILENAMES=1 %command%")

    def test_add_is_idempotent(self):
        for start in ("", "PROTON_LOG=1 %command% -console", "-windowed"):
            once = ss.add_env_to_launch_options(start, ENV)
            self.assertEqual(ss.add_env_to_launch_options(once, ENV), once)

    def test_values_with_spaces_are_quoted(self):
        self.assertEqual(ss.add_env_to_launch_options("", [("A", "/a b/c")]), "A='/a b/c' %command%")
        self.assertEqual(ss.remove_env_from_launch_options("A='/a b/c' B=1 %command%", ["A"]), "B=1 %command%")

    def test_remove(self):
        names = [n for n, _ in ENV]
        self.assertEqual(ss.remove_env_from_launch_options(f"{OURS} %command%", names), "")
        self.assertEqual(ss.remove_env_from_launch_options(f"{OURS} PROTON_LOG=1 %command% -console", names),
                         "PROTON_LOG=1 %command% -console")
        self.assertEqual(ss.remove_env_from_launch_options(f"{OURS} %command% -windowed", names),
                         "%command% -windowed")
        self.assertEqual(ss.remove_env_from_launch_options("-windowed", names), "-windowed")


class TextVdfTest(unittest.TestCase):
    def test_parse(self):
        nodes = ss.parse_text_vdf(CONFIG_VDF)
        steam = ss._steam_node(nodes)
        mapping = steam.child("compattoolmapping")
        self.assertEqual([c.key for c in mapping.value], ["0", "2343328086"])
        self.assertEqual(nodes[0].child("Music").child("LocalLibrary").value, '/home/steamos/Music "quoted"')

    def test_comments_conditionals_and_unquoted_tokens(self):
        nodes = ss.parse_text_vdf('// comment\nroot { key value [$WIN32]\n "k2" "v2" // c\n sub { } }\n')
        self.assertEqual([c.key for c in nodes[0].value], ["key", "k2", "sub"])
        self.assertEqual(nodes[0].child("key").value, "value")

    def test_rejects_broken_text(self):
        for bad in ('"a" {', '"a" { "b" }', '"a" "b" }', '"a'):
            with self.assertRaises(ss.VdfError, msg=bad):
                ss.parse_text_vdf(bad)

    def test_truncated_text_only_raises_vdf_error(self):
        for n in range(len(CONFIG_VDF)):
            try:
                ss.set_compat_tool_text(CONFIG_VDF[:n], 1, "x")
                ss.unset_compat_tool_text(CONFIG_VDF[:n], 2343328086)
            except ss.VdfError:
                pass

    def test_set_new_mapping_and_unset_restores_original(self):
        new, previous = ss.set_compat_tool_text(CONFIG_VDF, 3000966086, "proton_frame_fixes")
        self.assertIsNone(previous)
        expected_block = ('\t\t\t\t\t"3000966086"\n\t\t\t\t\t{\n'
                          '\t\t\t\t\t\t"name"\t\t"proton_frame_fixes"\n'
                          '\t\t\t\t\t\t"config"\t\t""\n'
                          '\t\t\t\t\t\t"priority"\t\t"250"\n'
                          '\t\t\t\t\t}\n')
        self.assertIn(expected_block + '\t\t\t\t}\n\t\t\t\t"SteamDefaultDialog"', new)
        self.assertEqual(new.replace(expected_block, ""), CONFIG_VDF)
        mapping = ss._steam_node(ss.parse_text_vdf(new)).child("CompatToolMapping")
        self.assertEqual(mapping.child("3000966086").child("name").value, "proton_frame_fixes")
        self.assertEqual(ss.set_compat_tool_text(new, 3000966086, "proton_frame_fixes"), (new, "proton_frame_fixes"))

        restored, removed = ss.unset_compat_tool_text(new, 3000966086, "proton_frame_fixes")
        self.assertEqual(removed, "proton_frame_fixes")
        self.assertEqual(restored, CONFIG_VDF)

    def test_set_existing_mapping_replaces_only_the_name(self):
        new, previous = ss.set_compat_tool_text(CONFIG_VDF, 2343328086, "proton_frame_fixes")
        self.assertEqual(previous, "proton_10")
        self.assertEqual(new, CONFIG_VDF.replace('"name"\t\t"proton_10"', '"name"\t\t"proton_frame_fixes"'))

    def test_unset_only_removes_our_tool(self):
        self.assertEqual(ss.unset_compat_tool_text(CONFIG_VDF, 2343328086, "proton_frame_fixes"), (CONFIG_VDF, None))
        self.assertEqual(ss.unset_compat_tool_text(CONFIG_VDF, 1, "proton_frame_fixes"), (CONFIG_VDF, None))
        new, removed = ss.unset_compat_tool_text(CONFIG_VDF, 2343328086)
        self.assertEqual(removed, "proton_10")
        self.assertNotIn("2343328086", new)
        self.assertIn('"0"', new)
        ss.parse_text_vdf(new)

    def test_creates_missing_mapping_block(self):
        new, previous = ss.set_compat_tool_text(CONFIG_VDF_NO_MAPPING, 42, "proton_frame_fixes")
        self.assertIsNone(previous)
        self.assertIn('\t\t\t\t"CompatToolMapping"\n\t\t\t\t{\n\t\t\t\t\t"42"\n', new)
        self.assertTrue(new.startswith(CONFIG_VDF_NO_MAPPING[:CONFIG_VDF_NO_MAPPING.index('\t\t\t}')]))
        mapping = ss._steam_node(ss.parse_text_vdf(new)).child("CompatToolMapping")
        self.assertEqual(mapping.child("42").child("priority").value, "250")

    def test_missing_steam_section(self):
        with self.assertRaises(ss.VdfError):
            ss.set_compat_tool_text('"InstallConfigStore"\n{\n}\n', 1, "x")


class CliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.shortcuts = os.path.join(self.tmp.name, "shortcuts.vdf")
        self.config = os.path.join(self.tmp.name, "config.vdf")
        self.original = sample_shortcuts()
        with open(self.shortcuts, "wb") as f:
            f.write(self.original)
        with open(self.config, "w", encoding="utf-8") as f:
            f.write(CONFIG_VDF)

    def read(self, path=None):
        with open(path or self.shortcuts, "rb") as f:
            return f.read()

    def backups(self, path=None):
        return glob.glob((path or self.shortcuts) + ".frame-fixes-*.bak")

    def test_list(self):
        rc, out, _ = run_cli("list", "--shortcuts", self.shortcuts, "--match", "ARM64.exe", "--format", "appid")
        self.assertEqual((rc, out), (0, f"{(-1294003210) & 0xFFFFFFFF}\n"))
        rc, out, _ = run_cli("list", "--shortcuts", self.shortcuts, "--match", "nope")
        self.assertEqual(rc, 3)
        rc, out, _ = run_cli("list", "--shortcuts", self.shortcuts, "--format", "json")
        self.assertIn('"Gra żółw"', out)

    def test_set_and_unset_launch_options(self):
        args = ["--shortcuts", self.shortcuts, "--match", "ARM64.exe", "--match", "World of Warcraft",
                "--yes", "--allow-running"]
        rc, out, err = run_cli("set-launch-options", *args, *ENV_ARGS)
        self.assertEqual(rc, 0, err)
        self.assertEqual(len(self.backups()), 1)
        with open(self.backups()[0], "rb") as f:
            self.assertEqual(f.read(), self.original)
        changed = self.read()
        self.assertEqual(changed, self.original.replace(
            b"PROTON_LOG=1 %command% -console", f"{OURS} PROTON_LOG=1 %command% -console".encode()))

        rc, out, _ = run_cli("set-launch-options", *args, *ENV_ARGS)
        self.assertEqual((rc, out.strip()), (0, "Nothing to change."))
        self.assertEqual(self.read(), changed)
        self.assertEqual(len(self.backups()), 1)

        rc, _, err = run_cli("unset-launch-options", *args, "--env", "VK_ICD_FILENAMES", "--env", "VK_DRIVER_FILES")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.read(), self.original)

    def test_dry_run_and_no_match_do_not_write(self):
        args = ["--shortcuts", self.shortcuts, "--allow-running", "--yes"]
        rc, out, _ = run_cli("set-launch-options", *args, "--match", "ARM64", "--dry-run", *ENV_ARGS)
        self.assertEqual(rc, 0)
        self.assertIn("after:", out)
        rc, _, _ = run_cli("set-launch-options", *args, "--match", "nope", *ENV_ARGS)
        self.assertEqual(rc, 3)
        self.assertEqual(self.read(), self.original)
        self.assertEqual(self.backups(), [])

    def test_requires_confirmation_when_not_interactive(self):
        stdin = sys.stdin
        sys.stdin = io.StringIO("")
        try:
            rc, _, err = run_cli("set-launch-options", "--shortcuts", self.shortcuts, "--allow-running",
                                 "--match", "ARM64", *ENV_ARGS)
        finally:
            sys.stdin = stdin
        self.assertEqual(rc, 1)
        self.assertIn("--yes", err)
        self.assertEqual(self.read(), self.original)

    def test_refuses_file_that_does_not_round_trip(self):
        # Unparseable content (here: trailing bytes after the root map) must never be rewritten.
        with open(self.shortcuts, "ab") as f:
            f.write(b"\x08")
        rc, _, err = run_cli("set-launch-options", "--shortcuts", self.shortcuts, "--allow-running", "--yes",
                             "--match", "ARM64", *ENV_ARGS)
        self.assertEqual(rc, 1)
        self.assertIn("trailing", err)

    def test_invalid_env(self):
        rc, _, err = run_cli("set-launch-options", "--shortcuts", self.shortcuts, "--allow-running", "--yes",
                             "--match", "ARM64", "--env", "1BAD=x")
        self.assertEqual(rc, 1)
        self.assertIn("invalid --env", err)

    def test_set_and_unset_compat_tool(self):
        appid = str((-1294003210) & 0xFFFFFFFF)
        args = ["--config", self.config, "--appid", appid, "--yes", "--allow-running"]
        rc, out, err = run_cli("set-compat-tool", *args, "--tool", "proton_frame_fixes")
        self.assertEqual(rc, 0, err)
        self.assertIn("previous= new=proton_frame_fixes", out)
        self.assertEqual(len(self.backups(self.config)), 1)
        with open(self.config, encoding="utf-8") as f:
            self.assertIn(f'"{appid}"', f.read())
        rc, out, _ = run_cli("unset-compat-tool", *args, "--tool", "proton_frame_fixes")
        self.assertEqual(rc, 0)
        self.assertIn("removed=proton_frame_fixes", out)
        with open(self.config, encoding="utf-8") as f:
            self.assertEqual(f.read(), CONFIG_VDF)

    def test_negative_appid_argument_is_converted(self):
        rc, out, err = run_cli("set-compat-tool", "--config", self.config, "--appid", "-1294003210",
                               "--tool", "t", "--yes", "--allow-running", "--dry-run")
        self.assertEqual(rc, 0, err)
        self.assertIn(f"appid {(-1294003210) & 0xFFFFFFFF}:", out)

    def test_preserves_file_mode(self):
        os.chmod(self.shortcuts, 0o600)
        run_cli("set-launch-options", "--shortcuts", self.shortcuts, "--allow-running", "--yes", "--no-backup",
                "--match", "ARM64", *ENV_ARGS)
        self.assertEqual(os.stat(self.shortcuts).st_mode & 0o777, 0o600)
        self.assertEqual(self.backups(), [])


if __name__ == "__main__":
    unittest.main()
