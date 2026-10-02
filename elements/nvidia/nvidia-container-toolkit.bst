kind: manual
description: |
  NVIDIA Container Toolkit, CDI only: nvidia-ctk, nvidia-cdi-hook and
  nvidia-container-runtime.cdi built from the release source with FSDK Go,
  plus upstream's nvidia-cdi-refresh.{service,path} and its
  10-container-engines.conf drop-in, and the license and third-party
  notices.

  nvidia-container-runtime.cdi is upstream's runtime wrapper with the mode
  fixed to "cdi" in code (cmd/nvidia-container-runtime.cdi): it injects the
  CDI devices a container asks for and execs runc, and never needs the
  legacy stack. /usr/bin/nvidia-container-runtime is a symlink to it, the
  name container engines and the GPU Operator's RuntimeClass expect.

  Not built: the plain nvidia-container-runtime (mode from
  /etc/nvidia-container-runtime/config.toml, "auto" by default, which
  resolves to the legacy stack), nvidia-container-runtime.legacy,
  nvidia-container-runtime-hook (the OCI prestart hook) and
  libnvidia-container. containerd reads the CDI spec that
  nvidia-cdi-refresh.service generates at /var/run/cdi/nvidia.yaml.

  The source is the release tag's commit, fetched with git. Upstream
  commits vendor/, so Go modules come from that tree and the build needs
  no network. The third_party/libnvidia-container submodule is not
  fetched; nothing built here uses it. go-nvml needs cgo; the link flags are the ones
  upstream's Makefile uses, which leave the NVML symbols to be resolved
  when libnvidia-ml is dlopen()ed.

  No runtime `depends:`: oci/nvidia-container-toolkit-sysext.bst stages
  this artifact at a private location and ships exactly these files.

(@):
- include/nvidia-container-toolkit.yml

build-depends:
- base/base-stack.bst
- freedesktop-sdk.bst:components/go.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst

sources:
- kind: git_repo
  url: github:NVIDIA/nvidia-container-toolkit.git
  ref: "v%{nvidia-container-toolkit-version}-0-g%{nvidia-container-toolkit-commit}"

environment:
  GOROOT: "%{libdir}/go"
  GOTOOLCHAIN: local
  GOFLAGS: -mod=vendor -trimpath -buildvcs=false
  CGO_ENABLED: "1"

variables:
  # -s -w in the go build below already drops the symbol tables.
  strip-binaries: ""

config:
  build-commands:
  - |
    set -eu
    export GOPATH="${PWD}/.gopath" GOCACHE="${PWD}/.gocache"
    pkg=github.com/NVIDIA/nvidia-container-toolkit/internal/info
    for cmd in nvidia-ctk nvidia-cdi-hook nvidia-container-runtime.cdi; do
      go build -o "${cmd}" -ldflags "-s -w \
        '-extldflags=-Wl,--export-dynamic -Wl,--unresolved-symbols=ignore-in-object-files -Wl,-z,lazy' \
        -X ${pkg}.version=%{nvidia-container-toolkit-version}" "./cmd/${cmd}"
    done

  install-commands:
  - |
    set -eu
    install -D -m 0755 -t "%{install-root}%{bindir}" nvidia-ctk nvidia-cdi-hook nvidia-container-runtime.cdi
    ln -s nvidia-container-runtime.cdi "%{install-root}%{bindir}/nvidia-container-runtime"
    unitdir="%{install-root}%{indep-libdir}/systemd/system"
    install -D -m 0644 -t "${unitdir}" \
      deployments/systemd/nvidia-cdi-refresh.service \
      deployments/systemd/nvidia-cdi-refresh.path
    install -D -m 0644 -t "${unitdir}/nvidia-cdi-refresh.service.d" \
      deployments/systemd/10-container-engines.conf
    install -D -m 0644 -t "%{install-root}%{datadir}/licenses/nvidia-container-toolkit" \
      LICENSE THIRD_PARTY_NOTICES.md
