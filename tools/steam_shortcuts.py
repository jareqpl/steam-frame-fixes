#!/usr/bin/env python3
"""Inspect and edit Steam non-Steam game shortcuts and compatibility tool mappings.

Used by install.sh to set launch options (binary userdata/<id>/config/shortcuts.vdf) and the
compatibility tool (text config/config.vdf, CompatToolMapping) of non-Steam game shortcuts.

Python 3 standard library only (SteamOS has no pip). Safety rules:
  * a file is only modified if parsing and re-serializing it reproduces it byte for byte,
  * a timestamped backup is written next to it first (unless --no-backup),
  * files are replaced atomically,
  * nothing is changed while Steam is running (Steam rewrites these files on exit).

Commands (run with --help for details):
  list                  list shortcuts (optionally only those selected by --name/--match)
  set-launch-options    add environment variables in front of %command% in LaunchOptions
  unset-launch-options  remove those variables again
  set-compat-tool       map shortcut appids to a compatibility tool in config.vdf
  unset-compat-tool     remove such mappings
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shlex
import struct
import sys
import tempfile
import zlib

# ------------------------------------------------------------------------------------------------
# Binary VDF (shortcuts.vdf)
#
# A map is a sequence of entries terminated by 0x08. Each entry is a type byte, a NUL-terminated
# key and a value: 0x00 nested map, 0x01 NUL-terminated string, 0x02 int32, 0x03 float32,
# 0x04 pointer (4 bytes), 0x05 wide string, 0x06 color (4 bytes), 0x07 uint64, 0x0a int64.
# The file is a single root map, so it ends with 0x08 0x08.
# Keys and strings are kept as raw bytes so that re-serializing reproduces the input exactly.
# ------------------------------------------------------------------------------------------------

T_MAP, T_STRING, T_INT32, T_FLOAT32, T_PTR, T_WSTRING, T_COLOR, T_UINT64, T_END, T_INT64 = (
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0A)

_FIXED = {T_INT32: 4, T_FLOAT32: 4, T_PTR: 4, T_COLOR: 4, T_UINT64: 8, T_INT64: 8}


class VdfError(Exception):
    pass


class BinMap:
    """Ordered binary VDF map: a list of [type, key_bytes, value] entries.

    value is a BinMap for T_MAP, bytes for T_STRING/T_WSTRING and for the fixed-size types
    (raw little-endian bytes, so floats and unknown semantics round-trip exactly).
    """

    def __init__(self, entries=None):
        self.entries = entries if entries is not None else []

    def find(self, key: str):
        """First entry whose key matches case-insensitively, or None."""
        k = key.lower().encode()
        for e in self.entries:
            if e[1].lower() == k:
                return e
        return None

    def get_str(self, key: str, default: str = "") -> str:
        e = self.find(key)
        if e is None or e[0] != T_STRING:
            return default
        return e[2].decode("utf-8", "surrogateescape")

    def set_str(self, key: str, value: str) -> None:
        raw = value.encode("utf-8", "surrogateescape")
        if b"\0" in raw:
            raise VdfError("string values must not contain NUL")
        e = self.find(key)
        if e is None:
            self.entries.append([T_STRING, key.encode(), raw])
        elif e[0] != T_STRING:
            raise VdfError(f"{key} is not a string field")
        else:
            e[2] = raw

    def get_int32(self, key: str):
        e = self.find(key)
        if e is None or e[0] != T_INT32:
            return None
        return struct.unpack("<i", e[2])[0]


def _read_cstr(data: bytes, pos: int):
    end = data.find(b"\0", pos)
    if end < 0:
        raise VdfError(f"unterminated string at offset {pos}")
    return data[pos:end], end + 1


def _read_wstr(data: bytes, pos: int):
    end = pos
    while True:
        if end + 1 >= len(data):
            raise VdfError(f"unterminated wide string at offset {pos}")
        if data[end] == 0 and data[end + 1] == 0:
            return data[pos:end], end + 2
        end += 2


def _parse_map(data: bytes, pos: int):
    m = BinMap()
    while True:
        if pos >= len(data):
            raise VdfError("unexpected end of file (missing 0x08)")
        t = data[pos]
        pos += 1
        if t == T_END:
            return m, pos
        key, pos = _read_cstr(data, pos)
        if t == T_MAP:
            value, pos = _parse_map(data, pos)
        elif t == T_STRING:
            value, pos = _read_cstr(data, pos)
        elif t == T_WSTRING:
            value, pos = _read_wstr(data, pos)
        elif t in _FIXED:
            n = _FIXED[t]
            if pos + n > len(data):
                raise VdfError("unexpected end of file in a numeric value")
            value, pos = data[pos:pos + n], pos + n
        else:
            raise VdfError(f"unknown value type 0x{t:02x} at offset {pos - 1}")
        m.entries.append([t, key, value])


def parse_binary_vdf(data: bytes) -> BinMap:
    """Parse a whole binary VDF file. The result is the root map (key/value pairs at top level)."""
    root, pos = _parse_map(data, 0)
    if pos != len(data):
        raise VdfError(f"{len(data) - pos} trailing bytes after the root map")
    return root


def _dump_map(m: BinMap, out: bytearray) -> None:
    for t, key, value in m.entries:
        out.append(t)
        out += key + b"\0"
        if t == T_MAP:
            _dump_map(value, out)
        elif t == T_STRING:
            out += value + b"\0"
        elif t == T_WSTRING:
            out += value + b"\0\0"
        else:
            out += value
    out.append(T_END)


def dump_binary_vdf(root: BinMap) -> bytes:
    out = bytearray()
    _dump_map(root, out)
    return bytes(out)


# ------------------------------------------------------------------------------------------------
# Shortcuts
# ------------------------------------------------------------------------------------------------

class Shortcut:
    def __init__(self, index_key: str, node: BinMap):
        self.index_key = index_key
        self.node = node

    @property
    def name(self) -> str:
        return self.node.get_str("AppName")

    @property
    def exe(self) -> str:
        return self.node.get_str("Exe")

    @property
    def launch_options(self) -> str:
        return self.node.get_str("LaunchOptions")

    @property
    def appid(self) -> int:
        """Unsigned 32-bit appid as used in config.vdf and Steam URLs."""
        signed = self.node.get_int32("appid")
        if signed is not None:
            return signed & 0xFFFFFFFF
        # Older Steam versions did not store the appid; it was derived from exe and name.
        crc = zlib.crc32((self.exe + self.name).encode("utf-8", "surrogateescape"))
        return (crc | 0x80000000) & 0xFFFFFFFF

    def matches(self, patterns=(), names=(), appids=()) -> bool:
        """Selected by appid, by an exact name (case-insensitive, surrounding spaces ignored) or by a
        case-insensitive substring of Exe or AppName. Without any criteria every shortcut matches."""
        if not patterns and not names and not appids:
            return True
        if self.appid in appids:
            return True
        if any(n.strip().casefold() == self.name.strip().casefold() for n in names):
            return True
        hay = (self.exe + "\n" + self.name).casefold()
        return any(p.casefold() in hay for p in patterns)

    def as_dict(self) -> dict:
        return {"index": self.index_key, "appid": self.appid, "name": self.name,
                "exe": self.exe, "launch_options": self.launch_options}


def shortcuts_of(root: BinMap):
    e = root.find("shortcuts")
    if e is None or e[0] != T_MAP:
        raise VdfError("no 'shortcuts' map at the top level")
    return [Shortcut(k.decode("utf-8", "surrogateescape"), v)
            for t, k, v in e[2].entries if t == T_MAP]


# ------------------------------------------------------------------------------------------------
# Launch options
# ------------------------------------------------------------------------------------------------

COMMAND = "%command%"


def _quote(value: str) -> str:
    return value if re.fullmatch(r"[A-Za-z0-9_@%+=:,./-]+", value) else shlex.quote(value)


def _assignment_re(name: str):
    # NAME=value where value is a single shell word: unquoted, '...' or "..." parts
    return re.compile(r"(?:(?<=\s)|^)" + re.escape(name) + r"=(?:'[^']*'|\"(?:\\.|[^\"\\])*\"|[^\s'\"])*(?=\s|$)")


def _split_command(options: str):
    """(prefix, suffix) around %command%, or None if there is no %command%."""
    i = options.find(COMMAND)
    if i < 0:
        return None
    return options[:i], options[i + len(COMMAND):]


def _remove_vars(prefix: str, names) -> str:
    for n in names:
        prefix = _assignment_re(n).sub("", prefix)
    return " ".join(prefix.split()) if prefix.strip() else ""


def add_env_to_launch_options(options: str, env) -> str:
    """Put NAME=value assignments (env: list of (name, value)) in front of %command%.

    Existing assignments of the same names are replaced, everything else is kept. Options
    without %command% are arguments for the game, so they go after %command%.
    """
    parts = _split_command(options)
    if parts is None:
        prefix, suffix = "", (" " + options.strip()) if options.strip() else ""
    else:
        prefix, suffix = parts
    rest = _remove_vars(prefix, [n for n, _ in env])
    ours = " ".join(f"{n}={_quote(v)}" for n, v in env)
    new_prefix = ours + (" " + rest if rest else "")
    return f"{new_prefix} {COMMAND}{suffix}"


def remove_env_from_launch_options(options: str, names) -> str:
    parts = _split_command(options)
    if parts is None:
        return options
    prefix, suffix = parts
    rest = _remove_vars(prefix, names)
    if not rest and not suffix.strip():
        return ""  # only "%command%" would be left, which is the same as no options
    return (rest + " " if rest else "") + COMMAND + suffix


# ------------------------------------------------------------------------------------------------
# Text VDF (config.vdf), edited in place so that everything else stays byte-identical
# ------------------------------------------------------------------------------------------------

class TextNode:
    def __init__(self, key, key_start, value, value_start, value_end):
        self.key = key                  # unescaped key
        self.key_start = key_start      # offset of the key token
        self.value = value              # str, or list of TextNode for a block
        self.value_start = value_start  # offset of the value token or of "{"
        self.value_end = value_end      # offset after the value token or after "}"

    def child(self, key: str):
        if isinstance(self.value, list):
            for c in self.value:
                if c.key.lower() == key.lower():
                    return c
        return None


_ESCAPES = {"n": "\n", "t": "\t", "\\": "\\", '"': '"'}


def _text_tokens(text: str):
    """Yield (kind, value, start, end); kind is 'str', '{' or '}'. Skips comments and [$COND]."""
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
        elif c in "{}":
            yield c, c, i, i + 1
            i += 1
        elif c == "[":  # conditional like [$WIN32], belongs to the previous token
            j = text.find("]", i)
            if j < 0:
                raise VdfError(f"unterminated conditional at offset {i}")
            i = j + 1
        elif c == '"':
            j, buf = i + 1, []
            while True:
                if j >= n:
                    raise VdfError(f"unterminated string at offset {i}")
                ch = text[j]
                if ch == "\\" and j + 1 < n:
                    buf.append(_ESCAPES.get(text[j + 1], "\\" + text[j + 1]))
                    j += 2
                elif ch == '"':
                    break
                else:
                    buf.append(ch)
                    j += 1
            yield "str", "".join(buf), i, j + 1
            i = j + 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in '{}"':
                j += 1
            yield "str", text[i:j], i, j
            i = j


def parse_text_vdf(text: str):
    """Parse a text VDF file into a list of top-level TextNodes."""
    tokens = list(_text_tokens(text))
    pos = 0

    def parse_block(closing: bool):
        nonlocal pos
        nodes = []
        while True:
            if pos >= len(tokens):
                if closing:
                    raise VdfError("unexpected end of file (missing '}')")
                return nodes, None
            kind, value, start, end = tokens[pos]
            if kind == "}":
                if not closing:
                    raise VdfError(f"unexpected '}}' at offset {start}")
                pos += 1
                return nodes, end
            if kind != "str":
                raise VdfError(f"expected a key at offset {start}")
            pos += 1
            if pos >= len(tokens):
                raise VdfError(f"key without value at offset {start}")
            vkind, vvalue, vstart, vend = tokens[pos]
            pos += 1
            if vkind == "{":
                children, block_end = parse_block(True)
                nodes.append(TextNode(value, start, children, vstart, block_end))
            elif vkind == "str":
                nodes.append(TextNode(value, start, vvalue, vstart, vend))
            else:
                raise VdfError(f"unexpected '}}' after key at offset {start}")

    nodes, _ = parse_block(False)
    return nodes


def _escape_text(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _line_start(text: str, pos: int) -> int:
    return text.rfind("\n", 0, pos) + 1


def _indent_at(text: str, pos: int) -> str:
    start = _line_start(text, pos)
    m = re.match(r"[ \t]*", text[start:pos])
    return m.group(0) if m else ""


def _steam_node(nodes):
    root = next((n for n in nodes if n.key.lower() == "installconfigstore"), None)
    node = root
    for key in ("Software", "Valve", "Steam"):
        node = node.child(key) if node else None
    if node is None or not isinstance(node.value, list):
        raise VdfError("InstallConfigStore/Software/Valve/Steam not found in config.vdf")
    return node


def _mapping_entry_text(indent: str, appid: int, tool: str, priority: str) -> str:
    i2 = indent + "\t"
    return (f'{indent}"{appid}"\n{indent}{{\n'
            f'{i2}"name"\t\t"{_escape_text(tool)}"\n'
            f'{i2}"config"\t\t""\n'
            f'{i2}"priority"\t\t"{_escape_text(priority)}"\n'
            f'{indent}}}\n')


def _insert_before_close(text: str, block: TextNode, content_for_indent) -> str:
    """Insert text generated for the block's child indentation before the block's closing brace."""
    close = block.value_end - 1
    indent = _indent_at(text, close)
    child_indent = indent + "\t"
    at = _line_start(text, close)
    if text[at:close].strip():  # closing brace is not on its own line
        return text[:close] + "\n" + content_for_indent(child_indent) + indent + text[close:]
    return text[:at] + content_for_indent(child_indent) + text[at:]


def set_compat_tool_text(text: str, appid: int, tool: str, priority: str = "250"):
    """Return (new_text, previous_tool_name_or_None)."""
    steam = _steam_node(parse_text_vdf(text))
    mapping = steam.child("CompatToolMapping")
    if mapping is None:
        def block(ci):
            return (f'{ci}"CompatToolMapping"\n{ci}{{\n'
                    + _mapping_entry_text(ci + "\t", appid, tool, priority) + f"{ci}}}\n")
        return _insert_before_close(text, steam, block), None
    if not isinstance(mapping.value, list):
        raise VdfError("CompatToolMapping is not a block")
    entry = mapping.child(str(appid))
    if entry is None:
        return _insert_before_close(
            text, mapping, lambda ci: _mapping_entry_text(ci, appid, tool, priority)), None
    if not isinstance(entry.value, list):
        raise VdfError(f"CompatToolMapping/{appid} is not a block")
    name = entry.child("name")
    previous = name.value if name is not None and isinstance(name.value, str) else None
    if previous == tool:
        return text, previous
    if name is not None and isinstance(name.value, str):
        return text[:name.value_start] + f'"{_escape_text(tool)}"' + text[name.value_end:], previous
    return _insert_before_close(
        text, entry, lambda ci: f'{ci}"name"\t\t"{_escape_text(tool)}"\n'), previous


def unset_compat_tool_text(text: str, appid: int, only_tool=None):
    """Remove the mapping for appid (only if it points to only_tool, when given).

    Returns (new_text, removed_tool_name_or_None).
    """
    try:
        steam = _steam_node(parse_text_vdf(text))
    except VdfError:
        return text, None
    mapping = steam.child("CompatToolMapping")
    entry = mapping.child(str(appid)) if mapping is not None else None
    if entry is None:
        return text, None
    name = entry.child("name")
    current = name.value if name is not None and isinstance(name.value, str) else None
    if only_tool is not None and current != only_tool:
        return text, None
    start = _line_start(text, entry.key_start)
    if text[start:entry.key_start].strip():
        start = entry.key_start
    end = entry.value_end
    rest_of_line = re.match(r"[ \t]*\r?\n", text[end:])
    if rest_of_line:
        end += rest_of_line.end()
    return text[:start] + text[end:], current


# ------------------------------------------------------------------------------------------------
# File handling
# ------------------------------------------------------------------------------------------------

def steam_is_running() -> bool:
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/comm") as f:
                comm = f.read().strip()
        except OSError:
            continue
        if comm in ("steam", "steamwebhelper"):
            return True
    return False


def backup(path: str) -> str:
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    dst = f"{path}.frame-fixes-{stamp}.bak"
    n = 1
    while os.path.exists(dst):
        dst = f"{path}.frame-fixes-{stamp}-{n}.bak"
        n += 1
    with open(path, "rb") as src, open(dst, "xb") as out:
        out.write(src.read())
    return dst


def write_atomic(path: str, data: bytes) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    mode = os.stat(path).st_mode & 0o7777 if os.path.exists(path) else 0o644
    fd, tmp = tempfile.mkstemp(prefix=".frame-fixes-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def load_shortcuts(path: str):
    with open(path, "rb") as f:
        data = f.read()
    root = parse_binary_vdf(data)
    if dump_binary_vdf(root) != data:
        raise VdfError(f"{path}: re-serializing does not reproduce the file, refusing to edit it")
    return data, root


def load_config(path: str) -> str:
    with open(path, "rb") as f:
        raw = f.read()
    text = raw.decode("utf-8", "surrogateescape")
    if text.encode("utf-8", "surrogateescape") != raw:
        raise VdfError(f"{path}: cannot round-trip the file encoding")
    parse_text_vdf(text)  # validate
    return text


# ------------------------------------------------------------------------------------------------
# Commands
# ------------------------------------------------------------------------------------------------

class Abort(Exception):
    pass


def _check_not_running(args) -> None:
    if not args.dry_run and not args.allow_running and steam_is_running():
        raise Abort("Steam is running. Exit Steam completely first (it rewrites these files on exit).")


def _confirm(args, question: str) -> None:
    if args.yes or args.dry_run:
        return
    if not sys.stdin.isatty():
        raise Abort("not confirmed (use --yes for non-interactive use)")
    if input(f"{question} [y/N] ").strip().lower() not in ("y", "yes"):
        raise Abort("cancelled")


def _parse_env(items):
    env = []
    for item in items:
        name, sep, value = item.partition("=")
        if not sep or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise Abort(f"invalid --env {item!r}, expected NAME=value")
        env.append((name, value))
    return env


def _print_shortcut(s: Shortcut) -> None:
    print(f"  [{s.index_key}] appid {s.appid}  {s.name!r}")
    print(f"      exe: {s.exe}")
    print(f"      launch options: {s.launch_options!r}")


def cmd_list(args) -> int:
    _, root = load_shortcuts(args.shortcuts)
    found = [s for s in shortcuts_of(root) if s.matches(args.match, args.name, args.appid)]
    if args.format == "json":
        print(json.dumps([s.as_dict() for s in found], indent=2, ensure_ascii=False))
    elif args.format == "appid":
        for s in found:
            print(s.appid)
    else:
        for s in found:
            _print_shortcut(s)
    return 0 if found or not (args.match or args.name or args.appid) else 3


def _edit_launch_options(args, transform) -> int:
    if not args.match and not args.name and not args.appid:
        raise Abort("select shortcuts with --name, --match or --appid")
    _check_not_running(args)
    data, root = load_shortcuts(args.shortcuts)
    targets = [s for s in shortcuts_of(root) if s.matches(args.match, args.name, args.appid)]
    if not targets:
        print("No matching shortcuts.", file=sys.stderr)
        return 3
    changes = []
    for s in targets:
        old = s.launch_options
        new = transform(old)
        if new != old:
            changes.append((s, old, new))
    if not changes:
        print("Nothing to change.")
        return 0
    for s, old, new in changes:
        print(f"  appid {s.appid}  {s.name!r}\n      before: {old!r}\n      after:  {new!r}")
    _confirm(args, f"Change the launch options of {len(changes)} shortcut(s)?")
    if args.dry_run:
        return 0
    for s, _, new in changes:
        s.node.set_str("LaunchOptions", new)
    out = dump_binary_vdf(root)
    if dump_binary_vdf(parse_binary_vdf(out)) != out:
        raise VdfError("internal error: the modified file does not round-trip")
    if not args.no_backup:
        print(f"Backup: {backup(args.shortcuts)}")
    write_atomic(args.shortcuts, out)
    print(f"Updated {args.shortcuts}")
    return 0


def cmd_set_launch_options(args) -> int:
    env = _parse_env(args.env)
    if not env:
        raise Abort("at least one --env NAME=value is required")
    return _edit_launch_options(args, lambda old: add_env_to_launch_options(old, env))


def cmd_unset_launch_options(args) -> int:
    names = [n.partition("=")[0] for n in args.env]
    if not names:
        raise Abort("at least one --env NAME is required")
    return _edit_launch_options(args, lambda old: remove_env_from_launch_options(old, names))


def _edit_config(args, transform) -> int:
    _check_not_running(args)
    text = load_config(args.config)
    new = text
    for appid in args.appid:
        new, info = transform(new, appid)
        print(f"  appid {appid}: {info}")
    if new == text:
        print("Nothing to change.")
        return 0
    _confirm(args, "Update config.vdf?")
    if args.dry_run:
        return 0
    parse_text_vdf(new)  # must still be valid
    if not args.no_backup:
        print(f"Backup: {backup(args.config)}")
    write_atomic(args.config, new.encode("utf-8", "surrogateescape"))
    print(f"Updated {args.config}")
    return 0


def cmd_set_compat_tool(args) -> int:
    def transform(text, appid):
        new, previous = set_compat_tool_text(text, appid, args.tool, args.priority)
        return new, f"previous={previous or ''} new={args.tool}"
    return _edit_config(args, transform)


def cmd_unset_compat_tool(args) -> int:
    def transform(text, appid):
        new, removed = unset_compat_tool_text(text, appid, args.tool)
        return new, f"removed={removed or ''}"
    return _edit_config(args, transform)


def _appid(value: str) -> int:
    n = int(value, 0)
    if n < 0:
        n &= 0xFFFFFFFF
    if not 0 <= n <= 0xFFFFFFFF:
        raise argparse.ArgumentTypeError(f"invalid appid {value}")
    return n


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="command", required=True)

    def add_selection(sp):
        sp.add_argument("--name", action="append", default=[],
                        help="exact shortcut name, case-insensitive (repeatable)")
        sp.add_argument("--match", action="append", default=[],
                        help="case-insensitive substring of Exe or AppName (repeatable)")
        sp.add_argument("--appid", type=_appid, action="append", default=[],
                        help="shortcut appid, as printed by list (repeatable)")

    def common_edit(sp):
        sp.add_argument("--yes", action="store_true", help="do not ask for confirmation")
        sp.add_argument("--dry-run", action="store_true", help="only show what would change")
        sp.add_argument("--no-backup", action="store_true", help="do not write a .bak copy first")
        sp.add_argument("--allow-running", action="store_true", help=argparse.SUPPRESS)

    sp = sub.add_parser("list", help="list shortcuts")
    sp.add_argument("--shortcuts", required=True, help="path to userdata/<id>/config/shortcuts.vdf")
    add_selection(sp)
    sp.add_argument("--format", choices=("text", "json", "appid"), default="text")
    sp.set_defaults(func=cmd_list)

    for name, func, cmd_help, env_help in (
            ("set-launch-options", cmd_set_launch_options, "add environment variables before %%command%%",
             "NAME=value to put before %%command%% (repeatable)"),
            ("unset-launch-options", cmd_unset_launch_options, "remove environment variables from launch options",
             "NAME (or NAME=value) to remove (repeatable)")):
        sp = sub.add_parser(name, help=cmd_help)
        sp.add_argument("--shortcuts", required=True)
        add_selection(sp)
        sp.add_argument("--env", action="append", default=[], help=env_help)
        common_edit(sp)
        sp.set_defaults(func=func)

    sp = sub.add_parser("set-compat-tool", help="map appids to a compatibility tool in config.vdf")
    sp.add_argument("--config", required=True, help="path to Steam/config/config.vdf")
    sp.add_argument("--appid", type=_appid, action="append", required=True)
    sp.add_argument("--tool", required=True, help="internal tool name, e.g. proton_frame_fixes")
    sp.add_argument("--priority", default="250", help="mapping priority (Steam uses 250 for per-game choices)")
    common_edit(sp)
    sp.set_defaults(func=cmd_set_compat_tool)

    sp = sub.add_parser("unset-compat-tool", help="remove appid mappings from config.vdf")
    sp.add_argument("--config", required=True)
    sp.add_argument("--appid", type=_appid, action="append", required=True)
    sp.add_argument("--tool", help="only remove mappings that point to this tool")
    common_edit(sp)
    sp.set_defaults(func=cmd_unset_compat_tool)
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (Abort, VdfError, OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
