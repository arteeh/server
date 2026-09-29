kind: import
description: |
  Install the system-container helper into the target OS image. The helper
  wraps machinectl to start, stop, enter, and reset systemd-nspawn machines.

sources:
  - kind: local
    path: files/bin/system-container

config:
  target: /usr/bin
