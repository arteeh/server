kind: import
description: |
  Install the console issue banner (the KubeStellar sysext adds its own lines).

sources:
  - kind: local
    path: files/os/issue.d

config:
  target: /usr/lib/issue.d
