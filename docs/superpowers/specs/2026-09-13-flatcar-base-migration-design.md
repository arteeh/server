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

Stage 1 is a busybox shim that sets up dm-verity for `/usr` and pivots into
stage 2. Stage 2 is `bootengine.img`, a 50 MiB squashfs built by
`sys-kernel/bootengine` 0.0.38-r40 from Flatcar's dracut module set, carrying
`/init`, `/etc/initrd-release`, and `/etc/cmdline.d/10-default.conf`. It
conforms to the systemd initrd interface exactly as
`docs/INITRD_INTERFACE.md` prescribes.

`flatcar_production_image.vmlinuz` and `flatcar_production_pxe.vmlinuz` are
both 34,245,760 bytes: one kernel, one embedded initramfs, two names.

The consequence is that `elements/flatcar/flatcar-kernel.bst` has been
importing a self-sufficient kernel all along, and the installer has been
building a second initrd to lay on top of it.

`flatcar_production_pxe_image.cpio.gz` is **not** a candidate for anything. It
is a four-entry cpio whose payload is `usr.squashfs` at 374 MiB: the OS for a
RAM boot, not a driver initrd.

### The boot contract that comes with it

Taking the built-in initramfs means taking Flatcar's boot contract. Its
cmdline, from the shipped `usr/boot/syslinux/root.A.cfg`, is:

```
root=LABEL=ROOT rootflags=subvol=root usr=PARTLABEL=USR-A
```

`veritysetup` in stage 1 and `usr=PARTLABEL=USR-A` mean `/usr` is expected as
a dm-verity-protected A/B partition pair. Stage 2 then runs Flatcar's
provisioning state machine: `ignition-fetch.service`, `ignition-disks.service`,
`ignition-mount.service`, `ignition-files.service`, `ignition-kargs.service`,
`ignition-diskful.target`, `sysroot-boot.service`.

The current DDI has neither a `USR-A` verity pair nor a `ROOT` label, and this
design rejects Ignition. Three ways out, to be settled by the boot proof in
phase 4 rather than asserted here:

1. **Conform to the layout.** Give the installer's `repart.d` a `USR-A`/`USR-B`
   verity pair and a `ROOT`-labelled root, and mask the Ignition units. This is
   the largest change, but it delivers roadmap items 1, 2, and 3 - A/B slots,
   read-only `/usr`, dm-verity - as a consequence of conforming rather than as
   three separate projects, and it is the only option upstream actually tests.
2. **Override the built-in initramfs.** Supply an external initrd, which the
   kernel unpacks over the built-in one. This is today's behavior and keeps us
   owning a generator forever.
3. **Generate with `mkosi-initrd --generic --kernel-version=`.** The systemd
   project's own generator, if the current partition layout must be preserved
   and Flatcar's contract cannot be met.

Option 1 is the recommendation. Options 2 and 3 exist so the boot proof has
somewhere to fall back to.

### Versioning

`project.conf` `release-version` is currently derived from and enforced
against the FSDK junction ref by `.github/scripts/check-release-version.py`.
After the split, the FSDK pin describes only the installer, while the OS
payload's real version is `FLATCAR_VERSION`. The release version needs two
axes recorded and enforced separately. This is an invariant change, not a
string edit, and gets its own ticket ahead of any element work.

## Rejected alternatives

- **Rebuild Flatcar from source under `bst`.** Rejected: Flatcar is a
  portage/SDK cross-build of thousands of ebuilds. The effort is unbounded and
  buys nothing that a pinned, digest-verified binary import does not.
- **Status quo hybrid.** Rejected: it permanently straddles two ABI domains
  and requires the identity fiction in `os-release-flatcar.bst` to function.
- **Boot Flatcar's `/usr` squashfs with dm-verity, as upstream does.**
  Reclassified from "deferred follow-on" to the leading option, because the
  kernel's built-in stage-1 initramfs ships `veritysetup` and expects
  `usr=PARTLABEL=USR-A`. Conforming to that layout is how the embedded
  initramfs boots at all, and it delivers roadmap items 1-3 as a side effect.
  The alternative is overriding the built-in initramfs, which is what the
  repository does today and what this design exists to stop. Settled by the
  phase 4 boot proof.

## Migration phases

Each phase is independently landable and independently verifiable.

1. **Decision and invariants.** Amend hard rule 1 to scope FSDK composition to
   the installer and permit pinned Flatcar binary imports for the OS payload.
   Record this design as an ADR. Split the release-version axes.
2. **Import elements.** `flatcar/flatcar-usr.bst` plus a sysext family for
   `podman`, `containerd`, `docker`. Contract tests assert the update and
   provisioning stack is absent and the module layout is flat.
3. **Parallel DDI.** A project option (`os-base: fsdk | flatcar`) builds both
   payloads so they can be A/B compared on the ghost cluster before anything is
   deleted.
4. **Boot proof.** `just show-me-the-future` installs and boots the Flatcar
   payload in QEMU; the Lima end-to-end test drives the KubeStellar console
   login against it.
5. **Cutover.** `os-stack.bst` switches to the Flatcar base, displaced FSDK
   elements and the `dracut` target-initrd path are deleted, and the `os-base`
   option is removed.
6. **Follow-on.** dm-verity `/usr` and A/B slots; arm64.

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
