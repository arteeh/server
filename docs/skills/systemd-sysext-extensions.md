---
name: systemd-sysext-extensions
description: Extensibility via systemd-sysext and systemd-confext for Bluefin Server. Use when adding, debugging, or documenting system extensions.
metadata:
  type: reference
  status: stable
  last_updated: "2026-09-30"
  context7-sources:
    - /systemd/systemd
---
# Extensibility via systemd-sysext

Bluefin Server's base OS includes bash for login and bring-up, while heavy
developer and debug tools live in sysexts or system containers. For debugging,
monitoring, or runtime modifications, use systemd-sysext to overlay package
bundles into `/usr` and `/opt`, or systemd-confext to overlay files into `/etc`.

## Canonical scope

This file is the canonical home for extension-loading behavior, compatibility
checks, and runtime management. Future roadmap items for deeper integration
with the provisioning flow remain in [architecture-roadmap.md](architecture-roadmap.md).

## Where extensions live

System extensions are searched in:

- `/etc/extensions/`
- `/run/extensions/`
- `/var/lib/extensions/` (the primary location for persisted extension images)

Configuration extensions (confext) are searched in:

- `/run/confexts/`
- `/var/lib/confexts/`
- `/usr/lib/confexts/`
- `/usr/local/lib/confexts/`

Placing an empty directory named like the extension (without `.raw`) under
`/etc/extensions/` masks an extension of the same name in a lower-precedence
directory.

## Extension identity and version matching

The base OS `/usr/lib/os-release` identifies as `ID=bluefin-server` with
`VERSION_ID=<image-version>` (`elements/bluefin-server/os-release.bst`). A
sysext merges when its `extension-release` metadata matches the host `ID=` (or
uses `ID=_any`) and, when it pins `VERSION_ID=`, the host version.

The first-party extensions make opposite choices:

- **k0s** (`files/k0s/sysext/extension-release.k0s`) uses `ID=_any` and does
  not pin the image version, so it merges on any host image.
- **NVIDIA Container Toolkit** (`oci/nvidia-container-toolkit-sysext.bst`,
  version in `include/nvidia-container-toolkit.yml`) follows k0s: `ID=_any`,
  its own version, merged as `nvidia-container-toolkit.raw`. It is CDI only:
  `nvidia-ctk`, `nvidia-cdi-hook` and `nvidia-cdi-refresh.{service,path}`,
  which write `/var/run/cdi/nvidia.yaml` at boot for containerd (CDI is on by
  default in containerd 2.x). No `nvidia-container-runtime`, OCI hook or
  `nvidia` runtime class. The refresh is ordered after the driver sysext's
  units without requiring them, and skips on nodes without an NVIDIA GPU.
- **OpenZFS and KubeStellar** are version-locked to the image: their
  extension-release file is named after the versioned image file
  (`extension-release.zfs_<image-version>`,
  `extension-release.kubestellar_<image-version>`) with `ID=bluefin-server`
  and `VERSION_ID=<image-version>`, because the ZFS kernel modules only load
  on the exact kernel they were built against (and the KubeStellar stack is
  validated against one image). Several versions sit side by side in
  `/var/lib/extensions` as `zfs_<ver>.raw` / `kubestellar_<ver>.raw`;
  systemd-sysext merges only the one matching the booted image, so an A/B
  rollback keeps its ZFS. Installed nodes receive them in lock-step with OS
  updates through the optional `zfs` / `kubestellar` sysupdate features
  (see `systemd-sysupdate-verification.md`); diskless nodes get them from
  Ignition, which writes `/etc/extensions/<name>_<ver>.raw` with a sha256
  verification hash.

The NVIDIA driver sysexts (`nvidia-open-<branch>_<image-version>.raw`, open
kernel modules only; flavours and pins in `include/nvidia.yml`) are
version-locked the same way. They are built and exported only by
`just build-nvidia-sysext` / `just export-nvidia-sysext` and checked in QEMU
by `just dogfood-nvidia`; they are not yet part of the release image set.
Their units skip themselves on a node without an NVIDIA GPU, and
`nvidia-flavour-guard.service` fails when two flavours are merged.

**The NVIDIA and OpenZFS sysexts are mutually exclusive.** Both run `depmod`
over the base image's modules plus their own and ship the resulting
`/usr/lib/modules/<kver>/modules.*` index, so whichever image systemd-sysext
overlays last hides the other's index and `modprobe` can no longer find the
other's modules. `nvidia-flavour-guard.service` refuses the merge (and with it
`nvidia-load.service`) when a `zfs_*` extension is merged alongside, so the
conflict fails with a clear message instead of a bare `Module nvidia not
found`. A node that needs both has to wait for a single sysext that indexes
both module sets.

The GPU-present path (`nvidia-load.service`, `nvidia-device-nodes.service`,
`nvidia-persistenced.service`) is not exercised by `just dogfood-nvidia`, which
runs on a QEMU guest with no NVIDIA GPU and asserts only that those units skip
themselves. It is verified on real hardware during the GPU rollout phase.

Third-party extensions built for another distribution (for example the Flatcar
System Extension Bakery) only merge with `systemd-sysext merge --force`, and
only if they are pure userspace.

## Adding an extension

The k0s sysext is the built-in example; a compatible extension layers the same
way.

```bash
# Download an extension image to the persistence directory
wget <extension-url> -O /var/lib/extensions/myext.raw

# Merge it into the running system
systemd-sysext merge

# Verify it is active
systemd-sysext status
```

To pick up newly dropped extension images automatically, refresh instead of
manually merging:

```bash
systemd-sysext refresh
```

The `systemd-sysext.service` unit performs a refresh at boot, so extensions in
`/var/lib/extensions/` become available without manual intervention. One
caveat: the refresh happens after PID 1 has built the boot transaction, so
`[Install]` symlinks shipped inside a sysext (for example `zfs.target` in
`multi-user.target.wants`) are not part of it. The enabled oneshot
`bluefin-sysext-activate.service` runs after `systemd-sysext.service` and
re-requests `multi-user.target`, which adds jobs for the now-visible wants;
that is how `zfs.target` comes up at boot when the ZFS sysext is merged.

## Removing an extension

```bash
rm /var/lib/extensions/myext.raw
systemd-sysext refresh
```

## Key constraints

- Keep extensions as simple read-only bundles. Do not ship a `/usr/lib/os-release`
  file inside an extension; it would override the host OS version metadata.
- The extension image format is the same one `systemd-repart` and `systemd-sysext`
  accept: a GPT/EROFS/directory tree that contains `/usr/` and/or `/opt/`.
- For files that belong under `/etc/`, ship a **confext** and place it under
  `/var/lib/confexts/`, then use `systemd-confext merge`/`refresh`.

## Debugging

```bash
# List discovered extensions
systemd-sysext list

# Show merge state and any compatibility errors
systemd-sysext status

# Force a merge ignoring version mismatches (debugging only)
systemd-sysext merge --force
```

## See also

- [k0s-sysext.md](k0s-sysext.md) for the built-in Kubernetes extension
- [CONTEXT.md](../../CONTEXT.md) — canonical project domain glossary (Sysext definition).
- `systemd-sysext(8)`, `systemd-confext(8)`
