kind: manual
description: |
  Flatcar's containerd system extension, shipped as a second sysext alongside
  oci/kubernetes-sysext.bst.

  Output: /containerd-flatcar.raw — the upstream squashfs image, imported
  verbatim under its upstream name.

  The name is load-bearing and must not be shortened. systemd-sysext resolves an
  image's metadata by stem: an extension merged as <name>.raw is required to
  carry /usr/lib/extension-release.d/extension-release.<name>. This image ships
  extension-release.containerd-flatcar, so renaming it to containerd.raw makes
  systemd-sysext look for extension-release.containerd, fail to find it, and
  refuse the extension — silently, at boot, long after the build went green.
  tests/unit/test_sysupdate_transfers.py encodes the same invariant for the
  Kubernetes sysext, and tests/unit/test_seeded_sysext_names.py now covers the
  installer-seeded path this element feeds.

  Why import rather than build: FSDK 26.08 ships no containerd component at all
  (see docs/superpowers/specs/2026-09-19-flatcar-runtime-parity.md, which records
  `no elements/components/containerd.bst` in the pinned junction), so there is
  nothing to compose from. Flatcar publishes containerd as a systemd-sysext, the
  same delivery mechanism this repository already uses for Kubernetes, and the
  image is self-contained:

    /usr/bin/containerd, containerd-shim-runc-v2, ctr, runc
    /usr/lib/systemd/system/containerd.service
    /usr/lib/systemd/system/multi-user.target.wants/containerd.service
    /usr/lib/systemd/system/multi-user.target.d/10-containerd-service.conf
    /usr/lib/extension-release.d/extension-release.containerd-flatcar
    /usr/share/containerd/config.toml, config-cgroupfs.toml
    /usr/share/SLSA/*.json.zst                (containerd 2.1.5, runc 1.3.3)

  It carries its own `multi-user.target.wants` symlink, so containerd.service is
  enabled by the merge itself — no preset is needed on our side. That is what
  satisfies `Requires=containerd.service` in
  files/os/systemd/system/kubeadm-init.service.

  The merge is gated on os-release matching. extension-release.containerd-flatcar
  declares ID=flatcar and VERSION_ID=4593.2.5; elements/bluefin-server/os-release-flatcar.bst
  writes ID=flatcar and VERSION_ID=%{flatcar-version}, both sourced from
  include/flatcar.yml. Bumping flatcar-version without re-pinning the ref below
  makes systemd-sysext refuse the extension rather than merge a mismatched one.

  elements/flatcar/container-runtime-reference-sysexts.bst also imports this file.
  That element is the parity oracle and additionally pulls podman and docker,
  which this image does not ship; no shipped target depends on it. This element
  exists so the shipped path imports exactly one runtime and nothing else.

(@):
  - include/flatcar.yml

build-depends:
  - base/base-stack.bst

variables:
  strip-binaries: ""

sources:
  - kind: remote
    url: flatcar:stable/amd64-usr/%{flatcar-version}/rootfs-included-sysexts/containerd-flatcar.raw
    filename: containerd-flatcar.raw
    ref: 78e38344ac490004b9fa4c7da38bbfcffc393146aa990379aff7b5c09589f809

config:
  install-commands:
    - |
      set -euo pipefail
      install -D -m 0644 containerd-flatcar.raw \
        "%{install-root}/containerd-flatcar.raw"
