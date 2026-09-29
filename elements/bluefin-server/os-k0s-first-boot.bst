kind: import
description: |
  Install the systemd units from files/os/systemd/system: the first-boot k0s
  sysext activation units, first-start SSH host key generation
  (ssh-host-keygen.service plus its sshd.service and systemd-ssh-generator
  sshd-generated@.service drop-ins), the installer
  source ESP mounts (run-bluefin-boot.mount for netboot,
  run-bluefin-installer.mount for the USB installer), and the
  systemd-sysinstall.service drop-in the USB installer boots into.

sources:
  - kind: local
    path: files/os/systemd/system

config:
  target: /usr/lib/systemd/system
