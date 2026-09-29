---
name: ddi-installer-build
description: Build, export, and dogfood the Bluefin Server image set (OS DDI, signed UKIs, netboot ESP) and the opt-in sysexts.
metadata:
  type: how-to
  status: stable
  last_updated: "2026-09-28"
  context7-sources:
    - /systemd/systemd
    - /apache/buildstream
---
# Image Build and Dogfood

Use this skill when you need to build the release image set, export it, boot it
in QEMU, or run the end-to-end install/update/rollback test.

## Build targets

The repo exposes the main build entrypoints through `just`. BuildStream runs
inside the FSDK `bst2` container (`just bst`); it is not installed locally.

```bash
just validate          # version invariants + resolve the shipped element graphs
just test-unit         # pytest + bats
just gen-dev-keys      # throwaway Secure Boot + module keys in files/boot-keys/
just set-version V     # set image-version in include/image.yml (<=17 chars,
                       # increasing under strverscmp)
just build-image       # build oci/bluefin-server-image.bst
just export-image      # export the release set to dist/diskless/
just build-sysext      # build oci/k0s-sysext.bst
just export-sysext     # export k0s sysext + SHA256SUMS to dist/sysext/
just build-zfs-sysext  # build oci/zfs-sysext.bst
just export-zfs-sysext # export OpenZFS sysext + SHA256SUMS to dist/sysext/
just version / just tags  # FSDK-derived point release and tag set
```

`just export-image` writes one directory per image version containing the OS
DDI, the sysupdate usr/usr-verity sources, both UKIs, the netboot ESP image,
the k0s/KubeStellar/OpenZFS sysext assets, the `efi-keys/` enrollment
payloads, and a `SHA256SUMS` over all of it with its detached signature
`SHA256SUMS.gpg` (signed in-element by `oci/bluefin-server-image.bst`). See
[ddi-installer.md](ddi-installer.md) for what each artifact is.

To publish the set as an OCI artifact (one layer per file, tags `<version>`
and `latest`, artifact type
`application/vnd.projectbluefin.server.release.v1`):

```bash
just publish-oci ghcr.io/<owner>/bluefin-server                 # podman login first
just publish-oci <registry-host>:30500/bluefin-server dist/diskless 1  # plain HTTP
```

## Keys

Every image build signs: the UKIs and systemd-boot with DB, kernel modules
with the module signing certificate, and the release `SHA256SUMS` with the
image signing key. `build-image` (and `validate`) depends on `gen-dev-keys`,
which generates throwaway keys in `files/boot-keys/` (gitignored) on first
run: PK/KEK/DB, the module certificate, and the `sysupdate-signing.asc` /
`import-pubring.pgp` pair. Keys are kept unless `--force` is given. CI builds
on `main` unpack the `BOOT_KEYS_TARBALL` secret, write `SYSUPDATE_SIGNING_KEY`
to `files/boot-keys/sysupdate-signing.asc`, and copy the committed release
keyring `files/os/sysupdate-keys/import-pubring.gpg` to
`files/boot-keys/import-pubring.pgp`; pull requests get throwaway keys and
their images are never published.

## Dogfood: boot it in QEMU

All dogfood paths boot with Secure Boot firmware (OVMF secboot). The firmware
starts in setup mode; systemd-boot enrolls the dev keys from the ESP
(`secure-boot-enroll if-safe`) and reboots, so every later boot is verified.

```bash
just dogfood                     # interactive diskless boot of dist/diskless/
just dogfood-check               # headless: pass when the in-guest probe
                                 # reports no failed units
just dogfood-install             # diskless boot, systemd-sysinstall to a blank
                                 # disk, then boot the installed disk
just dogfood-install NEXT=<dir>  # ...then sysupdate A->B to NEXT and boot it
```

`scripts/dogfood-diskless.sh <dir> [--check]` boots the way a PXE/HTTP-booted
node would: signed systemd-boot -> signed netboot UKI -> initrd pulls
`bluefin-server_<ver>.raw` over HTTP into RAM -> dm-verity /usr, tmpfs root.
Useful environment variables:

- `DOGFOOD_IGNITION=<file>` — pass an Ignition config as the `ignition.config`
  credential (see `tests/fixtures/ignition/var-on-disk.ign`).
- `DOGFOOD_CREDS=<dir>` — pass every file in `<dir>` as a system credential
  named after the file (SMBIOS type 11).
- `DOGFOOD_STATE_DISK=<file>` — attach a persistent second disk (`/dev/vdb`).
- `DOGFOOD_VARS=<file>` — persistent UEFI variable store (keeps enrolled keys
  across runs).
- `DOGFOOD_BOOT=disk` — boot `DOGFOOD_STATE_DISK` instead of the netboot ESP.
- `DOGFOOD_BOOT=http` — UEFI HTTP boot the netboot UKI; the initrd derives the
  `/usr` image URL from the boot URL. Enrolls the Secure Boot keys from the
  netboot ESP once per variable store first.
- `DOGFOOD_BOOT_URL=<url>` — HTTP boot from another server (e.g. Booty)
  instead of the built-in one.
- `DOGFOOD_NODE_IGN=<file>` — serve it as `bluefin-node.ign` next to the UKI
  (picked up by HTTP-booted nodes with no Ignition credential).
- `DOGFOOD_SERVE_EXTRA=<dir>` — also serve the files in `<dir>`.
- `DOGFOOD_TAMPER=raw|sums` — serve a corrupted DDI or a re-hashed, unsigned
  `SHA256SUMS`; the boot must fail, proving the signature check.
- `DOGFOOD_MEM=<MiB>` — guest RAM (default 4096); below the diskless minimum
  the boot must fail with the RAM message (see `diskless-troubleshooting.md`).
- `DOGFOOD_EXTRA_PROBE=<file>` — shell snippet appended to the in-guest probe.

`scripts/dogfood-install.sh <dir> [<next-dir> [<broken-dir>]]` is the full
end-to-end check: install from a diskless boot, boot the installed disk,
`systemd-sysupdate` A->B to `<next-dir>` with the default `Verify=yes` against
the signed manifest (with the `zfs` feature enabled, so the ZFS sysext follows
the OS in lock-step), and with `<broken-dir>` corrupt the updated slot and
confirm boot counting rolls the node back to `<next-dir>` on its own, with the
matching ZFS sysext still merged. CI runs the first two stages
(`dogfood-diskless.sh --check`, `dogfood-install.sh dist/diskless`) as the
`boot-test` job in `.github/workflows/build.yml` on every pull request and
push to main.

## Local builds with a remote cache

If you must build locally with the cluster cache, point BuildStream at your
cache tunnel host (`<build-cache-host>`) in `~/.config/buildstream.conf`:

```yaml
projects:
  bluefin-server:
    artifacts:
      override-project-caches: false
      servers:
      - url: grpc://127.0.0.1:8980
        push: true
```

## Release automation

`.github/workflows/build.yml` runs `just validate`, exports the image set
(already carrying its signed `SHA256SUMS(.gpg)`), runs the QEMU boot test, and
on `main` publishes `dist/diskless/` as-is: an immutable GitHub Release tagged
`v<image-version>` plus an ORAS OCI artifact at
`ghcr.io/<owner>/bluefin-server:<ver>,latest`. One version is published
exactly once; creating an existing tag fails rather than overwriting assets
nodes may already trust.

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "Skip `gen-dev-keys`, the build has defaults." | Signing needs real key material in `files/boot-keys/`; the recipe generates throwaway keys so local builds boot under Secure Boot. |
| "Test the UKI with `-kernel`/`-initrd`." | That bypasses the signed boot chain. The dogfood scripts boot the netboot ESP or installed disk through OVMF the way firmware does. |
| "Reboot loops mean the boot hung." | With Secure Boot in setup mode the first boot enrolls keys and reboots; that is expected once per fresh variable store. |
| "A failed update needs manual recovery." | Boot counting handles it: three failed boots of the new UKI and systemd-boot falls back to the previous image. `dogfood-install.sh <dir> <next> <broken>` proves it. |
| "`chmod 4755` in install-commands makes a file setuid in the image." | No. BuildStream artifacts keep one executable bit per file, so every staged file is 0644/0755. FSDK components declare their special modes as initial scripts, and `oci/bluefin-server-usr.bst` runs them (`os-initial-scripts.bst`) while assembling /sysroot; special modes must be set in the `script` element that writes the image. |

## Red flags

- A boot cmdline with a hardcoded device path.
- An initrd change that drops `loop`, `dm-verity`, `erofs`, or `virtio_net`
  (the build fails the check in `bluefin-server-boot.bst`).
- A new release asset that is not added to `SHA256SUMS` in
  `oci/bluefin-server-image.bst`.
- Keys committed anywhere outside the gitignored `files/boot-keys/`.

## Verification

- [ ] `just validate` resolves the BuildStream graph without errors.
- [ ] `just dogfood-check` passes.
- [ ] `just dogfood-install NEXT=<dir>` passes when changing install or update logic.
- [ ] Exported `dist/diskless/` contains the OS DDI, both UKIs, the netboot
      ESP, the sysext assets, `efi-keys/`, `SHA256SUMS`, and `SHA256SUMS.gpg`.

## See also

- [ddi-installer.md](ddi-installer.md) — boot, install, and update architecture.
- [CONTEXT.md](../../CONTEXT.md) — canonical project domain glossary (OS DDI, Installer, Netboot UKI, Disk UKI).
