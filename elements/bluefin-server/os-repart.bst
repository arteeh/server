kind: import
description: |
  Disk layout of an installed Bluefin Server (/usr/lib/repart.d): ESP, usr
  slot A + verity copied from the running image, empty slot B + verity for
  systemd-sysupdate, and a persistent xfs root. Labels use %A (IMAGE_VERSION).

  systemd-sysinstall writes the ESP and slot A and defers the rest; on the
  first boot of the installed disk the initrd's systemd-repart (which reads
  /sysusr/usr/lib/repart.d) creates slot B and root. bluefin-server-boot.bst
  exports a copy with slot A's UUIDs pinned to the usrhash derivation for
  `systemd-sysinstall --definitions=`.

sources:
- kind: local
  path: files/os/repart.d

config:
  target: /usr/lib/repart.d
