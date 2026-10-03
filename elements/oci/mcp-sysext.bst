kind: manual
description: |
  Opt-in homelab add-on systemd-sysext: the Kubernetes MCP server
  (containers/kubernetes-mcp-server), read-only unless HOMELAB_MCP_READ_WRITE=yes,
  every request authenticated with a Kubernetes bearer token (the generated
  mcp-client token), and its HTTPRoute, under
  /usr/share/bluefin/homelab/addons.d/20-mcp/. Needs the homelab sysext,
  whose applier applies it on the control plane.

  Output: mcp_<image-version>.raw, .raw.zst, and SHA256SUMS. Locked to
  one image version like the homelab sysext and updated in lock-step with
  the OS through the `mcp` sysupdate feature.

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
  path: files/homelab/addons/20-mcp
  directory: addons-src/20-mcp

variables:
  strip-binaries: ""
  sysext-name: "mcp"
  sysext-image: "mcp_%{image-version}"
  sysext-release: "mcp_%{image-version}"
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
