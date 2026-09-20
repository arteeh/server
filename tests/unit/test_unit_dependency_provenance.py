"""Every hard dependency of a shipped unit must have a named provider.

`just validate` resolves the BuildStream graph, but a systemd `Requires=` is not
a bst node — the graph cannot see it. A unit that requires a service nothing
ships still builds, still validates, and then fails at boot with a job that
cannot be resolved. That is a silent, boot-only failure mode.

This module closes it. Every unit named by `Requires=` or `BindsTo=` in a unit
this repository stages must be either:

  * staged by this repository (a peer file in files/os/systemd/system), or
  * listed in EXTERNAL_PROVIDERS with the component that supplies it.

Adding a hard dependency on something nothing provides therefore fails here
rather than on a running machine.
"""

from __future__ import annotations

from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
UNIT_DIR = ROOT / "files" / "os" / "systemd" / "system"

# Units this repository does not stage, mapped to what does supply them.
#
# containerd.service is the load-bearing entry. Flatcar ships containerd as a
# sysext blob inside its /usr tree (usr/share/flatcar/sysext/containerd-flatcar.raw,
# 26 MiB, verified against the 4593.2.5 image contents listing). That tree only
# reaches this image through elements/flatcar/flatcar-usr.bst, which is NOT on
# main yet — it arrives with PR #140, and os-stack.bst consumes it in PR #132.
#
# Until both land, kubeadm-init.service has a hard requirement on a unit no
# element supplies, so the control plane does not come up on a real boot. The
# cutover is structurally complete but inert until then. This entry records that
# deliberately; delete the note, not the entry, once #140 and #132 have landed.
EXTERNAL_PROVIDERS = {
    "containerd.service": (
        "Flatcar /usr via elements/flatcar/flatcar-usr.bst — PENDING PR #140/#132"
    ),
    "systemd-sysext.service": "systemd, present in the base image",
    "network-online.target": "systemd",
    "systemd-networkd.service": "systemd",
    "var.mount": "generated from the installer's /var partition",
}

HARD_DEPENDENCY_KEYS = ("Requires=", "BindsTo=")


def staged_units() -> set[str]:
    return {path.name for path in UNIT_DIR.iterdir() if path.is_file()}


def hard_dependencies() -> list[tuple[str, str]]:
    """Return (unit_file, required_unit) for every hard dependency declared."""
    found: list[tuple[str, str]] = []
    for unit in sorted(UNIT_DIR.glob("*.service")):
        for raw in unit.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            for key in HARD_DEPENDENCY_KEYS:
                if line.startswith(key):
                    # systemd accepts a space-separated list and repeated keys.
                    for name in line[len(key):].split():
                        found.append((unit.name, name))
    return found


def test_units_declare_at_least_one_hard_dependency() -> None:
    """Guard the parser itself: a silent zero-match would make this suite vacuous."""
    assert hard_dependencies(), "parsed no Requires=/BindsTo= at all; parser is broken"


@pytest.mark.parametrize(
    ("unit", "required"),
    hard_dependencies(),
    ids=lambda value: value.replace(".service", ""),
)
def test_hard_dependency_has_a_provider(unit: str, required: str) -> None:
    local = staged_units()
    assert required in local or required in EXTERNAL_PROVIDERS, (
        f"{unit} declares a hard dependency on {required!r}, which this repository "
        f"does not stage and EXTERNAL_PROVIDERS does not account for. Either ship "
        f"the unit, or record who supplies it — a Requires= on a unit nothing "
        f"provides fails only at boot, where nothing else catches it."
    )


def test_containerd_provider_is_recorded_as_pending() -> None:
    """The cutover is inert until Flatcar's /usr lands; keep that visible.

    kubeadm-init.service requires containerd.service. Nothing on main supplies
    it. This asserts the gap stays documented rather than quietly forgotten.
    """
    assert "containerd.service" in EXTERNAL_PROVIDERS
    assert "flatcar-usr.bst" in EXTERNAL_PROVIDERS["containerd.service"], (
        "containerd.service must name flatcar-usr.bst as its provider"
    )


def test_kubelet_bridges_the_cni_plugin_directory() -> None:
    """Plugins ship at the bakery path; containerd and Cilium read /opt/cni/bin.

    Without the bridge the loopback plugin is absent, every pod sandbox fails to
    get a network, and the node never leaves NotReady with no obvious cause.
    """
    kubelet = (UNIT_DIR / "kubelet.service").read_text(encoding="utf-8")

    assert "/opt/cni/bin" in kubelet, "kubelet does not populate /opt/cni/bin"
    assert "/usr/local/bin/cni" in kubelet, (
        "kubelet does not read the sysext's CNI plugin directory"
    )

    bridge = next(
        line for line in kubelet.splitlines() if "cp -a" in line and "cni" in line
    )
    assert "-an" in bridge or "--no-clobber" in bridge, (
        "the copy must not clobber: the cilium agent installs its own binary "
        "into /opt/cni/bin and overwriting it breaks the CNI chain"
    )

    body = kubelet.split("[Service]", 1)[1]
    assert body.index("/opt/cni/bin") < body.index("ExecStart=/usr/bin/kubelet"), (
        "the bridge must run before kubelet starts"
    )
