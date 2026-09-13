# Flatcar Base Migration Design

**Status:** Proposed design

## Problem

Bluefin Server currently composes its OS payload from two incompatible
software domains:

- Userspace from freedesktop-sdk 26.08 (`components/*`): systemd 261, glibc
  from the FSDK bootstrap, `uutils-coreutils`, `openssh-systemd`, `podman`,
  `xfsprogs`, `gnupg`.
- Kernel and out-of-tree modules from Flatcar stable 4593.2.5
  (`flatcar/flatcar-kernel.bst`, `flatcar/flatcar-zfs.bst`): kernel
  `6.12.102-flatcar`, ZFS built against that kernel, both shipped as prebuilt
  binaries.

Every defect class hit during installer bring-up came from the seam between
those two domains, not from either domain individually:

- The installer builds the *target* OS initrd with FSDK `dracut` against the
  Flatcar module tree (`elements/oci/bluefin-server-installer.bst`, step 1b,
  `--kmoddir /target-root/usr/lib/modules/${TARGET_KVER}`). Flatcar nests its
  modules at `usr/lib/modules/6.12.102-flatcar/6.12.102-flatcar/`, which FSDK
  tooling does not expect, and storage drivers silently went missing from the
  initrd.
- USB and SCSI storage drivers had to be force-loaded and `udevadm settle`
  polled by hand before `systemd-sysinstall` would see the target disk.
- `os-release-flatcar.bst` already lies about identity (`ID=flatcar`,
  `CPE_NAME=cpe:/o:flatcar-linux:...`) purely so Flatcar sysexts will attach to
  an FSDK userspace. The sysext compatibility check passes on a fiction.

The repository therefore maintains a permanent ABI straddle to obtain one
thing: a long-term-support kernel with a matching, prebuilt ZFS module.

## Goals

- Collapse to a single ABI domain: kernel, userspace, and system extensions
  from one upstream with one vermagic, one glibc, one systemd.
- Keep BuildStream as the only build system and the DDI/installer contract
  unchanged.
- Keep the installer `systemd-sysinstall`-native and `systemd-repart`-based.
- Delete the hand-written initrd repair path in favor of upstream artifacts.
- Gain an upstream SBOM, package manifest, and signed digests for the OS
  payload.
- Make `ID=flatcar` true rather than cosmetic.

## Non-goals

- Rebuilding Flatcar packages from source in BuildStream. Flatcar is a
  Gentoo/portage cross-build driven by its own SDK; reproducing it under
  `bst` is a multi-year effort with no payoff. This design imports Flatcar
  binaries the same way `flatcar-kernel.bst` and `flatcar-zfs.bst` already do.
- Adopting Flatcar's update stack (`update_engine`, `locksmithd`) or its
  provisioning stack (Ignition, `coreos-cloudinit`). Bluefin Server stays on
  `systemd-sysupdate` plus Kured.
- Changing the k0s delivery model. k0s stays an optional sysext.
- arm64 support. Flatcar publishes `arm64-usr`; that is follow-on work.

## Upstream artifact survey

Measured against `https://stable.release.flatcar-linux.net/amd64-usr/4593.2.5/`
on 2026-09-13. Every artifact carries `.DIGESTS`, `.DIGESTS.asc`, and `.sig`
companions, so each import can be pinned by sha256 in `bst` and independently
GPG-verified at release time.

| Artifact | Size | Contents |
|---|---|---|
| `flatcar-container.tar.gz` | 377 MiB | Complete OS tree: `/usr` (19,658 entries), `/boot`, `/oem` |
| `flatcar_production_image_sysext.squashfs` | 418 MiB | The same `/usr`, packaged as a verity-capable sysext squashfs |
| `flatcar_production_image.vmlinuz` | 32 MiB, in use today | Kernel `6.12.102-flatcar` **with a two-stage initramfs compiled in** (`CONFIG_INITRAMFS_SOURCE="bootengine.cpio"`) |
| `flatcar_production_pxe.vmlinuz` | 32 MiB | Byte-for-byte the same size as the above; same kernel, same embedded initramfs |
| `flatcar_production_pxe_image.cpio.gz` | 374 MiB | Four cpio entries wrapping `usr.squashfs`; a RAM-boot OS payload, **not** a driver initrd |
| `flatcar_production_image_initrd_contents.txt` / `_realinitrd_contents.txt` | text | Per-stage manifests for the embedded initramfs: 339 and 2,280 entries |
| `usr/lib/flatcar/bootengine.img` (inside the tarball) | 50 MiB | Stage 2 of that initramfs, standalone: squashfs, 2,280 entries, `/init` + `/etc/initrd-release` |
| `flatcar-zfs.raw` | 3 MiB | ZFS sysext (in use today) |
| `flatcar-podman.raw` | 33 MiB | Podman sysext |
| `rootfs-included-sysexts/containerd-flatcar.raw` | 24 MiB | containerd sysext |
| `rootfs-included-sysexts/docker-flatcar.raw` | 54 MiB | Docker sysext |
| `flatcar_production_image_packages.txt`, `_contents.txt`, SBOM | text | Package manifest and provenance |
| `version.txt` | text | `FLATCAR_VERSION=4593.2.5`, `FLATCAR_BUILD_ID="2026-08-11-2350"` |

Verified contents of `flatcar-container.tar.gz`:

- systemd 257 (`usr/lib/systemd/libsystemd-shared-257.so`).
- glibc 2.41 (`usr/lib64/glibc-2.41/`).
- Everything the current design depends on is present: `systemd-repart`,
  `systemd-sysext`, `systemd-confext`, `systemd-sysupdate`, `systemd-creds`,
  `bootctl`, `machinectl`, `systemd-nspawn`, `bash`, `sshd`, `crictl`.
- Flatcar's own stack that must be masked or stripped: `update_engine`,
  `update_engine_client`, `locksmithd`, `ignition`, `coreos-cloudinit`,
  `flatcar-update`, `download_sysext`, `ensure-sysext.service`.
- `systemd-sysinstall` is **absent** — it is an FSDK 261 tool.

## Design

### Split the two images by role

The installer and the installed OS stop sharing a userspace.

- **Installer** stays FSDK 26.08. It is the only consumer of
  `systemd-sysinstall`, which does not exist in systemd 257. Hard rule 3 is
  preserved untouched.
- **Installed OS DDI** becomes Flatcar `/usr` plus the Bluefin overlay.

This split is safe because the installer's contract with the DDI is
byte-level, not content-level: `files/installer/repart.d/20-root.conf` copies
the DDI into the root partition with `CopyBlocks=`. Nothing in the installer
inspects the payload's userspace. Changing what is inside the XFS image does
not change how it is written.

### New element: `flatcar/flatcar-usr.bst`

`kind: manual`, mirroring the existing `flatcar-zfs.bst` import pattern:

- `sources:` one `kind: remote` entry for
  `flatcar:stable/%{flatcar-board}/%{flatcar-version}/flatcar-container.tar.gz`,
  pinned by `ref:` sha256, using the existing `flatcar:` alias in
  `include/aliases.yml`.
- `variables: strip-binaries: ""` (prebuilt binaries; the FSDK stripper must
  not touch them).
- `install-commands:` extract `./usr` into `%{install-root}/usr`, then remove
  the update and provisioning stack listed above, and flatten Flatcar's nested
  module directory to the single-level layout the rest of the tree expects.

Removals are explicit `rm` lines with a comment naming the replacement, not a
wildcard sweep, so a future Flatcar bump that renames a unit fails loudly.

### Overlay: what Bluefin keeps

These elements are OS policy, not upstream software, and carry over unchanged:

`os-release-flatcar.bst` (now truthful), `os-sysupdate.bst`,
`os-k0s-sysupdate.bst`, `os-sysupdate-keys.bst`, `os-networkd.bst`,
`os-k0s-first-boot.bst`, `os-creds-prov.bst`, `os-kured-hook.bst`,
`os-justfile.bst`, `os-issue.bst`, `os-image-info.bst`, `os-countme.bst`,
`os-sshd-preset.bst`, `os-sshd-config.bst`.

### Overlay: what Flatcar displaces

Removed from the OS payload once the Flatcar base lands:

| Current element | Replacement |
|---|---|
| `freedesktop-sdk.bst:public-stacks/runtime-minimal.bst` | Flatcar `/usr` |
| `freedesktop-sdk.bst:components/systemd.bst` | Flatcar systemd 257 |
| `freedesktop-sdk.bst:components/dbus.bst`, `dbus-broker.bst`, `kmod.bst`, `shadow.bst` | Flatcar `/usr` |
| `freedesktop-sdk.bst:bootstrap/bash.bst` | Flatcar `/usr/bin/bash` |
| `bluefin-server/uutils-coreutils.bst` | Flatcar coreutils |
| `freedesktop-sdk.bst:components/openssh-systemd.bst` | Flatcar `/usr/bin/sshd` |
| `freedesktop-sdk.bst:components/podman.bst` | `flatcar-podman.raw` sysext |
| `freedesktop-sdk.bst:components/xfsprogs.bst`, `gnupg.bst`, `ca-certificates.bst`, `tzdata.bst` | Flatcar `/usr` |
| `bluefin-server/linux-firmware-split.bst` | Flatcar firmware in `/usr/lib/firmware` |

Moving Podman from the base DDI to a sysext also brings the tree into line
with hard rule 4, which already forbids container runtimes in the base DDI.

### Initrd: the kernel already has one

The FSDK `dracut` invocation for the target OS initrd is deleted, and nothing
replaces it. The kernel this repository already imports ships a complete,
two-stage initramfs compiled in.

`flatcar_production_image_kernel_config.txt` for this release states it
directly:

```
CONFIG_BLK_DEV_INITRD=y
CONFIG_INITRAMFS_SOURCE="bootengine.cpio"
CONFIG_INITRAMFS_COMPRESSION_XZ=y
```

Flatcar publishes a manifest for each stage:

| Stage | Manifest | Entries | Contents |
|---|---|---|---|
| 1 | `flatcar_production_image_initrd_contents.txt` | 339 | `rootfs-0/` shim: a 6,772-byte `/init`, busybox, `kmod`, `dmsetup`, `veritysetup`, and empty `/realinit` + `/sysusr/usr` mount points |
| 2 | `flatcar_production_image_realinitrd_contents.txt` | 2,280 | The systemd initrd - byte-identical entry count to `/usr/lib/flatcar/bootengine.img` |

Stage 1 is a busybox shim. It is the only stage compiled into the kernel; the
`realinit` entry in its cpio is an empty directory. Stage 2 is
`bootengine.img`, a 50 MiB squashfs built by `sys-kernel/bootengine` 0.0.38-r40
from Flatcar's dracut module set, carrying `/init`, `/etc/initrd-release`, and
`/etc/cmdline.d/10-default.conf`. Stage 1 loop-mounts it **from the `/usr` it
just mounted**, so stage 2 versions with the OS payload automatically rather
than with the kernel. It conforms to the systemd initrd interface exactly as
`docs/INITRD_INTERFACE.md` prescribes.

`flatcar_production_image.vmlinuz` and `flatcar_production_pxe.vmlinuz` are
both 34,245,760 bytes: one kernel, one embedded stage 1, two names.

The consequence is that `elements/flatcar/flatcar-kernel.bst` has been
importing a self-sufficient kernel all along, and the installer has been
building a second initrd to lay on top of it.

`flatcar_production_pxe_image.cpio.gz` is not a driver initrd. It is a
four-entry cpio whose payload is `usr.squashfs` at 374 MiB, and stage 1 has an
explicit branch for it: when no `/usr` partition is found and `/usr.squashfs`
exists in the initramfs, that file becomes `/usr` with `usrfstype=squashfs`.
It is the PXE path, not the disk path.

### Verified by experiment

The claim above is not inferred from the kernel config alone. Booting the
pinned kernel in QEMU with **no `-initrd` argument and no disk attached**:

```
qemu-system-x86_64 -enable-kvm -m 2048 -cpu host -nographic -no-reboot \
  -kernel <cached flatcar_production_image.vmlinuz> \
  -append "console=ttyS0,115200n8 root=LABEL=ROOT usr=PARTLABEL=USR-A"
```

produced:

```
[    0.000000] Linux version 6.12.102-flatcar (build@pony-truck.infra.kinvolk.io) ...
[    0.025767] Kernel command line: rootflags=rw mount.usrflags=ro console=ttyS0,115200n8 root=LABEL=ROOT usr=PARTLABEL=USR-A
[    1.053101] Run /init as init process
[    1.171015] SCSI subsystem initialized
...
Waiting for drive...
Still waiting for drive...
```

Three facts fall out of those six lines:

- `Run /init as init process` with no initrd supplied proves the initramfs is
  compiled in and live, not merely declared in the config.
- Stage 1 loaded storage modules and then blocked on `Waiting for drive...`,
  which is the busybox shim hunting for `usr=PARTLABEL=USR-A`. With no disk
  attached it waits forever. That message is the boot contract asserting
  itself.
- `rootflags=rw mount.usrflags=ro` appears **before** the appended arguments:
  the kernel carries a built-in `CONFIG_CMDLINE` that any UKI cmdline is
  merged with, not a replacement for.

### The boot contract: decided, conform to it

**Decision: follow Flatcar's design.** The OS payload becomes a `/usr` image on
a verity-protected A/B partition pair, and `/` becomes writable state. The
alternatives - overriding the built-in initramfs, or generating one with
`mkosi-initrd` - are dropped.

The contract is not guesswork. Stage 1's `/init` was extracted from the kernel
and read directly; it is 6,772 bytes of shell and the relevant logic is exact:

```sh
verityusr=$(cmdline_arg verity.usr)
usrhash=$(cmdline_arg verity.usrhash)
verityusr=$(find_drive "${verityusr}")
if echo "${verityusr}" | grep -q "^/" && [ "${usrhash}" != "" ]; then
  veritysetup --panic-on-corruption --hash-offset=1065345024 open "${verityusr}" usr "${verityusr}" "${usrhash}"
  status=$(dmsetup status usr | cut -d " " -f 4)
  [ "${status}" = V ] || { echo "Verity setup failed" >&2; false; }
fi
usr=$(cmdline_arg mount.usr $(cmdline_arg usr))
usrfstype=$(cmdline_arg mount.usrfstype $(cmdline_arg usrfstype auto))
usrflags=$(cmdline_arg mount.usrflags $(cmdline_arg usrflags ro))
mount -t "${usrfstype}" -o "${usrflags}" "${usr}" /sysusr/usr
losetup -r "${LOOP}" /sysusr/usr/lib/flatcar/bootengine.img
mount -t squashfs "${LOOP}" /underlay
mount -t overlay -o rw,lowerdir=/underlay,upperdir=/work/realinit,workdir=/work/work overlay /realinit
mount -o move /sysusr/usr /realinit/sysusr/usr
exec switch_root /realinit /init
```

Seven consequences, each load-bearing:

1. **Verity is one partition, not two.** `--hash-offset=1065345024` is
   hardcoded, with the comment "Hardcoded expected value from the image GPT
   layout". The filesystem occupies the first 1,065,345,024 bytes and the
   verity hash tree follows it in the same partition. This is incompatible with
   `systemd-repart`'s `Verity=data` / `Verity=hash` two-partition model, so the
   image is built with the hash appended by the DDI element and `repart` simply
   `CopyBlocks=` the result - the existing contract, unchanged.
2. **Our `/usr` must fit in 1,065,345,024 bytes.** Flatcar's own uses 454 MiB of
   it. This is a hard build-time budget, and the DDI element must fail loudly
   when exceeded rather than silently corrupt the hash offset.
3. **Verity is optional.** The block is guarded by
   `[ "${usrhash}" != "" ]`. Landing the partition layout without verity is a
   valid intermediate state, so layout and verity split cleanly into two
   tickets.
4. **The root hash must reach the kernel cmdline** as `verity.usrhash=`.
   Flatcar publishes theirs per release in
   `flatcar_production_image_verity.txt`
   (`20b08968dc4527a622b7f9f0ba9b6e1a16377500f1f9f93231712ccb45150570`). Ours is
   an output of our own DDI build, baked into the UKI cmdline by `ukify`. That
   binds each UKI to exactly one `/usr` image, which is precisely the property
   A/B updates need.
5. **The `/usr` filesystem stays XFS.** `mount -t "${usrfstype}"` passes the
   type through, so `mount.usrfstype=xfs` works. Only `auto` and `btrfs` get
   Flatcar's `rescue=nologreplay` special-casing.
6. **`/usr/lib/flatcar/bootengine.img` must survive the import.** Stage 1
   loop-mounts it from the mounted `/usr`; without it the boot stops between
   stages. It is an explicit keep in the `flatcar-usr.bst` strip list, not an
   incidental leftover.
7. **Ignition needs no masking.** Measured, not assumed: on a disk with no
   Ignition config, stage 2 runs `ignition-setup-pre.service` to completion,
   skips `ignition-delete-config.service` ("no trigger condition checks were
   met"), and reaches `ignition-subsequent.target - Subsequent (Not Ignition)
   boot complete`. The state machine degrades to a no-op on its own. Masking
   is available if a future unit misbehaves, but it is not a prerequisite.

### Target partition layout

Flatcar's own GPT, read from `flatcar_production_image.bin`:

| # | PARTLABEL | MiB | Type GUID |
|---|---|---|---|
| 1 | `EFI-SYSTEM` | 1024 | `c12a7328-f81f-11d2-ba4b-00a0c93ec93b` |
| 2 | `BIOS-BOOT` | 2 | `21686148-6449-6e6f-744e-656564454649` |
| 3 | `USR-A` | 2048 | `5dfbf5f4-2848-4bac-aa5e-0d9a20b745a6` |
| 4 | `USR-B` | 2048 | `5dfbf5f4-2848-4bac-aa5e-0d9a20b745a6` |
| 6 | `OEM` | 1024 | `0fc63daf-8483-4772-8e79-3d69d8477de4` |
| 7 | `OEM-CONFIG` | 64 | `c95dc21a-df0e-4340-8d7b-26cbfa9a03e0` |
| 9 | `ROOT` | 1784 | `3884dd41-8582-4404-b9a8-e9b84f2df50e` |

Partitions 5 and 8 are absent; the numbering is ChromeOS heritage.

What Bluefin Server adopts, as `repart.d` drop-ins replacing the current
`10-esp.conf` / `20-root-a.conf` / `30-var.conf`:

| PARTLABEL | Type | Source | Notes |
|---|---|---|---|
| `EFI-SYSTEM` | ESP, vfat | `bootctl install` + UKI | Carries the UKI whose cmdline pins `verity.usrhash=` |
| `USR-A` | `5dfbf5f4-…` | `CopyBlocks=` the `/usr` DDI | Read-only, verity, 2048 MiB |
| `USR-B` | `5dfbf5f4-…` | empty | The A/B slot `50-root.transfer` already names but the installer never provisioned |
| `OEM` | `0fc63daf-…` | `Format=ext4`, `Label=OEM` | Required: stage 2 waits on `dev-disk-by-label-OEM.device` |
| `ROOT` | `3884dd41-…` | `Format=`, `GrowFileSystem=yes` | Writable state |

`BIOS-BOOT` is dropped: this is a UEFI-only image, per hard rule 5.
`OEM` is **required**, not optional. Stage 2 declares a dependency on
`dev-disk-by-label-OEM.device`; without it the boot waits 90 seconds and drops
to an emergency shell. Note the match is on **filesystem label** `OEM`, not
partition label, so the partition must be formatted with `mke2fs -L OEM` or
equivalent. `OEM-CONFIG` is dropped: nothing in the boot path references it.

This closes the known gap recorded as an `xfail` in
`tests/unit/test_repart_layout.py`, where `50-root.transfer` names both slots
but the installer provisions only one. Roadmap items 1, 2, and 3 - A/B slots,
read-only `/usr`, dm-verity - arrive as a consequence of conforming rather than
as three separate projects.

### Boot proof

The adopted design was booted end to end before any Bluefin code was written,
using only upstream artifacts and unprivileged tooling (`mksquashfs`,
`mke2fs -d`, `sfdisk`; no root, no loop mounts).

A 10 GiB GPT was built with Flatcar's type GUIDs: `EFI-SYSTEM`, `USR-A`,
`USR-B`, `OEM`, `ROOT`. Flatcar's `/usr` tree was packed with `mksquashfs`
(356 MiB, against the 1,065,345,024-byte budget) and written into `USR-A`;
`OEM` and `ROOT` were `mke2fs -d` ext4 images. The pinned kernel was booted
with no external initrd:

```
-append "console=ttyS0,115200n8 mount.usr=PARTLABEL=USR-A \
         mount.usrfstype=squashfs mount.usrflags=ro root=PARTLABEL=ROOT rootfstype=ext4"
```

The full chain ran:

```
[    1.122448] Run /init as init process
Mounting /usr from /dev/vda2
[    1.776610] systemd[1]: Successfully made /usr/ read-only.
[    1.788585] systemd[1]: systemd 257.9 running in system mode
[    1.794580] systemd[1]: Running in initrd.
[    4.133550] systemd[1]: Switching root.
Welcome to Flatcar Container Linux by Kinvolk 4593.2.5 (Oklo)!
[  OK  ] Reached target multi-user.target - Multi-User System.
localhost login:
```

SSH host keys were generated and DHCP brought `ens3` up on `10.0.2.15`. Every
claim in this section - `PARTLABEL` resolution, read-only `/usr`,
`bootengine.img` loop-mount, `switch_root`, Ignition degrading to a no-op - is
from that trace rather than from reading upstream code.

Two corrections came out of it, both folded in above: `OEM` is required, and
Ignition needs no masking.

### Versioning

`project.conf` `release-version` is currently derived from and enforced
against the FSDK junction ref by `.github/scripts/check-release-version.py`.
After the split, the FSDK pin describes only the installer, while the OS
payload's real version is `FLATCAR_VERSION`. The release version needs two
axes recorded and enforced separately. This is an invariant change, not a
string edit, and gets its own ticket ahead of any element work.

## Second opinion: the version-parity plan

A competing plan proposes **version parity**: read the component versions
Flatcar ships and rebuild those same versions from source inside BuildStream,
with three kernels (Flatcar LTS, Fedora CoreOS, Ubuntu), a Flatcar-versioned
`k8s` sysext replacing k0s, and A/B slots as `root-a`/`root-b`.

Adopted from it:

- **Single source of truth for pins.** Extend `include/flatcar.yml` to carry
  every pinned upstream version, with a single-consumer rule so no element or
  script hardcodes one. Good discipline, orthogonal to the base swap.
- **Provisioning parity via `systemd-creds`**, covering SSH keys, networkd
  configuration, `systemd-firstboot`, and TPM2 sealing. This design keeps
  `systemd-sysinstall` + `systemd-creds` and rejects Ignition, which the other
  plan agrees with; its provisioning workstream is real work this spec did not
  cover.
- **Reboot coordination for non-Kubernetes hosts**, matching roadmap item 6.

Rejected, with reasons:

- **"Rebuild Flatcar's versions from source in BuildStream."** Version parity
  is not ABI parity. Flatcar's kernel banner reads
  `x86_64-cros-linux-gnu-gcc (Gentoo Hardened 14.3.1_p20250801 p4)`; rebuilding
  "the same version" under the FSDK toolchain produces different binaries with
  different behavior, which is precisely the seam this migration exists to
  close. It also means maintaining forks of Flatcar's forks.
- **Three kernels built from upstream tarballs.** The premise that Flatcar has
  "Ubuntu-based builds" is not true of any published release. More decisively,
  the boot proof above depends on `CONFIG_INITRAMFS_SOURCE="bootengine.cpio"`:
  a kernel built from a plain upstream tarball has no embedded initramfs, so
  each additional kernel re-creates the initrd problem this design removes.
- **Deleting the k0s sysext for a Flatcar `k8s` sysext.** That plan's own risk
  table concedes the Flatcar sysext is "binaries-only, not a full control
  plane" and that dropping k0s "removes the single-node k8s story". The
  KubeStellar console path depends on it.
- **A/B as `root-a`/`root-b`.** Superseded by measurement: Flatcar's A/B pair
  is `USR-A`/`USR-B` with type GUID `5dfbf5f4-2848-4bac-aa5e-0d9a20b745a6`,
  and `/` is writable state. Mirroring the whole-rootfs DDI into a second slot
  does not satisfy the initramfs contract.
- **"Enforce read-only `/usr` via fstab or cmdline `ro`."** Already automatic:
  `mount.usrflags=ro` produced `Successfully made /usr/ read-only` in the
  trace. No additional mechanism needed.

## Rejected alternatives

- **Rebuild Flatcar from source under `bst`.** Rejected: Flatcar is a
  portage/SDK cross-build of thousands of ebuilds. The effort is unbounded and
  buys nothing that a pinned, digest-verified binary import does not.
- **Status quo hybrid.** Rejected: it permanently straddles two ABI domains
  and requires the identity fiction in `os-release-flatcar.bst` to function.
- **Boot Flatcar's `/usr` with dm-verity, as upstream does.** **Adopted.** Not
  a follow-on and not optional: stage 1 hardcodes
  `--hash-offset=1065345024` and expects `verity.usr=` / `verity.usrhash=`, so
  this is simply how the embedded initramfs boots. See "The boot contract:
  decided, conform to it".
- **Override the built-in initramfs with a generated one**, via dracut or
  `mkosi-initrd --generic`. Rejected: it is what the repository does today and
  what this design exists to stop. Keeping it means owning an initrd generator
  and a foreign module tree forever.

## Migration phases

Each phase is independently landable and independently verifiable.

1. **Decision and invariants.** Amend hard rule 1 to scope FSDK composition to
   the installer and permit pinned Flatcar binary imports for the OS payload.
   Record this design as an ADR. Split the release-version axes.
2. **Import elements.** `flatcar/flatcar-usr.bst` plus a sysext family for
   `podman`, `containerd`, `docker`. Contract tests assert the update and
   provisioning stack is absent, the module layout is flat, and
   `/usr/lib/flatcar/bootengine.img` is preserved.
3. **Partition layout.** Replace `repart.d/10-esp.conf`, `20-root-a.conf`, and
   `30-var.conf` with Flatcar's `EFI-SYSTEM` / `USR-A` / `USR-B` / `ROOT`
   layout using upstream type GUIDs. Verity stays off at this stage, which
   stage 1 explicitly permits, so the layout can be proven on its own.
4. **`/usr` DDI.** The OS payload becomes a `/usr` image sized to the
   1,065,345,024-byte budget with the verity hash tree appended, and its root
   hash is baked into the UKI cmdline as `verity.usrhash=`.
5. **Boot proof.** `just show-me-the-future` installs and boots on the kernel's
   built-in initramfs with Ignition masked; the Lima end-to-end test drives the
   KubeStellar console login against it.
6. **Cutover.** `os-stack.bst` switches to the Flatcar base; the displaced FSDK
   elements and the `dracut` target-initrd path are deleted.
7. **Follow-on.** Wire `50-root.transfer` to the real `USR-A`/`USR-B` slots and
   retire the `xfail` in `tests/unit/test_repart_layout.py`; arm64.

## Verification

- `just validate` after every element change.
- `python3 .github/scripts/docs-checks.py`.
- `pytest tests/unit` including new contract tests for the import elements.
- `just cluster-build` on the ghost cluster for heavy builds.
- `just show-me-the-future` QEMU install-and-boot smoke test.
- `just test-e2e-lima` for the console login path.

## See also

- [docs/skills/gap-analysis-distros.md](../../skills/gap-analysis-distros.md) - distro comparison that framed this.
- [docs/skills/architecture-roadmap.md](../../skills/architecture-roadmap.md) - A/B slots and verity follow-on.
- [docs/skills/ddi-installer.md](../../skills/ddi-installer.md) - installer and DDI contract.
