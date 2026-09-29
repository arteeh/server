kind: import
description: |
  /usr/libexec/bluefin-boot-origin: prints the URL a network-booted node was
  booted from (UEFI HTTP boot URL, the explicit rd.systemd.pull= source, or
  the import.pull credential). One helper for both consumers:
  bluefin-ignition-credentials in the initrd (initrd-ignition-stack.bst) and
  bluefin-diskless-update-check in the booted OS (os-update-check.bst).

sources:
- kind: local
  path: files/boot-origin
