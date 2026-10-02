---
name: homelab-profile
description: The Bluefin Server Homelab profile, i.e. the Ignition templates that turn a node into a homelab control plane or node (kubeadm, or k0s), how they pull in the sysexts, and how the USB installer's Homelab entries use them. Load when changing, publishing or testing the templates.
metadata:
  type: how-to
  status: stable
  last_updated: "2026-10-01"
---
# Homelab profile

Bluefin Server stays an OS plus opt-in pieces. The Homelab profile is those
pieces turned on by **one Ignition template**: the kubeadm and homelab
sysexts, a cluster, and the default homelab component set. Use a template
on any node (network boot, an installed disk, a VM), or pick a Homelab
entry in the USB installer's boot menu ([usb-installer.md](usb-installer.md)).

## When to Use

- Changing, publishing or testing the templates in `files/homelab/templates/`.
- Explaining what a template turns on, and what to edit before using it.

## When NOT to Use

- The components and the applier (`bluefin-homelab-apply`): every key and
  default is in `files/homelab/sysext/homelab.conf.example`, the sysext in
  [systemd-sysext-extensions.md](systemd-sysext-extensions.md).
- Joining and the passphrase protocol:
  [`files/homelab/cluster/README.md`](../../files/homelab/cluster/README.md).
- kubeadm itself: [kubeadm-sysext.md](kubeadm-sysext.md); k0s:
  [k0s-sysext.md](k0s-sysext.md).

## Templates

One template per runtime and role. Butane has no conditionals and the role
decides which units start (a node must never run `kubeadm init` or start a
k0s controller), so the role is the file you pick, and each file works
unmodified apart from the values below.

| Template | Runtime | Role | sysupdate features | Starts |
|---|---|---|---|---|
| `homelab-control-plane` | kubeadm | control-plane | `kubeadm`, `homelab` | `kubeadm-init.service` (link) |
| `homelab-node` | kubeadm | node | `kubeadm`, `homelab` | `bluefin-cluster-join.service` (from the sysext) |
| `homelab-k0s-control-plane` | k0s | control-plane | `homelab` (+ k0s component) | `k0s-first-boot.service`; `/etc/sysconfig/k0s` drops `--single` |
| `homelab-k0s-node` | k0s | node | `homelab` (+ k0s component) | `k0s-first-boot-fetch.service` (link); the join starts k0s |

Every template also enables `bluefin-sysext-fetch.service` and `sshd.service`
(key-only root login; the key line is an `authorized_keys` comment
placeholder) and writes `/etc/bluefin/homelab.conf.template` plus a tmpfiles
`C` rule that copies it to `/etc/bluefin/homelab.conf` only while that file
is absent. A control-plane template's copy is `homelab.conf.example` with
`HOMELAB_ROLE=control-plane` set: the default component set (monitoring off)
and every optional block commented (MetalLB pool, ACME email, Argo CD root
repository, NFS, democratic-csi, GPU Operator, monitoring). A node's sets
`HOMELAB_ROLE=node` with `HOMELAB_JOIN_PASSPHRASE` and
`HOMELAB_CONTROL_PLANE` commented. Nothing secret is in a template.

`files/homelab/templates/<name>.bu` is the source; `<name>.ign` is it
compiled to Ignition 3.6 by `just homelab-templates` (butane pinned by digest
in the Justfile; `just homelab-templates 1` fails on a stale `.ign`).
`tests/unit/test_homelab_templates.py` checks the `.ign` against the `.bu`
without butane, the units and features each one turns on, and that none
carries a secret or turns monitoring on. Both forms are release assets
(signed `SHA256SUMS`, `scripts/publish-release.sh` requires all eight),
unversioned, so `releases/latest/download/homelab-control-plane.bu` names
the newest.

**Edit before use:** replace the SSH key line, and on a control plane set
what you need in `homelab.conf.template` (at least
`HOMELAB_METALLB_ADDRESSES`: without a pool MetalLB assigns nothing and
LoadBalancer Services, Envoy Gateway's included, stay pending). Ignition
(v2.27) reads Butane YAML as is, so the edited `.bu` can be passed directly;
compile it with butane only for other consumers.

## Using a template

Pass the file as the node's `ignition.config` system credential (SMBIOS type
11, QEMU fw_cfg, an encrypted `/loader/credentials/ignition.config.cred`), or
serve it as a network-booted node's `bluefin-node.ign`
([ddi-installer.md](ddi-installer.md), "Ignition (opt-in)"). On its first
boot (and on the first boot of each new image version)
`bluefin-sysext-fetch.service` installs the enabled features' sysexts for the
running version and merges them; how it finds them (the installer's copy on
the ESP, the boot server, or the release through `systemd-sysupdate`) is in
[systemd-sysext-extensions.md](systemd-sysext-extensions.md). On an installed
node the enabled features keep the sysexts in step with OS updates. The
cluster images are pulled from the internet at `kubeadm init` and by the
applier. A diskless node keeps `/var`, and so every image, in RAM: with
the default set kubelet reports DiskPressure and evicts pods unless the
node has a disk for `/var` (an Ignition `var.mount`, as in
`tests/fixtures/ignition/var-on-disk.ign`) or far more RAM.

**Joining.** The control plane generates a join passphrase and shows it on
its consoles (`bluefin-cluster passphrase`). Give it to a node as
`HOMELAB_JOIN_PASSPHRASE` in its template's `homelab.conf.template`, as the
`bluefin-cluster.passphrase` credential, or at the USB installer's prompt.
A node removes it from `homelab.conf` once joined; a copy you put into a
provisioning config stays wherever that config is kept.

**Ignition runs on every boot that carries the config** (always on a diskless
node; on a disk installed from the USB stick until the first OS update
replaces the boot entry that carries it). Every file a template writes is
rewritten then, so change those in the template; `homelab.conf` is the
exception, created once and yours to edit afterwards on an installed node.

**Access.** No identity layer: `ssh root@<node>` with your key; `kubectl` as
root uses kubeadm's `/etc/kubernetes/admin.conf` (k0s:
`/var/lib/k0s/pki/admin.conf`); Argo CD's built-in `admin` with the
password in `argocd-initial-admin-secret`.

**k0s** is the alternative: the two k0s templates, not offered by the USB
installer, which installs kubeadm only.

## Verify

- `python3 -m pytest tests/unit/test_homelab_templates.py tests/unit/test_sysext_fetch.py tests/unit/test_homelab_installer.py`
- `just homelab-templates 1` (podman)
- `just dogfood-homelab-templates`: a diskless control plane from
  `homelab-control-plane.bu` and a node from `homelab-node.ign` with the
  passphrase it showed; the default set applied (monitoring off, MetalLB
  without a pool), a local-path PVC bound, both nodes Ready. Needs guest
  internet.
- `just dogfood-homelab-installer`: the same from the USB installer's Homelab
  entries, offline installs ([usb-installer.md](usb-installer.md)).
