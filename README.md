# Steam Frame fixes

Unofficial fixes that let the **native ARM64 World of Warcraft client** run on **Steam Frame**, until the
fixes land upstream in Wine, Proton and Mesa.

This repository provides:

- **Proton Experimental ARM64 (Frame fixes)**: Valve's Proton Experimental for ARM64 with one Wine patch,
  installed as a Steam compatibility tool,
- **Turnip**: the Mesa Vulkan driver for Adreno GPUs built from upstream Mesa with two small patches,
- **`install.sh`**: a one-command installer for Steam Frame (desktop mode).

Everything is built from source by GitHub Actions, see [Building from source](#building-from-source).

> This is not affiliated with or endorsed by Valve, Blizzard, the Wine project or Mesa.
> Blizzard does not support Linux or Wine. You use this at your own risk.

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

Reports and patches for the upstream projects are drafted in [UPSTREAM.md](UPSTREAM.md).

## Requirements

- Steam Frame (SteamOS), in desktop mode with a terminal,
- the World of Warcraft **ARM64** client installed through Battle.net (see [Game setup](#game-setup)),
- about 2.5 GB of free space (2 GB installed, plus the download).

## Installation

In desktop mode, open a terminal and run:

```bash
curl -LO https://github.com/jareqpl/steam-frame-fixes/releases/latest/download/install.sh
bash install.sh
```

The installer downloads the latest release, verifies its SHA-256 checksums and installs:

- Proton into `~/.local/share/Steam/compatibilitytools.d/proton-frame-fixes/`,
- Turnip into `~/.local/share/steam-frame-fixes/turnip/`.

It then prints the remaining steps:

1. **Restart Steam.**
2. In the game's shortcut, open **Properties > Compatibility**, enable *Force the use of a specific Steam Play
   compatibility tool* and select **Proton Experimental ARM64 (Frame fixes)**.
3. In **Properties > General > Launch options**, enter exactly the line the installer printed, for example:

   ```
   VK_ICD_FILENAMES=/home/steamos/.local/share/steam-frame-fixes/turnip/freedreno_icd.aarch64.json VK_DRIVER_FILES=/home/steamos/.local/share/steam-frame-fixes/turnip/freedreno_icd.aarch64.json %command%
   ```

   Keep anything you already had there (for example `PROTON_LOG=1`) in front of `%command%`.

Steps 2 and 3 can be done by the installer instead:

1. In Steam, rename the game's shortcut to **`WoW Forever`** (right-click it > Properties, the name field at
   the top).
2. Exit Steam completely (Steam menu > Exit).
3. Run:

   ```bash
   bash ~/.local/share/steam-frame-fixes/install.sh --set-compat-tool --set-launch-options
   ```

It changes only the non-Steam shortcut with exactly that name (not case-sensitive), shows the changes and asks
before writing. A backup of each changed Steam file is kept next to it. To use another name, add
`--shortcut-name "Your Name"`. Renaming the shortcut afterwards is fine: `--uninstall` remembers which
shortcut it changed.

Other options:

| Command | What it does |
|---|---|
| `bash install.sh --version TAG` | install a specific release |
| `bash install.sh --from-dir DIR` | install from release files you downloaded yourself |
| `bash ~/.local/share/steam-frame-fixes/install.sh --doctor` | show the installation state and which Vulkan driver the last game run used |
| `bash ~/.local/share/steam-frame-fixes/install.sh --uninstall` | remove everything and undo the shortcut changes |

Running `install.sh` again updates to the latest release.

### Minimal variant

[`install-min.sh`](install-min.sh) does only what is needed to start the game, for a non-Steam shortcut named
exactly `WoW Forever`: with Steam closed, it unpacks Proton and Turnip, writes the driver's ICD file, replaces
the shortcut's launch options and selects the Frame fixes Proton for it. It has no checksum verification, no
backups, no uninstaller and installs the release named in its `VER=` line. Run it next to the downloaded
release files (or let it download them):

```bash
bash install-min.sh
```

### Why the launch options?

Steam runs Proton inside the Steam Runtime container (pressure-vessel), which sets `VK_ICD_FILENAMES` to the
system driver when the container starts. Proton's `user_settings.py` only sets variables that are not set yet,
so **`VK_ICD_FILENAMES` in `user_settings.py` has no effect**. Variables in the game's launch options are set
before the container starts, and pressure-vessel then imports the driver they point to.

The driver is deliberately not installed system-wide (`~/.local/share/vulkan/icd.d`): that would change the
driver of every game and show two Adreno 750 devices.

## Game setup

<!-- TODO(author): confirm the exact login flow and the steps below on a clean prefix. -->

1. Install Battle.net (x86) as a non-Steam game with Proton, in its own prefix, and install
   World of Warcraft with it.
2. Add the **ARM64 executable** of the game as a separate non-Steam game. For World of Warcraft: Forever
   (beta) it is `_classic_beta_/WowB-ARM64.exe` in the game folder. Other variants have similar names
   (e.g. `Wow-ARM64.exe`).
   <!-- TODO(author): exact executable names of the other WoW variants. Reports welcome. -->
3. Name that shortcut `WoW Forever` and set the compatibility tool and launch options as described in
   [Installation](#installation) (by hand, or with `--set-compat-tool --set-launch-options`).
4. Started without Battle.net, the game first shows a language and region selection window.

<!-- TODO(author): is a Config.wtf copied from a PC needed? Believed not, but not verified on a clean prefix. -->

### Existing prefixes

If the game's prefix was created with another Proton version, Proton updates it when you switch. If anything
behaves oddly, try a fresh prefix. You can check that the prefix uses the fixed `ntdll.dll`:

```bash
python3 -c "import sys;d=open(sys.argv[1],'rb').read();print(d.count(bytes.fromhex('0010fe7f00000000')))" \
  ~/.local/share/Steam/steamapps/compatdata/<appid>/pfx/drive_c/windows/system32/ntdll.dll
```

It prints several hundred with the fix and `0` without it. `install.sh --doctor` does this for shortcuts set
up with `--set-compat-tool`.

## Troubleshooting

1. Add `PROTON_LOG=1` to the launch options, in front of the other variables, and start the game. Proton
   writes `~/steam-<appid>.log`.
2. Run `bash ~/.local/share/steam-frame-fixes/install.sh --doctor`. It reads the newest logs and tells you
   which driver was used:
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
- `install.sh` verifies every download against `SHA256SUMS` before installing anything.
- Nothing modifies game files. Steam settings are only changed when you ask for it, after a backup, and
  `--uninstall` undoes those changes.

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

Tests: `python3 -m unittest discover -s tools/tests`, `tests/test_install.sh` and `tests/test_install_min.sh`.

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
