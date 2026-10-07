# Steam Frame fixes

Unofficial fixes that let the **native ARM64 World of Warcraft client** run on **Steam Frame**, until the
fixes land upstream in Wine, Proton and Mesa.

This repository provides:

- **Proton Experimental ARM64 (Frame fixes)**: Valve's Proton Experimental for ARM64 with one Wine patch,
  installed as a Steam compatibility tool,
- **Turnip**: the Mesa Vulkan driver for Adreno GPUs built from upstream Mesa with two small patches,
- **`install-min.sh`** / **`uninstall-min.sh`**: one-command setup and removal on Steam Frame (desktop mode).

Everything is built from source, see [Building from source](#building-from-source).

> **Use at your own risk.** Please read the [disclaimer](#disclaimer) before installing.

## Disclaimer

This is an unofficial, experimental community project. It is not affiliated with or endorsed by Valve,
Blizzard Entertainment, the Wine project or Mesa, and Blizzard does not support playing its games on Linux,
Wine or Proton.

**You use this software entirely at your own risk.** It is provided "as is", without warranty of any kind
(see the [license](LICENSE)). The author is not responsible for any damage or loss it may cause, including
to your device, your Steam installation, your game data or your game account.

**This software was developed with heavy use of AI.** The analysis, the patches, the build scripts, the
installer and this documentation were largely written with the help of an AI assistant (Claude, by
Anthropic) and tested by a human on a real Steam Frame. Treat it accordingly: read the
scripts before running them, and report anything that looks wrong.

## What is fixed

**1. Crash in the game's protection (Wine/Proton).**
The ARM64 client crashes right after creating its DirectX device (`c0000005` at address 0). Its
anti-tamper code calls system call stubs from its own copy of `ntdll.dll`, in which Wine's pointer to the
system call dispatcher is zero. On x86_64 Wine keeps that pointer at a fixed address (`0x7ffe1000`) for exactly
this reason; [the patch](patches/wine/0001-ntdll-arm64-fixed-address-syscall-dispatcher.patch) does the same on
ARM64. The same crash is reported in
[Winlator-Ludashi #632](https://github.com/StevenMXZ/Winlator-Ludashi/issues/632).

**2. Shader compilation crash (Turnip).**
Steam Frame's system Turnip driver fails to compile two fragment shaders of the login screen (they use
`InterpolateAtSample`) and then crashes in `vkCreateGraphicsPipelines`. A Turnip built from upstream Mesa
compiles them fine (tested with all 144 combinations of MSAA, sample shading, pipeline type and subgroup size,
versus 144 crashes with the system driver). The [two Mesa patches](patches/mesa) add a NULL check that turns
such a failure into an error instead of a crash, and log which compiler stage failed.

## Requirements

- Steam Frame (SteamOS), in desktop mode with a terminal,
- the World of Warcraft **ARM64** client installed through Battle.net (see [Game setup](#game-setup)),
- about 2.5 GB of free space (2 GB installed, plus the download).

## Installation

1. Add **Battle.net** (or the game's ARM64 executable) to Steam as a non-Steam game, see
   [Game setup](#game-setup).
2. Rename that shortcut to exactly **`WoW Forever`** (right-click it > Properties, the name field at the top).
3. Download `install-min.sh` from the [latest release](https://github.com/jareqpl/steam-frame-fixes/releases).
4. In desktop mode, open a terminal in the folder with the script and run:

   ```bash
   bash install-min.sh
   ```

5. **Restart Steam** and launch `WoW Forever`.

`install-min.sh` downloads the Proton and Turnip archives of its release (about 370 MB), verifies them against
the release's `SHA256SUMS` and then (archives already next to the script are used instead of downloading):

- unpacks Proton into `~/.local/share/Steam/compatibilitytools.d/proton-frame-fixes/`,
- unpacks Turnip into `~/.local/share/steam-frame-fixes/turnip/` and writes its Vulkan ICD file,
- sets the launch options of the `WoW Forever` shortcut to

  ```
  VK_ICD_FILENAMES=/home/<user>/.local/share/steam-frame-fixes/turnip/freedreno_icd.aarch64.json VK_DRIVER_FILES=/home/<user>/.local/share/steam-frame-fixes/turnip/freedreno_icd.aarch64.json %command%
  ```

  (replacing what was there; add `PROTON_LOG=1` in front again if you need logs),
- selects **Proton Experimental ARM64 (Frame fixes)** as its compatibility tool.

Steam does not need to be closed; the changes are picked up after the restart (tested on Steam Frame).
The script makes no backups of the Steam files it changes.

To set it up by hand instead, use the same two settings in the shortcut's Properties: Compatibility > force
*Proton Experimental ARM64 (Frame fixes)*, and General > Launch options as above.

### Uninstalling

Download `uninstall-min.sh` from the release and run it, then restart Steam:

```bash
bash uninstall-min.sh
```

It removes both installed folders, our variables from the launch options of any shortcut that uses them (also
if it was renamed) and the compatibility tool mappings to the Frame fixes Proton.

### Why the launch options?

Steam runs Proton inside the Steam Runtime container (pressure-vessel), which sets `VK_ICD_FILENAMES` to the
system driver when the container starts. Proton's `user_settings.py` only sets variables that are not set yet,
so **`VK_ICD_FILENAMES` in `user_settings.py` has no effect**. Variables in the game's launch options are set
before the container starts, and pressure-vessel then imports the driver they point to.

The driver is deliberately not installed system-wide (`~/.local/share/vulkan/icd.d`): that would change the
driver of every game and show two Adreno 750 devices.

## Game setup

<!-- TODO(author): confirm the exact login flow on a clean prefix. -->

1. Install Battle.net (x86) as a non-Steam game with Proton, in its own prefix, and install
   World of Warcraft with it.
2. Name the shortcut that starts the game `WoW Forever` and run `install-min.sh` (see
   [Installation](#installation)). This can be the **Battle.net** shortcut itself (tested on Steam Frame) or a
   separate non-Steam shortcut to the game's **ARM64 executable**: for World of Warcraft: Forever (beta)
   `_classic_beta_/WowB-ARM64.exe` in the game folder; other variants have similar names (e.g. `Wow-ARM64.exe`).
   <!-- TODO(author): exact executable names of the other WoW variants. Reports welcome. -->
3. Started directly (without Battle.net), the game first shows a language and region selection window.

<!-- TODO(author): is a Config.wtf copied from a PC needed? Believed not, but not verified on a clean prefix. -->

### Existing prefixes

If the game's prefix was created with another Proton version, Proton updates it when you switch. If anything
behaves oddly, try a fresh prefix. You can check that the prefix uses the fixed `ntdll.dll`:

```bash
python3 -c "import sys;d=open(sys.argv[1],'rb').read();print(d.count(bytes.fromhex('0010fe7f00000000')))" \
  ~/.local/share/Steam/steamapps/compatdata/<appid>/pfx/drive_c/windows/system32/ntdll.dll
```

It prints several hundred with the fix and `0` without it.

## Troubleshooting

1. Add `PROTON_LOG=1` to the launch options, in front of the other variables, and start the game. Proton
   writes `~/steam-<appid>.log`.
2. Check which Vulkan driver was used:

   ```bash
   grep -h 'with driver:' ~/steam-*.log | tail -n 3
   ```

   - `Using "Turnip Adreno (TM) 750" with driver: "/home/.../steam-frame-fixes/turnip/libvulkan_freedreno.so"`
     means this driver is used,
   - `... with driver: "/run/host/usr/lib/libvulkan_freedreno.so"` means the **system** driver is used: the
     launch options are missing or mistyped.
3. `MESA: error: compile failed!` in the log means a shader failed to compile. With this driver the log also
   says which compiler stage failed (`ir3: ... failed for ... shader`); please open an issue with that line.
4. A crash with `c0000005` and `pc=0` means the game does not run with the Frame fixes Proton: check the
   compatibility tool and the prefix (see [Existing prefixes](#existing-prefixes)).

## Security and trust

- Releases are built from source by [GitHub Actions](.github/workflows/build.yml); the build logs are public.
- All patches are in [`patches/`](patches) and are small enough to review.
- `install-min.sh` verifies the downloaded archives against the release's `SHA256SUMS` before unpacking them.
- Nothing modifies game files. `install-min.sh` only changes the launch options and the compatibility tool of
  the `WoW Forever` shortcut, and `uninstall-min.sh` removes those changes.

## Building from source

Both components are built in Valve's Steam Runtime 4 SDK container for ARM64
(`registry.gitlab.steamos.cloud/proton/steamrt4/sdk/arm64-llvm`), so the results run on SteamOS.

**GitHub Actions.** The [build workflow](.github/workflows/build.yml) runs on GitHub's ARM64 runners, manually
(`workflow_dispatch`) and for `v*` tags, where it publishes a release.

**Any ARM64 Linux host with Docker** (or Podman with `CONTAINER_ENGINE=podman`):

```bash
scripts/check-patches.sh               # patches apply to the pinned versions (any architecture)
scripts/build-turnip.sh                # a few minutes
scripts/build-proton.sh --ccache       # several hours, 30-40 GB of disk; re-run to resume
scripts/package.sh --version v1-test   # release files and SHA256SUMS in dist/
```

A cloud VM works too (for example an Azure `Standard_D8ps_v6` with Ubuntu 24.04 ARM64). Turnip can also be
built on x86_64 through qemu-user with `scripts/build-turnip.sh --emulate`; use qemu 10 or newer, as qemu 8.2
makes clang crash on some Mesa sources.

Pinned versions:

| Component | Version |
|---|---|
| Proton | [`experimental-11.0-20260917b`](https://github.com/ValveSoftware/Proton/tree/experimental-11.0-20260917b) |
| Wine (Proton submodule) | `debeec01b20ce07a0abc9a1876aa372259335d74` |
| Mesa | [`e3a986f0167aa7d1c5cfd62a63362c65f5339373`](https://gitlab.freedesktop.org/mesa/mesa/-/commit/e3a986f0167aa7d1c5cfd62a63362c65f5339373) |
| Steam Runtime SDK | `steamrt4/sdk/arm64-llvm:4.0.20260714.251823-0` |

Tests: `tests/test_install_min.sh` (no ARM64 or Steam needed) and `scripts/check-patches.sh`.

## Credits

- [Wine](https://www.winehq.org/) and [Proton](https://github.com/ValveSoftware/Proton) (Valve, CodeWeavers and
  the Wine contributors),
- [Mesa](https://mesa3d.org/) and its Turnip/freedreno developers,
- [DXVK](https://github.com/doitsujin/dxvk), [vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton)
  and [FEX](https://github.com/FEX-Emu/FEX), which are part of Proton,
- the analysis, patches and tooling were developed with the help of Claude (Anthropic).

## License

The scripts and tools in this repository are under the [MIT license](LICENSE). The patches and the built
components are under the licenses of their projects: Wine is LGPL 2.1 or later (the patched Wine sources are
published with every release), Proton's own files are under its BSD-style license, Mesa is MIT. Each release
archive contains the corresponding license files.

## Trademarks

World of Warcraft, Warcraft, Battle.net and Blizzard Entertainment are trademarks or registered trademarks of
Blizzard Entertainment, Inc. in the U.S. and/or other countries. Steam, Steam Frame, Proton and Valve are
trademarks and/or registered trademarks of Valve Corporation in the U.S. and/or other countries. Adreno is a
trademark of Qualcomm Incorporated. Vulkan is a registered trademark of the Khronos Group Inc. All other
trademarks are the property of their respective owners. These names are used only to describe what this project
is compatible with. This project is not affiliated with, sponsored or endorsed by any of these companies.
