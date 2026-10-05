# V1.0.4 — miatoll / sm6250

- **Build:** OpenELA 4.14.357 legacy kernel, non-GKI
- **Devices:** Redmi Note 9 Pro / 9S, POCO M2 Pro, and the supported miatoll family

## Installer hotfix

- Fixed Error 1 after boot-image unpacking: `dump_boot` leaves the working
  directory inside the ramdisk, so the SELinux helper is now loaded using the
  absolute AnyKernel3 home path. A regression test exercises that directory
  change before the simulated boot write.
- Skip permission updates for absent optional `ramdisk/init*` and `ramdisk/sbin`
  entries instead of emitting misleading missing-file warnings.

## Highlights

- Updated the vendored KernelSU-Next legacy kernel and UAPI to official upstream commit [`cd739c788023`](https://github.com/KernelSU-Next/KernelSU-Next/commit/cd739c78802333455391df973db17d9f28328b83).
- Kept SuSFS v2.3.0 (NON-GKI) and NoMount v2.0.0, with the KernelSU compatibility overlay adapted to the upstream two-UID `setresuid` API.
- Added the available legacy-kernel configuration required by DroidSpaces and applied its compatible cgroup controller-prefix patch; enabled namespaces, seccomp, cgroup accounting/controllers, devtmpfs, OverlayFS, tmpfs xattrs/ACLs, veth/bridge networking, and IPv4/IPv6 NAT support.
- Pinned KernelSU-Next to the UAPI-4 legacy revision immediately before the UAPI-5 service-event change, as requested. This is deliberately one revision behind the latest legacy source checked on 2026-10-05. The DroidSpaces guide pin is unchanged.
- Fixed inherited SELinux boot arguments in the AnyKernel3 installer: `androidboot.selinux=enforcing`, `enforcing=1`, and `selinux=1` now match actual kernel enforcement, including removal of conflicting duplicates.
- Carried the KernelSU `path_umount()` and seccomp compatibility definitions in-tree before compilation to avoid parallel-build source-edit races.
- Changed the miatoll defconfig to hard-enforcing SELinux: development mode, boot-time disable, and runtime disable are off.
- Release kernel is built by GitHub Actions with clang 18 and `ld.lld`; the workflow attaches the flashable AnyKernel3 ZIP and its SHA-256 checksum.

## Compatibility notes

- `CONFIG_KSU_SUSFS_TRY_UMOUNT` and `CONFIG_KSU_SUSFS_SUS_MEMFD` remain disabled because the SuSFS v2.3.0 4.14 port does not implement their helper functions. SuSFS and KernelSU's normal zygote unmount handling remain enabled.
- This device uses WALT, and this kernel's `CONFIG_CFS_BANDWIDTH` depends on WALT being disabled. The scheduler is kept unchanged, so DroidSpaces CPU-quota limits may be unavailable; other supported container resource controls are enabled. The guide's xt_qtaguid patch was not applied because this tree has no `net/netfilter/xt_qtaguid.c`.
- Hard-enforcing SELinux can expose policy denials or prevent boot if the ROM's policy is incompatible. Confirm the target userspace policy before flashing; permissive mode can no longer be selected through this kernel's development controls.
- KernelSU-Next reports **33294-4**: `33294` is the integrator-pinned version code and `4` is the UAPI implemented by the pinned source. Reverted the UAPI-5 `EVENT_SERVICES` start/skip change along with its version declaration, rather than masking a UAPI-5 kernel as UAPI 4. Manager compatibility still requires a matching APK; this is not a guarantee that every older Manager will work.
- Flash using a compatible custom recovery and the attached AnyKernel3 package. Back up the current boot image before flashing.

## Validation and boot-property scope

- The Actions pre-build audit checks the root stack, DroidSpaces configuration,
  and enforcing SELinux settings. Installer regression tests cover both AnyKernel3
  command-line storage formats, duplicate arguments, and repeat installation.
- `ro.boot.selinux` comes from Android boot inputs, not the kernel defconfig.
  The installer corrects the boot-image command line; it does not spoof runtime
  SELinux status or rewrite ROM properties. Bootloader/vendor-supplied overrides
  and bootconfig are outside this installer fix. After flashing, check both
  `adb shell getenforce` and `adb shell getprop ro.boot.selinux`.
- A successful Actions build is not an on-device boot test. DroidSpaces runtime,
  ROM-policy compatibility, and root/module operation still require device testing.
