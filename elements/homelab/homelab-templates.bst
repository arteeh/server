kind: import
description: |
  The homelab Ignition templates (files/homelab/templates): Butane sources
  and the Ignition 3.6 configs compiled from them (`just
  homelab-templates`, pinned butane) for a kubeadm control plane and node
  and the k0s alternative. Staged by oci/bluefin-server-image.bst as release
  assets in the signed SHA256SUMS, and the kubeadm pair onto the USB
  installer's ESP for its Homelab entries (docs/skills/homelab-profile.md).

sources:
- kind: local
  path: files/homelab/templates
