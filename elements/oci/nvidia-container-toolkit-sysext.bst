kind: manual
description: |
  Opt-in systemd-sysext with the NVIDIA Container Toolkit for CDI: nvidia-ctk,
  nvidia-cdi-hook, nvidia-container-runtime.cdi (with the
  nvidia-container-runtime symlink) and upstream's
  nvidia-cdi-refresh.{service,path} from nvidia/nvidia-container-toolkit.bst,
  plus a containerd drop-in that registers the `nvidia` runtime handler
  (files/nvidia-container-toolkit/sysext/containerd-nvidia-container-runtime.toml,
  imported by the kubeadm sysext's containerd config). No OCI hook or
  libnvidia-container, and no CDI spec: nvidia-cdi-refresh.service writes
  /var/run/cdi/nvidia.yaml at boot, where containerd's CRI plugin (CDI on by
  default in containerd 2.x) and the runtime pick it up.

  Output: nvidia-container-toolkit-<version>.raw, .raw.zst and SHA256SUMS.
  Like k0s it has its own version axis (include/nvidia-container-toolkit.yml):
  ID=_any and no image VERSION_ID, merged under the stable name
  nvidia-container-toolkit.raw.

  Both units are wired into multi-user.target with static .wants links
  (presets are inert inside a sysext). Without the driver sysext they are
  skipped by upstream's conditions (no nvidia-smi); with the driver on a node
  without an NVIDIA GPU, a Bluefin drop-in skips the refresh too.

(@):
- include/arch.yml
- include/nvidia-container-toolkit.yml
- include/sysext.yml

build-depends:
- base/base-stack.bst
- freedesktop-sdk.bst:components/erofs-utils.bst
- freedesktop-sdk.bst:components/zstd.bst
- filename: nvidia/nvidia-container-toolkit.bst
  config:
    location: /nvidia-container-toolkit

sources:
- kind: local
  path: files/nvidia-container-toolkit/sysext
  directory: sysext-src

variables:
  strip-binaries: ""
  sysext-name: "nvidia-container-toolkit"
  sysext-image: "nvidia-container-toolkit-%{nvidia-container-toolkit-version}"
  sysext-release: "nvidia-container-toolkit"
  sysext-version: "%{nvidia-container-toolkit-version}"
  sysext-architecture: "%{systemd-arch}"

config:
  install-commands:
  - |
    set -euo pipefail
    unitdir="sysext%{indep-libdir}/systemd/system"

    mkdir -p sysext
    cp -a /nvidia-container-toolkit%{prefix} sysext%{prefix}

    install -D -m 0644 sysext-src/nvidia-cdi-refresh-bluefin.conf \
      "${unitdir}/nvidia-cdi-refresh.service.d/50-bluefin.conf"
    install -D -m 0644 sysext-src/containerd-nvidia-container-runtime.toml \
      "sysext%{datadir}/bluefin/containerd/conf.d/nvidia-container-runtime.toml"

    for bin in nvidia-ctk nvidia-cdi-hook nvidia-container-runtime.cdi; do
      [ -x "sysext%{bindir}/${bin}" ] || { echo "ERROR: ${bin} missing from the toolkit build" >&2; exit 1; }
    done
    [ "$(readlink "sysext%{bindir}/nvidia-container-runtime")" = nvidia-container-runtime.cdi ] ||
      { echo "ERROR: nvidia-container-runtime must be a symlink to nvidia-container-runtime.cdi" >&2; exit 1; }

    mkdir -p "${unitdir}/multi-user.target.wants"
    for u in nvidia-cdi-refresh.service nvidia-cdi-refresh.path; do
      [ -f "${unitdir}/${u}" ] || { echo "ERROR: ${u} missing from the toolkit build" >&2; exit 1; }
      ln -s "../${u}" "${unitdir}/multi-user.target.wants/${u}"
    done

    for entry in sysext/* sysext/.[!.]*; do
      [ -e "${entry}" ] || [ -L "${entry}" ] || continue
      [ "${entry}" = "sysext%{prefix}" ] || { echo "ERROR: sysext ships ${entry#sysext}" >&2; exit 1; }
    done

  - "%{sysext-pack}"
