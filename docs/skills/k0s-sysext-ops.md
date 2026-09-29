---
name: k0s-sysext-ops
description: Operator runbook for the k0s and KubeStellar systemd-sysext extensions on Bluefin Server — provisioning, runtime testing, and troubleshooting.
metadata:
  type: how-to
  status: stable
  last_updated: "2026-09-29"
  context7-sources:
    - /systemd/systemd
---
# k0s / KubeStellar systemd-sysext Operations

Use this skill when running, testing, or debugging the k0s and KubeStellar
systemd-sysext extensions on a live Bluefin Server host.

## The split

Bluefin Server ships two separate, opt-in sysexts:

- **k0s** (`oci/k0s-sysext.bst`): the k0s binary plus `k0scontroller.service`
  and `k0sworker.service`. No Kubernetes add-ons are included. It is its own
  sysupdate component on its own version axis (`ID=_any`).
- **KubeStellar** (`oci/kubestellar-sysext.bst`): Argo CD and KubeStellar
  manifests, loopback kiosk proxy assets, kubeflex secret generators, and the
  KubeStellar console issue banner. Requires the k0s sysext. It is
  version-locked to the OS image and follows OS updates.

## Enabling k0s on a host

`k0s-first-boot.service` is **not enabled by default**; the preset
`80-bluefin-opt-in.preset` disables it and its fetcher. To opt in:

```bash
# 1. Place the k0s sysext image at /var/lib/k0s/k0s.raw, or let the fetcher
#    pull it from the release track:
systemd-sysupdate --component=k0s update

# 2. Enable the one-shot activation unit
systemctl enable --now k0s-first-boot.service
```

The unit copies `/var/lib/k0s/k0s.raw` to `/run/extensions/k0s.raw`, runs
`systemd-sysext refresh`, and then enables either `k0scontroller.service` or
`k0sworker.service` depending on whether `/etc/k0s/token` exists.

While either k0s unit runs, the base image's automatic reboot stands down,
and so does the boot-deadline rollback reboot, which flags
`/run/reboot-required` instead; deploy kured to roll staged OS updates (and
rollbacks) across the cluster (see "Updates" in
[ddi-installer.md](ddi-installer.md)).

### Worker nodes

A node with a join token at `/etc/k0s/token` becomes a worker. The token can be
written by Booty via Ignition at provisioning time; `k0sworker.service` will
start automatically on the next boot when the token is present.

## Enabling the KubeStellar appliance

The KubeStellar sysext is opt-in and version-locked to the OS image. Enable
its sysupdate feature so it downloads with every OS update:

```bash
updatectl enable kubestellar
# or, equivalently, a drop-in /etc/sysupdate.d/kubestellar.feature.d/enable.conf
# with [Feature] Enabled=true, then systemd-sysupdate update
```

This places `kubestellar_<ver>.raw` under `/var/lib/extensions/` (two versions
kept). `systemd-sysext` merges only the one matching the booted image, on the
next refresh or boot, so a boot-counted OS rollback keeps the matching
KubeStellar.

Once merged, `kubestellar-seed.service` is pulled in by `k0scontroller.service`
via a `.wants` drop-in and runs **Before** it. The seed unit:

1. Runs `systemd-tmpfiles --create /usr/lib/tmpfiles.d/k0s-manifests.conf` to
   seed Argo CD and KubeStellar YAML stacks into `/var/lib/k0s/manifests/`.
2. Generates a per-node kiosk TLS key at `/var/lib/k0s/kiosk/key.pem` (mode
   600). The public sysext never ships key material; the key is created on the
   node on first use.
3. Runs the kubeflex secret generators
   (`generate-postgres-secret.sh`, `generate-console-secret.sh`).

## Verifying

```bash
# Check merged extensions
systemd-sysext status

# Check k0s role
systemctl status k0scontroller.service   # controller node
systemctl status k0sworker.service       # worker node

# Check seeded manifests
ls /var/lib/k0s/manifests/argocd/ /var/lib/k0s/manifests/kubestellar/

# Check pods
k0s kubectl get pods -A
```

## Verified QEMU behavior

Opt-in activation in QEMU reaches:

- `k0scontroller.service` active
- `kubestellar-seed.service` active
- Manifests present under `/var/lib/k0s/manifests/argocd/` and
  `/var/lib/k0s/manifests/kubestellar/`
- Kiosk key at `/var/lib/k0s/kiosk/key.pem` with mode 600

Placing a token at `/etc/k0s/token` switches the node to `k0sworker.service`.

## Troubleshooting

- **Extension not merged**: Check `systemd-sysext status`. For k0s, verify the
  persistent image is `/var/lib/k0s/k0s.raw`; `k0s-first-boot.service` copies it
  into `/run/extensions/k0s.raw`. For KubeStellar, verify the versioned image
  matching the booted OS version exists at
  `/var/lib/extensions/kubestellar_<ver>.raw`.
- **Seed unit did not run**: Confirm the KubeStellar sysext is merged and that
  `k0scontroller.service` is starting. The seed unit has
  `Before=k0scontroller.service` and `RequiresMountsFor=/var/lib/k0s`.
- **Manifests not applied**: Check `/var/lib/k0s/manifests/`. Ensure files end
  in `.yaml` (not `.yml`).
- **Service failed**: Check `journalctl -u k0scontroller -e` or
  `journalctl -u k0sworker -e`. For the seed unit, check
  `journalctl -u kubestellar-seed -e`.

## See also

- [k0s-sysext.md](k0s-sysext.md)
- [CONTEXT.md](../../CONTEXT.md) — canonical project domain glossary (Sysext definition).
- `systemd-sysext(8)`
