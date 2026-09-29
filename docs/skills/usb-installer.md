---
name: usb-installer
description: The offline USB installer bluefin-server-installer_<ver>.raw. Load when working on the installer image, its systemd-sysinstall drop-in, unattended installs via systemd.unit-dropin credentials, or install-time provisioning from the ESP.
metadata:
  type: reference
  status: stable
  last_updated: "2026-09-29"
  context7-sources:
    - /systemd/systemd
---
# Offline USB Installer

`bluefin-server-installer_<ver>.raw` is the offline USB installer in the
release set: the same usr and usr-verity images as the OS DDI (labelled
`bluefin-installer-usr` / `bluefin-installer-usr-verity`) plus an ESP with
signed systemd-boot, the installer UKI, the Secure Boot key enrollment
payloads, and the disk UKI + install-time `repart.d` under `bluefin/`. Write
it to a USB stick to install without a network:

```bash
sudo dd if=bluefin-server-installer_<ver>.raw of=/dev/<usb> bs=4M conv=fsync status=progress
```

## Boot flow

```text
firmware -> systemd-boot -> bluefin-server-installer_<ver>.efi
  -> /usr from the stick's bluefin-installer-usr partition (dm-verity, usrhash=)
  -> tmpfs root, systemd.unit=system-install.target
  -> systemd-sysinstall.service on the monitor (/dev/console = tty0)
```

The installer UKI finds its /usr by partition label, not by the
usrhash-derived UUIDs. Those UUIDs belong to installed usr slots, so an
existing Bluefin install (including the disk being overwritten) is never
opened as the installer's /usr, and an installed node booted with the stick
still plugged in never opens the stick's usr. The installer is offline: its
initrd masks `systemd-networkd-wait-online`, as the disk UKI already does.

`run-bluefin-installer.mount` mounts the stick's ESP (`bluefin-installer`) at
`/run/bluefin/installer` (with `fmask=0133,dmask=0022`, so systemd-repart does
not warn about executable definition files). The
`systemd-sysinstall.service.d/10-bluefin-installer.conf` drop-in passes
`--definitions=/run/bluefin/installer/bluefin/repart.d` and
`--kernel=${BLUEFIN_INSTALL_KERNEL}` (the disk UKI, named by the installer
UKI's `systemd.setenv=`). The disk UKI sits outside `EFI/Linux` on the stick
so systemd-boot never offers it there. sysinstall prompts for the target
disk, erasing it, and confirmation, then reboots; remove the stick when it
does.

The installed disk is identical to one a diskless node installs: stock
`systemd-sysinstall` with the layout from `files/os/repart.d/` (see
[ddi-installer.md](ddi-installer.md), "Installing to disk").

## Unattended installs

`systemd-sysinstall` is interactive on `/dev/console`. To make an install
unattended, pass a `systemd.unit-dropin.systemd-sysinstall.service` system
credential (SMBIOS type 11, QEMU fw_cfg, or a `.cred` file in
`/loader/credentials/` on the stick's ESP). It lands as `50-credential.conf`,
after the image's `10-bluefin-installer.conf`, and re-runs that drop-in's
`ExecStart=` with the target disk and `--erase=yes --confirm=no
--variables=yes` appended, plus `StandardInput=null` so any leftover prompt
fails instead of hanging. `scripts/dogfood-installer.sh` drives exactly this
path in QEMU and is the reference for the drop-in contents.

## First-boot prompt

Root ships locked as `!unprovisioned`, which `systemd-firstboot` reads as
"root not configured yet"; upstream's `--prompt-root-password` would block
the installer's console on a password prompt. The
`systemd-firstboot.service.d/10-bluefin-no-root-prompt.conf` drop-in removes
only that prompt: the `passwd.hashed-password.root` /
`passwd.plaintext-password.root` credentials still apply, and without one
root stays locked. See [tpm2-credential-sealing.md](tpm2-credential-sealing.md).

## Credentials and the ESP

The installer needs no login: `systemd-sysinstall` runs on the console. It
does not carry the installer's credentials over to the installed disk, so
provision the installed node by placing encrypted `.cred` files in
`/loader/credentials/` on the installed disk's ESP before its first boot
(details in [tpm2-credential-sealing.md](tpm2-credential-sealing.md)).

## Secure Boot

The stick's systemd-boot and UKIs are signed with the project DB key. On bare
metal put the firmware into Setup Mode and pick the enrollment entry in the
systemd-boot menu (`secure-boot-enroll if-safe` only auto-enrolls in VMs), or
turn Secure Boot off.

## See also

- [ddi-installer.md](ddi-installer.md) — boot, install, and update architecture.
- [ddi-installer-build.md](ddi-installer-build.md) — build and dogfood
  (`just dogfood-installer`).
- [tpm2-credential-sealing.md](tpm2-credential-sealing.md) — first-boot
  credentials and ESP credential files.
- [secure-boot-keys.md](secure-boot-keys.md) — the keys that sign the stick.
- [CONTEXT.md](../../CONTEXT.md) — canonical project domain glossary (Installer).
