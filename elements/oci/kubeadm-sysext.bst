kind: manual
description: |
  Opt-in systemd-sysext that turns a Bluefin Server node into a kubeadm
  worker or a single-node control plane: kubelet, kubeadm, kubectl, crictl,
  containerd, runc and the CNI plugins from kubeadm/kubeadm-bin.bst, plus
  containerd.service, kubelet.service with kubeadm's 10-kubeadm.conf
  drop-in, kubeadm-init.service with its default init config, the default
  containerd config, crictl config, module and sysctl drop-ins, and an
  idempotent migration that prepends the containerd `imports` glob at the
  top level of a pre-existing /etc/containerd/config.toml that lacks it
  (line 1, the only always-valid placement for a top-level key) so drop-ins
  (the NVIDIA Container Toolkit sysext's `nvidia` runtime handler, node
  overrides in /etc/containerd/conf.d) deep-merge into the kubeadm config
  on the next containerd start. No preset enables anything; Ignition
  enables containerd.service and kubelet.service (worker) or
  kubeadm-init.service (control plane) per node.

  Output: kubeadm_<image-version>.raw, .raw.zst and SHA256SUMS. Locked to
  one image version like the ZFS sysext (extension-release.kubeadm_<ver>,
  ID=bluefin-server, VERSION_ID=<image-version>) and updated in lock-step
  with the OS through the `kubeadm` sysupdate feature.

(@):
- include/arch.yml
- include/image.yml
- include/kubeadm.yml
- include/sysext.yml

build-depends:
- base/base-stack.bst
- freedesktop-sdk.bst:components/erofs-utils.bst
- freedesktop-sdk.bst:components/zstd.bst
- filename: kubeadm/kubeadm-bin.bst
  config:
    location: /kubeadm

sources:
- kind: local
  path: files/kubeadm/sysext
  directory: sysext-src

variables:
  strip-binaries: ""
  sysext-name: "kubeadm"
  sysext-image: "kubeadm_%{image-version}"
  sysext-release: "kubeadm_%{image-version}"
  sysext-version: "%{image-version}"
  sysext-architecture: "%{systemd-arch}"

config:
  install-commands:
  - |
    set -euo pipefail
    src=sysext-src
    lib="sysext%{indep-libdir}"
    unitdir="${lib}/systemd/system"

    mkdir -p sysext
    cp -a /kubeadm%{prefix} sysext%{prefix}

    install -D -m 0644 -t "${unitdir}" "${src}/containerd.service" "${src}/kubelet.service" \
      "${src}/kubeadm-init.service" "${src}/kubeadm-init-config.service"
    install -D -m 0644 "${src}/10-kubeadm.conf" "${unitdir}/kubelet.service.d/10-kubeadm.conf"
    install -D -m 0755 "${src}/bluefin-kubeadm-init" "sysext%{libexecdir}/bluefin-kubeadm-init"
    install -D -m 0755 "${src}/bluefin-kubeadm-containerd-migrate" \
      "sysext%{libexecdir}/bluefin-kubeadm-containerd-migrate"
    install -D -m 0644 "${src}/80-kubeadm.preset" "${lib}/systemd/system-preset/80-kubeadm.preset"
    install -D -m 0644 "${src}/tmpfiles-kubeadm.conf" "${lib}/tmpfiles.d/kubeadm.conf"
    install -D -m 0644 "${src}/modules-load-kubeadm.conf" "${lib}/modules-load.d/kubeadm.conf"
    install -D -m 0644 "${src}/sysctl-90-kubeadm.conf" "${lib}/sysctl.d/90-kubeadm.conf"
    install -D -m 0644 "${src}/config.toml" "sysext%{datadir}/bluefin/containerd/config.toml"
    install -D -m 0644 "${src}/crictl.yaml" "sysext%{datadir}/bluefin/kubeadm/crictl.yaml"
    install -D -m 0644 "${src}/init-tmpfiles.conf" "sysext%{datadir}/bluefin/kubeadm/init-tmpfiles.conf"

    # The init config names the Kubernetes version these binaries are; the
    # sysext's own kubeadm checks it strictly (unknown fields fail).
    init="sysext%{datadir}/bluefin/kubeadm/init.yaml"
    template="$(cat "${src}/init.yaml")"
    printf '%s\n' "${template//@KUBERNETES_VERSION@/%{kubernetes-version}}" > "${init}"
    chmod 0644 "${init}"
    case "$(cat "${init}")" in
      *$'\n''kubernetesVersion: v%{kubernetes-version}'$'\n'*) ;;
      *) echo "ERROR: init.yaml kubernetesVersion is not v%{kubernetes-version}" >&2; exit 1 ;;
    esac
    /kubeadm%{bindir}/kubeadm config validate --config "${init}"

    case "$(cat "sysext%{datadir}/bluefin/containerd/config.toml")" in
      *'sandbox = "%{pause-image}"'*) ;;
      *) echo "ERROR: config.toml sandbox image is not %{pause-image} (include/kubeadm.yml)" >&2; exit 1 ;;
    esac

    # A sysext may only carry /usr (and /opt, which must stay a plain
    # writable host directory for /opt/cni/bin).
    for entry in sysext/* sysext/.[!.]*; do
      [ -e "${entry}" ] || [ -L "${entry}" ] || continue
      [ "${entry}" = "sysext%{prefix}" ] || { echo "ERROR: sysext ships ${entry#sysext}" >&2; exit 1; }
    done

  - "%{sysext-pack}"
