# Bluefin Server

An immutable, Freedesktop-SDK-based Linux server operating system providing native systemd update and extension mechanisms.

## Language

**OS DDI**:
The discoverable disk image (`bluefin-server_<ver>.raw`) carrying the `/usr` erofs partition, its dm-verity hash partition, and an ESP with the disk UKI. Diskless nodes pull it into RAM; on a diskless boot it is also the installer payload.
_Avoid_: base image, OS rootfs, root tarball

**Installer**:
Stock `systemd-sysinstall`, run from either the offline USB installer (`bluefin-server-installer_<ver>.raw`, which boots straight into `systemd-sysinstall.service`) or a diskless-booted node; either way it block-copies `/usr` from the running image onto the target disk and installs the disk UKI. See `ddi-installer.md`.
_Avoid_: live ISO, setup script, shell installer

**Netboot UKI**:
The signed unified kernel image (`bluefin-server-netboot_<ver>.efi`) that pulls the OS DDI into RAM (`rd.systemd.pull`) and boots a tmpfs root with a dm-verity `/usr`. The UEFI HTTP boot / PXE target.
_Avoid_: PXE kernel, vmlinuz/initrd pair, ipxe image

**Disk UKI**:
The signed unified kernel image (`bluefin-server-<ver>.efi`) for installed nodes. It finds the active `/usr` slot by partition label and verity-derived UUIDs, and the persistent xfs root via gpt-auto.
_Avoid_: bootloader entry, kernel package

**Slot**:
One of the two A/B `/usr` (plus usr-verity) partition pairs on an installed disk. `systemd-sysupdate` stages updates into the inactive slot; UKI boot counting rolls back to the previous slot after failed boots.
_Avoid_: partition set, deployment

**Sysext**:
A systemd-sysext extension raw image merged into `/usr` to deliver opt-in server runtimes such as k0s or OpenZFS.
_Avoid_: addon, plugin, package, sidecar

**Transfer**:
A systemd-sysupdate definition mapping a remote release asset to a local target file or partition.
_Avoid_: update manifest, download job, sync rule

**countme**:
Privacy-preserving counting mechanism for measuring adoption and system installations.
_Avoid_: telemetry, tracking, spyware, metrics
