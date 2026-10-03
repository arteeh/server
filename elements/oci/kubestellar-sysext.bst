kind: manual
description: |
  Opt-in homelab add-on systemd-sysext: the KubeStellar Console (deployed
  once its GitHub OAuth app is configured, behind the homelab Gateway) and,
  with HOMELAB_KUBESTELLAR_FULL=yes, full KubeStellar (KubeFlex, its
  Postgres, the KubeStellar controllers' PostCreateHooks), under
  /usr/share/bluefin/homelab/addons.d/. Needs the homelab sysext, whose
  applier applies it on the control plane of a kubeadm or k0s cluster.

  Output: kubestellar_<image-version>.raw, .raw.zst, and SHA256SUMS. Locked to
  one image version like the homelab sysext and updated in lock-step with
  the OS through the `kubestellar` sysupdate feature.

(@):
- include/image.yml
- include/sysext.yml

build-depends:
- base/base-stack.bst
- freedesktop-sdk.bst:components/erofs-utils.bst
- freedesktop-sdk.bst:components/zstd.bst

sources:
- kind: local
  path: files/homelab/addon-sysexts
  directory: sysext-src
- kind: local
  path: files/homelab/addons/30-kubestellar-console
  directory: addons-src/30-kubestellar-console
- kind: local
  path: files/homelab/addons/31-kubestellar-full
  directory: addons-src/31-kubestellar-full

variables:
  strip-binaries: ""
  sysext-name: "kubestellar"
  sysext-image: "kubestellar_%{image-version}"
  sysext-release: "kubestellar_%{image-version}"
  sysext-version: "%{image-version}"
  # Manifests only.
  sysext-architecture: ""

config:
  install-commands:
  - |
    set -euo pipefail
    addons="sysext%{datadir}/bluefin/homelab/addons.d"
    mkdir -p "${addons}"
    cp -a addons-src/. "${addons}/"
    for d in "${addons}"/*/; do
      [ -f "${d}addon" ] || { echo "ERROR: ${d} has no addon index file" >&2; exit 1; }
    done
    # Every registry reference carries a digest.
    if grep -rnE '^[[:space:]-]*image: "?[^[:space:]]*[/:]' "${addons}" | grep -v '@sha256:[0-9a-f]\{64\}'; then
      echo "ERROR: image reference not pinned by digest" >&2; exit 1
    fi
    if find sysext -name '*.pem' -o -name '*.key' | grep -q .; then
      echo "ERROR: key material in a public sysext" >&2; exit 1
    fi

  - "%{sysext-pack}"
