kind: manual
description: |
  Upstream release binaries for a kubeadm worker node, each pinned by
  sha256 (published alongside the release asset): kubelet, kubeadm and
  kubectl from dl.k8s.io, crictl (cri-tools), the containerd static build
  (containerd, containerd-shim-runc-v2, ctr), the runc static build, and
  the full CNI reference plugin set. Versions come from include/kubeadm.yml.

  Layout: binaries in /usr/bin, CNI plugins in /usr/libexec/cni. Nothing
  goes under /opt: /opt/cni/bin stays a writable host directory that the
  cluster's CNI (Cilium) populates through a hostPath mount.

  No runtime `depends:`: oci/kubeadm-sysext.bst stages this artifact at a
  private location and ships exactly these files.

(@):
- include/kubeadm.yml

build-depends:
- base/base-stack.bst
- freedesktop-sdk.bst:components/findutils.bst

variables:
  # Upstream release binaries: never strip or rewrite them.
  strip-binaries: ""

sources:
- kind: remote
  url: k8s_dl:release/v%{kubernetes-version}/bin/linux/amd64/kubelet
  ref: 0e759f40bbc717c05227ae3994b77786f58f59ffa0137a34958c6b26fa5bcbbd
  directory: k8s
- kind: remote
  url: k8s_dl:release/v%{kubernetes-version}/bin/linux/amd64/kubeadm
  ref: f9ce265434d306e59d800b26f3049b8430ba71f815947f4bacdcdc33359417fb
  directory: k8s
- kind: remote
  url: k8s_dl:release/v%{kubernetes-version}/bin/linux/amd64/kubectl
  ref: ab60ca5f0fd60c1eb81b52909e67060e3ba0bd27e55a8ac147cbc2172ff14212
  directory: k8s
- kind: tar
  url: github:kubernetes-sigs/cri-tools/releases/download/v%{crictl-version}/crictl-v%{crictl-version}-linux-amd64.tar.gz
  ref: a8ff2a3edb37a98daf3aba7c3b284fe0aa5bff24166d896ab9ef64c8913c9f51
  base-dir: ''
  directory: crictl
- kind: tar
  url: github:containerd/containerd/releases/download/v%{containerd-version}/containerd-static-%{containerd-version}-linux-amd64.tar.gz
  ref: 9389a4bff0112258bd953c66382709c2a4a11e25e376c8c4c7075b39de156882
  base-dir: bin
  directory: containerd
- kind: remote
  url: github:opencontainers/runc/releases/download/v%{runc-version}/runc.amd64
  ref: 8781ab9f71c12f314d21c8e85f13ca1a82d90cf475aa5131a7b543fcc5487543
  directory: runc
- kind: tar
  url: github:containernetworking/plugins/releases/download/v%{cni-plugins-version}/cni-plugins-linux-amd64-v%{cni-plugins-version}.tgz
  ref: b275772da4026d2161bf8a8b41ed4786754c8a93ebfb6564006d5da7f23831e5
  base-dir: ''
  directory: cni

config:
  install-commands:
  - |
    set -eu
    if [ "%{arch}" != "x86_64" ]; then
      echo "ERROR: elements/kubeadm/kubeadm-bin.bst pins amd64 release binaries only (arch=%{arch})" >&2
      exit 1
    fi
    bin="%{install-root}%{bindir}"
    install -d "${bin}"
    for b in kubelet kubeadm kubectl; do install -m 0755 "k8s/${b}" "${bin}/"; done
    install -m 0755 crictl/crictl "${bin}/"
    for b in containerd containerd-shim-runc-v2 ctr; do install -m 0755 "containerd/${b}" "${bin}/"; done
    install -m 0755 runc/runc.amd64 "${bin}/runc"
    install -d "%{install-root}%{libexecdir}/cni"
    find cni -maxdepth 1 -type f -perm -u+x -exec install -m 0755 -t "%{install-root}%{libexecdir}/cni" {} +
    for p in loopback bridge host-local portmap; do
      [ -x "%{install-root}%{libexecdir}/cni/${p}" ] || { echo "ERROR: CNI plugin ${p} missing" >&2; exit 1; }
    done
