"""An installer-seeded sysext must keep the stem its extension-release names.

systemd-sysext resolves an extension's metadata by filename stem. An image
merged as ``<name>.raw`` is required to carry
``/usr/lib/extension-release.d/extension-release.<name>``; if it does not, the
extension is refused. The refusal is silent from the build's point of view —
the element builds, ``just validate`` resolves, the installer writes a bootable
disk, and the failure only appears as a missing service on a running machine.

``tests/unit/test_sysupdate_transfers.py`` already enforces this for the
Kubernetes sysext on the *sysupdate* path, where the name is fixed by the
transfer's ``CurrentSymlink``. This module covers the other path: the images
``files/installer/repart.d/30-var.conf`` seeds onto ``/var/lib/extensions`` at
install time, whose names are fixed by ``CopyFiles=`` and by the element that
stages them.

The concrete hazard is the Flatcar containerd import. Upstream names it
``containerd-flatcar.raw`` and ships ``extension-release.containerd-flatcar``.
Shortening it to ``containerd.raw`` anywhere in the chain — the element's
install target, the installer's ``cp`` into the initrd, or the ``CopyFiles=``
here — makes systemd-sysext look for ``extension-release.containerd``, find
nothing, and drop containerd.service. ``kubeadm-init.service`` then has an
unresolvable hard requirement and the control plane never starts.

The chain is asserted end to end so a rename in any one link fails here.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VAR_REPART = ROOT / "files" / "installer" / "repart.d" / "30-var.conf"
INSTALLER = ROOT / "elements" / "oci" / "bluefin-server-installer.bst"
CONTAINERD_ELEMENT = ROOT / "elements" / "flatcar" / "containerd-sysext.bst"
KUBEADM_INIT = ROOT / "files" / "os" / "systemd" / "system" / "kubeadm-init.service"

# Units that only a seeded sysext can provide, mapped to the image that ships
# them. Derived from the image contents, not from configuration: Flatcar's
# containerd-flatcar.raw carries usr/lib/systemd/system/containerd.service.
SYSEXT_PROVIDED_UNITS = {
    "containerd.service": "containerd-flatcar.raw",
}

COPY_FILES_RE = re.compile(r"^CopyFiles=([^:]+):(.+)$", re.MULTILINE)


def seeded_extensions() -> dict[str, str]:
    """``{staged source path: destination path}`` for every seeded sysext."""
    return {
        src: dst
        for src, dst in COPY_FILES_RE.findall(VAR_REPART.read_text(encoding="utf-8"))
        if "/lib/extensions/" in dst
    }


def test_every_sysext_provided_unit_a_host_unit_requires_is_actually_seeded() -> None:
    """A hard Requires= on a sysext-provided unit obliges the installer to seed it.

    Deleting the ``CopyFiles=`` line for containerd would restore exactly the
    failure this whole arrangement exists to fix: kubeadm-init.service holds
    ``Requires=containerd.service``, nothing provides it, the job is
    unresolvable, and bluefin-cluster-bootstrap.service never runs because it
    declares ``Requires=kubeadm-init.service``. The machine boots to
    multi-user.target with no control plane.

    The requirement is read out of the unit rather than restated here, so
    dropping the ``Requires=`` deliberately also relaxes this test.
    """
    unit = without_comments(KUBEADM_INIT.read_text(encoding="utf-8"))
    seeded_names = {Path(dst).name for dst in seeded_extensions().values()}

    for required_unit, image in SYSEXT_PROVIDED_UNITS.items():
        if f"Requires={required_unit}" not in unit:
            continue
        assert image in seeded_names, (
            f"{KUBEADM_INIT.relative_to(ROOT)} declares "
            f"Requires={required_unit}, which only {image} provides, but "
            f"{VAR_REPART.relative_to(ROOT)} does not seed it into "
            f"/lib/extensions. Seeded images: {sorted(seeded_names) or 'none'}. "
            "The control plane will not start."
        )


def test_seeded_images_land_in_the_sysext_scan_directory() -> None:
    seeded = seeded_extensions()

    assert seeded, (
        f"{VAR_REPART.relative_to(ROOT)} seeds no sysext into /lib/extensions; "
        "the installer's offline-merge path has regressed"
    )

    for src, dst in seeded.items():
        assert dst.startswith("/lib/extensions/"), (
            f"{dst} is not under /lib/extensions, so systemd-sysext will not "
            f"scan it (/var is mounted at /var, making this /var/lib/extensions)"
        )
        assert dst.endswith(".raw"), f"{dst} is not a .raw sysext image"
        assert Path(src).name == Path(dst).name, (
            f"{VAR_REPART.relative_to(ROOT)} renames {src} to {dst} in flight. "
            "The seeded name is what systemd-sysext resolves "
            "extension-release.<name> against; renaming here breaks the merge."
        )


def test_installer_stages_every_seeded_image_under_its_seeded_name() -> None:
    installer = INSTALLER.read_text(encoding="utf-8")

    for src in seeded_extensions():
        # repart reads CopyFiles= sources from the installer's own root, which
        # is the staged /layer tree.
        staged = f"/layer{src}"
        assert staged in installer, (
            f"{VAR_REPART.relative_to(ROOT)} seeds {src}, but "
            f"{INSTALLER.relative_to(ROOT)} never stages {staged} into the "
            "initrd, so repart has nothing to copy at install time"
        )


def without_comments(text: str) -> str:
    """Effective directives only, for ``#``-commented formats.

    The prose in these files deliberately names the wrong spelling in order to
    warn against it, so scanning raw text would flag the warning as the defect.
    """
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def test_containerd_keeps_its_upstream_extension_release_stem() -> None:
    """The specific rename that would silently drop containerd.service.

    Flatcar's image carries extension-release.containerd-flatcar, so every link
    in the chain must say ``containerd-flatcar.raw``, never ``containerd.raw``.
    """
    element = CONTAINERD_ELEMENT.read_text(encoding="utf-8")

    assert '"%{install-root}/containerd-flatcar.raw"' in element, (
        f"{CONTAINERD_ELEMENT.relative_to(ROOT)} must install the image as "
        "containerd-flatcar.raw to match extension-release.containerd-flatcar"
    )

    # Only the two `#`-commented files are scanned for the forbidden spelling.
    # The element's `description: |` is a YAML block scalar, not a comment, and
    # it names containerd.raw on purpose to explain the hazard. The element is
    # pinned by the positive assertion above instead, which is the stronger
    # check: it fails if the install target is anything but containerd-flatcar.raw.
    for path in (INSTALLER, VAR_REPART):
        # `containerd.raw` as a whole token — `containerd-flatcar.raw` must not
        # trip this.
        match = re.search(
            r"(?<![\w-])containerd\.raw", without_comments(path.read_text(encoding="utf-8"))
        )
        assert match is None, (
            f"{path.relative_to(ROOT)} refers to containerd.raw. "
            "systemd-sysext would look for extension-release.containerd, which "
            "the Flatcar image does not ship, and refuse to merge it — dropping "
            "containerd.service and leaving kubeadm-init.service with an "
            "unresolvable requirement."
        )
