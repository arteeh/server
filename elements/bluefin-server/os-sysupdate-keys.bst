kind: import
description: |
  OpenPGP keyring that systemd-importd (diskless rd.systemd.pull) and
  systemd-sysupdate verify SHA256SUMS.gpg against, installed as
  /etc/systemd/import-pubring.pgp: systemd reads that path before the
  vendor keyring FSDK ships in /usr/lib/systemd.

  It comes from files/boot-keys/import-pubring.pgp, the public half of the
  key that signs this build's SHA256SUMS (bluefin-server-image.bst): a dev
  key from `just gen-dev-keys`, or on release builds the key in
  files/os/sysupdate-keys/import-pubring.gpg (CI copies it in).

sources:
  - kind: local
    path: files/boot-keys/import-pubring.pgp

config:
  target: /etc/systemd
