# Root + stealth integration — miatoll 4.14 legacy (non-GKI)

Official KernelSU-Next legacy + SuSFS v2.3.0 + NoMount v2.0.0 are integrated
**in-tree** into `4.14.357-openela` (arm64, Xiaomi sm6250: miatoll / curtana /
excalibur / gram / joyeuse). The defconfig also enables the legacy-kernel
requirements for **DroidSpaces**. Release builds use **clang 18 / ld.lld only**.

Everything here is self-contained: the upstreams are vendored into this repo, so
the tree builds without network access and without `git submodule update`.

| part | revision | where |
|---|---|---|
| KernelSU-Next (official legacy) | `KernelSU-Next/KernelSU-Next`, branch `legacy` @ `cd739c78802333455391df973db17d9f28328b83` (2026‑10‑01); build reports `33294-4` (`KSU_VERSION=33294`, UAPI 4) | `KernelSU-Next/kernel/` + `uapi/`, symlinked as `drivers/kernelsu` |
| SuSFS | **v2.3.0**, `NON-GKI` variant | `tools/root-integration/patches/susfs/susfs_patch_to_4.14.patch` (already applied) |
| NoMount | **v2.0.0**, built-in | `fs/nomount/` (from `maxsteeel/nomount@v2.0.0`, `kernel/src/*`) |
| eBPF | 5.10-era backport, already in this tree | no changes (see [eBPF](#ebpf)) |

Machines: exact pins in [`tools/root-integration/upstreams.json`](../tools/root-integration/upstreams.json).

## Layout

```
KernelSU-Next/                      vendored official source (kernel/, uapi/)
drivers/kernelsu -> ../KernelSU-Next/kernel      (symlink, upstream's own layout)
drivers/{Makefile,Kconfig}          obj-$(CONFIG_KSU) += kernelsu/ + source .../Kconfig
fs/susfs.c                          SuSFS core (from the patch)
include/linux/susfs{,_def}.h        SuSFS headers
fs/nomount/                         NoMount v2.0.0 kernel side (13 files + Kconfig)
fs/{Makefile,Kconfig}               nomount wiring
tools/root-integration/
  apply_ksu_hooks.py                the hook installer (idempotent, --verify audits)
  audit_hooks.sh                    full integration audit (used by CI)
  check_susfs_symbols.py            SusFS-overlay-vs-port symbol cross-check (used by CI)
  upstreams.json                    exact upstream pins
  patches/                          provenance diff of this integration
  patches/susfs/                    the SuSFS 4.14 patch that was applied
  scripts/                          upstream hook scripts (reference only - do not run)
```

## How the pieces hook the kernel

4.14 with `# CONFIG_KPROBES is not set` (kept off deliberately) means **no kprobes
and no syscall-table patching** (that mode needs ≥4.17). So KernelSU is wired with
the upstream `CONFIG_KSU_MANUAL_HOOK=y` API: real calls inserted into the core
kernel. `drivers/kernelsu/Kbuild` *fails the build* unless it finds the reboot
hook, so a half-integrated tree cannot ship silently.

Call sites inserted (all inside `#ifdef CONFIG_KSU`):

| file | function | handler |
|---|---|---|
| `fs/exec.c` | `__do_execve_file()` | `ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags)` |
| `fs/open.c` | `faccessat` | `ksu_handle_faccessat(&dfd, &filename, &mode, NULL)` |
| `fs/stat.c` | native `vfs_fstatat()` sites | `ksu_handle_stat(&dfd, &filename, &flag)` |
| `fs/read_write.c` | `read` syscall | `ksu_handle_sys_read(fd)` when `ksu_init_rc_hook` is active |
| `drivers/input/input.c` | `input_event()` | `ksu_handle_input_handle_event(&type, &code, &value)` when `ksu_input_hook` is active |
| `kernel/reboot.c` | `reboot` syscall | `ksu_handle_sys_reboot()` — the Kbuild manual-hook check |
| `kernel/sys.c` | `setresuid` syscall | `ksu_handle_setresuid(current_uid().val, ruid)`; upstream API takes old and new real UID |

There is intentionally **no** external hook in `security/selinux/hooks.c`:
upstream KernelSU-Next owns SELinux hiding internally, and the obsolete
`ksu_hide_setprocattr()` call was removed because that symbol is not part of the
pinned upstream source.

### Port fixup required by the SuSFS 4.14 patch

`include/linux/susfs_def.h` of this SuSFS port keeps `STATX_SUS_KSTAT` /
`STATX_SUS_KSTAT_FUSE` / `susfs_is_current_app_uid()` **inside the header** (it does
not touch `include/uapi/linux/stat.h`, unlike the GKI patch), but the hunk it applies
to `fs/stat.c` only adds the two `extern` prototypes and no include -- so the tree
fails with

```
fs/stat.c:84:6: error: implicit declaration of function 'susfs_is_current_app_uid' [-Werror,-Wimplicit-function-declaration]
fs/stat.c:90:26: error: use of undeclared identifier 'STATX_SUS_KSTAT'
```

`apply_ksu_hooks.py` therefore also performs this fixup (adds
`#include <linux/susfs_def.h>` plus `<linux/sched.h>` for `test_thread_flag()`, which
the header's `TIF_PROC_UMOUNTED` helpers need) inside the existing
`#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT` block, and `audit_hooks.sh` gates on it. The
`TIF_PROC_UMOUNTED 33` / `TIF_PROC_NO_SU 34` / `TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT 35`
bits come from `susfs_def.h` itself, so **no `arch/arm64/include/asm/thread_info.h`
change is needed** (bits 26-31 are unused there too, hence no clash with
`_TIF_WORK_MASK`), which is why the port ships no thread_info hunk.

Deliberately **not** done, and why:

* `security/security.c` — KernelSU SELinux hiding is handled internally by `feature/selinux_hide.c`; SuSFS SELinux logging hooks are in `security/selinux/avc.c`. Neither requires an external `setprocattr` call.
* `ksu_handle_newfstat_ret` / `fstat64_ret` / `init_mark_tracker` — the pinned official legacy source exposes none of those handlers; calling them would fail to link. The compat `COMPAT_SYSCALL_DEFINE4(newfstatat)` in `fs/stat.c` remains unhooked (its third argument is a compat `int`).
* `path_umount()`/`can_umount()` and `struct seccomp::filter_count` are carried
  in-tree for the pinned KernelSU-Next compatibility layer. Its Kbuild otherwise
  injects these with `sed -i` only when make descends into `drivers/kernelsu`,
  after `fs/namespace.o` and other objects may already have compiled. That caused
  an undefined `path_umount` at link time and could give `task_struct`
  inconsistent layouts because `struct seccomp` is embedded in it. The
  definitions and field are present before the build starts, so Kbuild's greps
  skip those racy edits. The `set_fs()` + `ksys_umount()` fallback remains
  available for kernels without `path_umount()`.
* The helper scripts in `tools/root-integration/scripts/` are kept for reference **but must not be run on this tree**: they target a different KernelSU handler API and are non-idempotent. Use `apply_ksu_hooks.py` instead.

## Reproducing the integration from a clean tree

```bash
# 1. KernelSU-Next official legacy source is pinned at cd739c78802333455391df973db17d9f28328b83
#    (the vendored tree already includes the local SuSFS v2.3.0 compatibility overlay)
cp -a KernelSU-Next <clean-tree>/KernelSU-Next
ln -sfn ../KernelSU-Next/kernel <clean-tree>/drivers/kernelsu
echo 'obj-$(CONFIG_KSU) += kernelsu/'      >> <clean-tree>/drivers/Makefile
echo 'source "drivers/kernelsu/Kconfig"'   >> <clean-tree>/drivers/Kconfig

# 2. SuSFS v2.3.0 (NON-GKI)
cd <clean-tree> && patch -p1 --fuzz=3 < ../tools/root-integration/patches/susfs/susfs_patch_to_4.14.patch

# 3. NoMount v2.0.0 built-in (kernel/README.md "Option A")
cp -a fs/nomount <clean-tree>/fs/nomount
echo 'obj-$(CONFIG_NOMOUNT) += nomount/'   >> <clean-tree>/fs/Makefile
echo 'source "fs/nomount/Kconfig"'         >> <clean-tree>/fs/Kconfig

# 4. DroidSpaces cgroup controller-prefix compatibility patch
#    (the companion xt_qtaguid patch is inapplicable: that source file is absent here)
python3 tools/root-integration/apply_droidspaces_cgroup.py <clean-tree>

# 5. Manual hooks (idempotent; --verify re-audits without writing)
python3 tools/root-integration/apply_ksu_hooks.py <clean-tree>

# 6. Defconfig (see next section) then audit
bash tools/root-integration/audit_hooks.sh <clean-tree>
```

The pre-V1.0.4 `root-integration-core.patch` is a historical snapshot and does not
contain the current official KernelSU-Next sync or its SuSFS compatibility overlay;
do not use it to reproduce this release. The pinned KSU tree, host hooks, SuSFS 4.14
patch, NoMount sources, and current defconfig in this repository are authoritative.

## defconfig

Appended to `arch/arm64/configs/vendor/xiaomi/miatoll_defconfig`:

```
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
# CONFIG_KSU_SUSFS_TRY_UMOUNT is not set   <-- required, see below
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
# CONFIG_KSU_SUSFS_SUS_MEMFD is not set
CONFIG_NOMOUNT=y
CONFIG_KALLSYMS_ALL=y
```

**`CONFIG_KSU_SUSFS_TRY_UMOUNT` must stay off.** The local KernelSU overlay only
references `susfs_try_umount()` (`hook/setuid_hook.c`) and
`susfs_add_try_umount()` (`supercall/supercall.c`) under that option, but the
SuSFS v2.3.0-for-4.14 port implements neither (it keeps only the deprecated
`CMD_SUSFS_ADD_TRY_UMOUNT` ID). Enabling the option would fail compilation; the
CI symbol audit rejects it before the build:

```
drivers/kernelsu/supercall/supercall.c:158:13: error: implicit declaration of function 'susfs_add_try_umount' [-Werror,-Wimplicit-function-declaration]
```

With the symbol off, the upstream KSU zygote umount path is used instead
(`feature/kernel_umount.c::ksu_handle_umount()`, driven by the `mount_list` supercalls
`KSU_UMOUNT_ADD/DEL/GETSIZE`/`WIPE`), which is the functional equivalent here and is
also what the deprecated SusFS userspace command no longer needs. `tools/root-integration/check_susfs_symbols.py`
cross-checks *every* `susfs_*` call in the overlay against the definitions this port
provides, honouring the guards in the defconfig, so this class of upstream/port skew fails
in the CI audit step rather than 9 minutes into the build (it also confirms
`CONFIG_KSU_SUSFS_SUS_MEMFD` must stay off for the same reason: no
`susfs_add_sus_memfd()` in this port).

`CONFIG_KSU_SYSCALL_TABLE_HOOK` stays off (needs ≥4.17). `# CONFIG_KPROBES is not set`
is left as the upstream defconfig has it, which is exactly why `KSU_MANUAL_HOOK` is
used. `CONFIG_FSNOTIFY`/`CONFIG_INOTIFY_USER` were already `y`, which upstream's
fsnotify-based `pkg_observer` requires. `CONFIG_KSU_SUSFS_SUS_MEMFD` stays off because
this 4.14 port has no `susfs_add_sus_memfd()` helper.

## DroidSpaces support on the legacy kernel

The miatoll defconfig enables the available non-GKI requirements from the
[DroidSpaces kernel configuration guide](https://github.com/ravindu644/Droidspaces-OSS/blob/ac38c11fef1402c0db8172ea8187db0401a0bc30/Documentation/Kernel-Configuration.md): System V IPC and POSIX
message queues; IPC/PID/UTS/user/network namespaces; seccomp filters; cgroup
scheduling, freezer, memory/device/PID/CPU accounting and network-priority
controllers; devtmpfs; OverlayFS; tmpfs xattrs/ACLs; firmware loading and user
helper; veth/bridge support; netfilter, conntrack/netlink, IPv4 NAT, nftables,
policy routing and IPv6 NAT/masquerading. User namespaces are enabled as required
for DroidSpaces' container isolation; this expands the kernel attack surface and
should be paired with Android userspace restrictions. The workflow checks these
symbols in both the miatoll defconfig audit and the resolved `.config` before
compiling.

The applicable DroidSpaces non-GKI cgroup-prefix compatibility patch is applied
by `tools/root-integration/apply_droidspaces_cgroup.py` to `kernel/cgroup/cgroup.c`;
it restores controller-prefixed symlinks on
`CGRP_ROOT_NOPREFIX` mounts. The guide's other non-GKI patch targets
`net/netfilter/xt_qtaguid.c`, which is absent from this tree, so it is not applied.

`CONFIG_CFS_BANDWIDTH` is gated by `!SCHED_WALT` in this 4.14 kernel, while miatoll
uses WALT. The scheduler is left unchanged, so DroidSpaces CPU-quota limits may be
unavailable. The guide's generic `CONFIG_NETFILTER_XT_TARGET_MASQUERADE` name is
not defined in this 4.14 tree; the IPv4/IPv6 equivalents
(`IP_NF_TARGET_MASQUERADE` and `IP6_NF_TARGET_MASQUERADE`) are enabled. Its
`CONFIG_NF_CONNTRACK_NETLINK` is named `CONFIG_NF_CT_NETLINK` here and is enabled.
`CONFIG_FW_LOADER_COMPRESS` and `CONFIG_ANDROID_PARANOID_NETWORK` are not defined
as Kconfig symbols, while `CONFIG_FW_LOADER_USER_HELPER` is enabled. The tree also
has no `DEVPTS_MULTIPLE_INSTANCES` Kconfig entry, so unknown defconfig keys are not
added; unavailable optional limits are reported as such.

## SELinux enforcement

The miatoll release configuration has `CONFIG_SECURITY_SELINUX=y` and
`CONFIG_DEFAULT_SECURITY_SELINUX=y`, with `CONFIG_SECURITY_SELINUX_DEVELOP`,
`CONFIG_SECURITY_SELINUX_BOOTPARAM`, and `CONFIG_SECURITY_SELINUX_DISABLE` all
unset. This builds SELinux in hard-enforcing mode: the kernel does not start in
permissive mode, and the development-only `enforcing=0`/runtime setenforce and
SELinux boot-disable paths are unavailable. The Actions workflow checks this
security posture in the resolved `.config` before compiling.

This is a security-sensitive behavior change; an incompatible device policy can
cause denials or prevent userspace from booting. Verify the ROM's SELinux policy
before flashing. Android properties such as `ro.boot.selinux` are userspace boot
properties and are not defined by this kernel defconfig. The AnyKernel3 installer
now normalizes the unpacked boot-image command line before repacking, removing
conflicting duplicates and setting `androidboot.selinux=enforcing`, `enforcing=1`,
and `selinux=1`. It preserves unrelated arguments and supports both `cmdline.txt`
and `header` unpacker formats. `test_selinux_cmdline.sh` regression-tests this
helper before the Actions build. This does not change bootloader/vendor-provided
arguments or bootconfig; confirm `getenforce` and `getprop ro.boot.selinux` on the
target device. No userspace property/status spoofing is performed.

## NoMount on 4.14 — what was checked

The v2.0.0 kernel source carries compat shims for `<5.12 / <5.11 / <5.10 / <4.18 /
<4.17 / <4.16 / <4.11 / <4.9 / <4.6` kernels; ours lands in the pre‑5.12 branches
(e.g. `getattr(dentry, inode, &stat, 0, 0)` takes flags+request_mask,
`notify_change(dentry, &attr, NULL)`). `full_name_hash()` on 4.14 was verified to be
the *salted* `full_name_hash(salt, name, len)` form (already salted since 4.10 here,
`include/linux/stringhash.h`), so the `<4.16/<4.9/<4.6` un-salted shims do not apply
and no compat patch was needed. Arity of every kernel API NoMount touches was
audited (`__vfs_getxattr`, `__vfs_{set,rem}ovexattr`, `dentry_open`,
`vfs_{get,getattr_nosec}_nofollow`, `generic_fillattr`, `set_nlink`,
`get_user_pages_fast(…, int write, …)`, `d_backing_inode`, `IDMAP_*`, `NM_ACTOR_*`,
`nm_call_iterate`) — see `tools/root-integration/upstreams.json`; nothing in
`fs/nomount/` was modified.

## eBPF

The requirement was "a 5.10-level eBPF backport must exist; if it is missing, add
backport patches". Audit of this tree (2026‑09‑24):

*Present* — `kernel/bpf/` has `btf.c`, `core.c` (CO‑RE relocations), `verifier.c`,
`syscall.c`, `dispatcher.c`, `trampoline.c`, `bpf_struct_ops.c` +
`bpf_struct_ops_types.h`, `bpf_lsm.c`, `ringbuf.c`, `bpf_iter.c`, `task_iter.c`,
`prog_iter.c`, `map_iter.c`, `bpf_local_storage.c`, `bpf_inode_storage.c`,
`local_storage.c`, `preload.c`, `offload.c`, `sysfs_btf.c`, `disasm.c`, so the
infrastructure is at 5.10 level or beyond. `include/uapi/linux/bpf.h` exposes
`BPF_PROG_TYPE_{LSM,STRUCT_OPS,EXT}`, `BPF_MAP_TYPE_{RINGBUF,STRUCT_OPS,INODE_STORAGE}`,
`BPF_TRACE_ITER`, and `bpf_spin_lock` is wired in the verifier. `tools/lib/bpf`
(libbpf) and `samples/bpf` build against it.

*Absent* — features newer than 5.10: `bpf_for_each_map_elem` (5.11), `bpf_timer` /
`bpf_snprintf` (5.15), `bpf_loop` (5.17), `bpf_copy_from_user_task` (5.11),
`BPF_MAP_TYPE_TASK_STORAGE` (5.18), `BPF_PROG_TYPE_SYSCALL`, `BPF_TOKEN`,
`BPF_MAP_TYPE_{ARENA,BLOOM_FILTER,USER_RINGBUF,CGRP_STORAGE}` (5.15+/6.x churn).

**Verdict: no eBPF changes were made.** The 5.10-level requirement is satisfied, and
the items above are all *post*-5.10 work whose backport onto a 4.14 `struct bpf_prog` /
`btf` / trampoline layout (no `bpf_prog_pack`, no `asm-generic/barrier` bits, 4.14
module allocator, no `CONFIG_BPF_JIT_ALWAYS_ON`) is a multi-thousand-line surgery that
would put the *boot* of the device at risk for zero benefit to the root stack — KSU,
SuSFS and NoMount never touch eBPF, and neither does the `=y` SELinux/selinuxfs work
they rely on. If an eBPF-based daemon on this device ever needs `bpf_loop`-class
helpers, that is a separate, testable project (see "what is missing" above).

## Building (clang 18 only)

`.github/workflows/kernel-build.yml`:

* The workflow installs LLVM 18 from apt.llvm.org (with the runner's clang-18
  package as fallback), pins the selected tools on `PATH`, and asserts that
  `clang --version` contains `version 18`.
* Kernel flags: `LLVM=1 LLVM_IAS=1 CC=clang CLANG_TRIPLE=aarch64-linux-gnu-
  CROSS_COMPILE=aarch64-linux-gnu- LD=ld.lld AR=llvm-ar NM=llvm-nm
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf
  STRIP=llvm-strip SIZE=llvm-size HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld
  HOSTAR=llvm-ar KCFLAGS="-Wno-error"`. `LLVM=1` is honoured by this tree's top
  Makefile (lines ~391-400), which is why no GNU tool is looked up; `CROSS_COMPILE`
  is only there so the Makefile emits `--target=aarch64-linux-gnu` for clang, and
  `LLVM_IAS=1` keeps the integrated assembler (no `as` needed; `AS` is unused by
  this tree anyway since `.S` files go through `$(CC)`). `--gcc-toolchain` stays
  empty because no `aarch64-linux-gnu-elfedit` exists on the runner — **CI installs
  no gcc and no binutils-aarch64-linux-gnu**, so a stray GNU dependency would fail
  loudly rather than silently mixing toolchains. `CROSS_COMPILE_ARM32` is not
  needed: `arch/arm64/kernel/vdso/` here is AArch64-native.
* No `pahole` needed: the defconfig has no `CONFIG_DEBUG_INFO_BTF`/CTF.
* `KSU_VERSION_OVERRIDE` / `KSU_VERSION_TAG_OVERRIDE` are passed because the
  vendored source is not a standalone git checkout (upstream Kbuild otherwise uses
  its fallback version/tag).
* Pre-build gate: the workflow runs `apply_ksu_hooks.py --verify` and
  `audit_hooks.sh`, and greps the produced `.config` for
  `CONFIG_KSU=y CONFIG_KSU_SUSFS=y CONFIG_NOMOUNT=y CONFIG_KSU_MANUAL_HOOK=y`.
* Post-build gate: `llvm-nm out/vmlinux | grep ' [Tt] ksu_'` must be non-empty.
* Target is `Image.gz` (this defconfig has no `BUILD_ARM64_APPENDED_DTB_IMAGE`, the
  DTB lives in its own `dtb` partition — AnyKernel3 does nothing with it).
  `build.sh` is the same recipe for local builds.

The old recipe (`build.sh` before this change) cloned a clang‑9 build and LineageOS
gcc‑4.9 prebuilts for `CROSS_COMPILE`; that is gone — the toolchain is now clang‑18 +
LLVM binutils for target *and* host.

## Releasing

The release workflow accepts both `v*` and `V*` tags. For this release it publishes
**V1.0.4** from the manually dispatched GitHub Actions workflow (`make_release: true`,
`release_tag: V1.0.4`), using [`docs/release-notes.md`](release-notes.md) as its
release description. The zip carries `Image.gz`, `kernel-notes.txt` (component
versions and build date), and a `.sha256sum` file. `AnyKernel3/anykernel.sh` is patched with
`kernel.string`, `kernel.compiler`, `kernel.version` and the `twrp`/`orangefox`
recovery detection is left untouched (`is_slot_device=0`, A‑only,
`/dev/block/bootdevice/by-name/boot`).

## Userspace side (not part of this repo)

* **Manager**: install a KernelSU‑Next manager compatible with the upstream UAPI
  pinned above and the release build's `KSU_VERSION=33294` override. The Android
  manager APK is not vendored in this kernel repository.
* **SuSFS**: `susfs4ksu` module must ship the **v2.x `ksu_susfs`** helper. The v1.5.x
  `susfs4ksu.sh` is incompatible with the v2.3.0 kernel patch (and
  `add_open_redirect` gained a third `<UID_SCHEME>` argument).
* **NoMount**: rules are managed with `nm` over the kernel **keyring** (`add_key()`),
  there is no ioctl node: `nm rule add <virtual> <real>`,
  `nm rule add --whiteout <path>`, `nm uid add <uid>`, `nm rule list [--json]`,
  `nm clear all`, `nm version`. Upstream ships it as a KSU/APatch **metamodule**
  (with WebUI); the release ZIP's prebuilt LKMs do **not** apply to legacy kernels —
  that's why it is compiled in here.
* NoMount's `CONFIG_NOMOUNT=m` path (`make O=out M=fs/nomount modules`) works too if
  you prefer modules; this tree uses `=y`.
