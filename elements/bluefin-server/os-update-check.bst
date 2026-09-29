kind: import
description: |
  Update helpers in /usr/libexec (units in files/os/systemd/system, enabled by
  80-bluefin-updates.preset):
  - bluefin-diskless-update-check, run by bluefin-diskless-update-check.timer
    on diskless boots only: fetches the signed SHA256SUMS from the directory
    the node booted from, and when it lists a newer bluefin-server_<ver>.raw
    than the running IMAGE_VERSION and the boot origin is not pinned to a
    versioned file, touches /run/reboot-required for kured or the operator.
    It never reboots.
  - bluefin-boot-deadline, run by bluefin-boot-deadline.timer on boot-counted
    boots only: reboots (or flags kured on a Kubernetes node) when the boot has
    not reached boot-complete.target by the deadline, so systemd-boot falls
    back to the previous UKI.
  - bluefin-update-pending: `systemd-sysupdate pending`, minus a version whose
    UKI already used up its boot tries; gates the kured flag and the nightly
    reboot so a rolled-back node does not reboot into it again.
  Runtime tools: bash, coreutils, curl, gpgv, bootctl, systemd-analyze
  (os-base.bst) and bluefin-boot-origin (boot-origin.bst).

sources:
- kind: local
  path: files/os/update-check
