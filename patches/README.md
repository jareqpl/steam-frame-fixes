# Patches

| Patch | Applies to | Purpose |
|---|---|---|
| `wine/0001-ntdll-arm64-fixed-address-syscall-dispatcher.patch` | Valve Wine `debeec01b20ce07a0abc9a1876aa372259335d74` (submodule of Proton `experimental-11.0-20260917b`) | Fixes the anti-tamper crash of the native ARM64 WoW client (`c0000005`, `pc=0`) |
| `mesa/0001-tu-fail-pipeline-creation-when-ir3-shader-compilatio.patch` | Mesa `e3a986f0167aa7d1c5cfd62a63362c65f5339373` | Turnip: return `VK_ERROR_UNKNOWN` instead of crashing when ir3 fails to compile a shader |
| `mesa/0002-ir3-log-why-shader-compilation-failed.patch` | Mesa `e3a986f0167aa7d1c5cfd62a63362c65f5339373` | ir3: log which compiler stage failed (diagnostics only) |

Apply the Wine patch with `git apply` (or `patch -p1`) inside the Wine tree, and the Mesa patches with `git am`.
`scripts/check-patches.sh` verifies that all of them apply cleanly to the pinned commits.

## Licensing

The scripts in this repository are MIT-licensed (see `LICENSE`). The patches are modifications of the respective
projects and are distributed under their licenses: the Wine patch under the GNU LGPL 2.1 or later, the Mesa patches
under the MIT license used by the affected Mesa files.
