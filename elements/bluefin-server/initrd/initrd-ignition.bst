kind: import
description: |
  Opt-in Ignition stages for the systemd-native initrd (no dracut). Units are
  adapted from coreos/ignition dracut/30ignition and statically linked into
  initrd.target via initrd.target.requires/ignition-complete.target; every
  unit is conditioned on the ignition.config / ignition.config.url system
  credentials, so a node booted without them runs none of it.

sources:
- kind: local
  path: files/initrd-ignition
