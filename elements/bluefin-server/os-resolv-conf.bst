kind: import
description: |
  Install the tmpfiles.d rule that recreates Flatcar's /etc/resolv.conf
  symlink to systemd-resolved's resolv.conf. The Flatcar /usr payload does
  not carry it (Flatcar ships the symlink in the image /etc, which this DDI
  does not import), and kubelet requires /etc/resolv.conf to create any pod
  sandbox.

sources:
  - kind: local
    path: files/os/tmpfiles.d

config:
  target: /usr/lib/tmpfiles.d
