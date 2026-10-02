kind: manual
description: |
  bluefin-cluster: the homelab's multi-node join service and client
  (files/homelab/cluster, Go). One static binary: `prepare` (control plane:
  unique hostname, mDNS API endpoint in kubeadm's init config), `serve`
  (control plane: DNS-SD advertisement and the passphrase-authenticated
  token hand-out), `join` (node) and `passphrase`.

  Offline Go build with FSDK Go: every dependency is vendored in the
  repository (files/homelab/cluster/vendor: filippo.io/cpace,
  github.com/gtank/ristretto255, golang.org/x/crypto; BSD-3-Clause), so the
  build needs no network. No cgo.

  No runtime `depends:`: oci/homelab-sysext.bst stages this artifact at a
  private location and ships exactly the binary and the licences.

build-depends:
- base/base-stack.bst
- freedesktop-sdk.bst:components/go.bst

sources:
- kind: local
  path: files/homelab/cluster

environment:
  GOROOT: "%{libdir}/go"
  GOTOOLCHAIN: local
  GOPROXY: "off"
  GOFLAGS: -mod=vendor -trimpath -buildvcs=false
  CGO_ENABLED: "0"

variables:
  # -s -w below already drops the symbol tables.
  strip-binaries: ""

config:
  build-commands:
  - |
    set -eu
    export GOPATH="${PWD}/.gopath" GOCACHE="${PWD}/.gocache"
    go vet ./...
    go test ./...
    go build -ldflags "-s -w" -o bluefin-cluster ./cmd/bluefin-cluster

  install-commands:
  - |
    set -eu
    install -D -m 0755 bluefin-cluster "%{install-root}%{bindir}/bluefin-cluster"
    lic="%{install-root}%{datadir}/licenses/bluefin-cluster"
    install -D -m 0644 vendor/filippo.io/cpace/LICENSE "${lic}/filippo.io-cpace.LICENSE"
    install -D -m 0644 vendor/github.com/gtank/ristretto255/LICENSE "${lic}/gtank-ristretto255.LICENSE"
    install -D -m 0644 vendor/golang.org/x/crypto/LICENSE "${lic}/golang-x-crypto.LICENSE"
    install -D -m 0644 internal/passphrase/WORDLIST-LICENSE "${lic}/eff-wordlist.LICENSE"
