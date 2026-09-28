kind: import
description: |
  Public kernel module signing certificate, staged at /keys for
  freedesktop-sdk.bst:components/linux.bst through the junction override in
  elements/freedesktop-sdk.bst. FSDK's kernel config trusts it
  (SYSTEM_TRUSTED_KEYS) and enables lockdown when it is present.
  Only the certificate is staged; the private key stays in
  files/boot-keys/linux-module-cert.key and is used by kernel-modules.bst.

config:
  target: /keys

sources:
- kind: local
  path: files/boot-keys/modules
