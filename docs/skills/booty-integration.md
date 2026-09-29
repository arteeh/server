---
name: booty-integration
description: How Booty serves Bluefin Server releases to nodes. Load when working on HTTP boot, iPXE chainloading, per-node Ignition, or kubeadm worker provisioning.
metadata:
  type: reference
  status: stable
  last_updated: "2026-09-29"
---
# Booty Integration

[Booty](https://github.com/jeefy/booty) is the network boot server for Bluefin
Server at scale. It syncs a release and answers boot requests with the right
artifacts per node.

## What Booty serves

A release `v<ver>` (from GitHub Releases or the OCI artifact) contains the
netboot UKI, the OS DDI `bluefin-server_<ver>.raw`, `SHA256SUMS(.gpg)`, and a
netboot ESP image. Booty syncs these and serves them over HTTP.

## Boot paths

| Firmware | Path |
|---|---|
| UEFI HTTP Boot | Firmware fetches `http://<booty>/bluefin/<mac>/bluefin-server-netboot.efi`; Secure Boot on. |
| iPXE chainload | Legacy or custom NICs chainload iPXE, which then HTTP-boots the UKI; Secure Boot off. |
| Legacy BIOS | Not supported for diskless; use the USB installer or disk install instead. |

## Per-node configuration

Booty writes a `bluefin-node.ign` per MAC address next to the UKI. The initrd
picks it up as the `ignition.config.url` system credential. Fields include
hostname, SSH keys, state disk, extensions, and k0s token.

## Install to disk

Setting `doInstall` in the node's Booty config boots it into
`booty-install.service`, which runs `systemd-sysinstall` against the local
disk. Without Booty, write `bluefin-server-netboot_<ver>.esp.raw` to a USB
stick and place an `import.pull.cred` credential in `/loader/credentials/`
specifying the URL to pull.

## kubeadm workers

Nodes that should join a kubeadm cluster get the kubeadm sysext via their
`bluefin-node.ign` (extension list) plus the cluster token. The sysext carries
kubelet and containerd; the node joins on first boot.

## Read more

- [Booty README](https://github.com/jeefy/booty) — flags, config file layout,
  and the `feat/bluefin-http-boot` branch status.
- [ddi-installer.md](ddi-installer.md) — boot flow, DDI layout, and sysinstall
  contract.
- [kubeadm-sysext.md](kubeadm-sysext.md) — worker sysext build and runtime
  contract.

## See also

- [index.md](index.md) — lazy-load routing manifest.
- [CONTEXT.md](../../CONTEXT.md) — canonical project domain glossary.
