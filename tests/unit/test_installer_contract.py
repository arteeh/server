"""Contracts for the published Installer and headless smoke boot."""

from __future__ import annotations

import re
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
INSTALLER_STACK = REPO_ROOT / "elements" / "installer" / "installer-stack.bst"
INSTALLER_ELEMENT = (
    REPO_ROOT / "elements" / "oci" / "bluefin-server-installer.bst"
)
JUSTFILE = REPO_ROOT / "Justfile"
DDI_ELEMENT = REPO_ROOT / "elements" / "oci" / "bluefin-server-ddi.bst"


def _installer_boot_cmdline(installer_element: str) -> str:
    """The cmdline the installer medium boots with.

    It lives in a systemd-boot type-1 loader entry, not in a UKI. A single
    `ukify build --linux --initrd` produced a 434 MiB PE that firmware loads and
    then never executes; measured on the same firmware and ESP, 34 MiB and
    64 MiB images boot and 434 MiB does not. The installer's initrd is ~382 MiB
    because it carries the live environment, so it cannot live in a PE section.
    """
    match = re.search(
        r"^\s*'options ([^']+)'\s*\\?\s*$",
        installer_element,
        flags=re.MULTILINE,
    )
    assert match, "installer loader entry must declare an options= line"
    return match.group(1)


def _target_uki_cmdline(installer_element: str) -> str:
    match = re.search(
        r'ukify build\s+.*?--cmdline="([^"]+)"\s+'
        r"[ \t\\\r\n]+--output=/target-root/boot/EFI/Linux/bluefin-server\.efi",
        installer_element,
        flags=re.DOTALL,
    )
    assert match, "target UKI ukify command must be present"
    return match.group(1)


def test_installer_runtime_and_boot_contracts() -> None:
    installer_stack = INSTALLER_STACK.read_text(encoding="utf-8")
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")
    justfile = JUSTFILE.read_text(encoding="utf-8")
    installer_boot_cmdline = _installer_boot_cmdline(installer_element)
    target_uki_cmdline = _target_uki_cmdline(installer_element)

    assert "freedesktop-sdk.bst:bootstrap/bash.bst" in installer_stack
    assert "console=ttyS0,115200 rw" in installer_element
    # The contract that used to live on the UKI's --cmdline and now lives in the
    # loader entry's options=. Assert it positively: a medium that boots but
    # lands in a shell instead of system-install.target is just as useless as
    # one that does not boot, and only the negative "unattended" check survived
    # the move.
    assert "systemd.unit=system-install.target" in installer_boot_cmdline, (
        "the medium must boot straight into the installer"
    )
    assert "console=ttyS0,115200" in installer_boot_cmdline, (
        "serial console is how the QEMU gate and headless hardware observe the "
        "install; without it a failure is silent"
    )
    assert "console=tty0" in installer_boot_cmdline, (
        "a physical operator watches tty0"
    )
    assert "rw" in installer_boot_cmdline.split(), (
        "the live environment needs a writable root"
    )
    assert "unattended" not in installer_boot_cmdline
    assert target_uki_cmdline == "rw console=ttyS0,115200 console=tty0 quiet loglevel=3 audit=0"
    assert (
        '-append "systemd.unit=system-install.target '
        'console=tty0 console=ttyS0,115200 rw unattended"'
    ) in justfile


def test_installer_wrapper_reads_kernel_command_line_without_cat() -> None:
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")

    assert 'CMDLINE="$(< /proc/cmdline)"' in installer_element
    assert 'CMDLINE="$(cat /proc/cmdline' not in installer_element


def test_installer_stages_uncompressed_sysext_before_packing_cpio() -> None:
    """The sysext has to be in /layer before the initrd is packed, or the
    offline installer ships no Kubernetes at all."""
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")
    data = yaml.safe_load(installer_element)
    sysext_dependency = next(
        (
            dependency
            for dependency in data["build-depends"]
            if isinstance(dependency, dict)
            and dependency.get("filename") == "oci/kubernetes-sysext.bst"
        ),
        None,
    )

    assert sysext_dependency == {
        "filename": "oci/kubernetes-sysext.bst",
        "config": {"location": "/kubernetes"},
    }

    seed_command = "cp /kubernetes/kubernetes-*.raw /layer/kubernetes.raw"
    cpio_command = "| cpio --null --create --format=newc"
    assert seed_command in installer_element
    assert installer_element.index(seed_command) < installer_element.index(
        cpio_command
    )


def test_ddi_generates_module_indexes_for_runtime_filesystem_drivers() -> None:
    ddi_element = DDI_ELEMENT.read_text(encoding="utf-8")

    assert "freedesktop-sdk.bst:components/kmod.bst" in ddi_element
    assert 'depmod -b /layer/usr "${KVER}"' in ddi_element
    assert "cp -a /etc/pki/ca-trust/extracted/* /layer/etc/pki/ca-trust/extracted/" in ddi_element
    assert "tls-ca-bundle.pem" in ddi_element
    assert "ln -sf /dev/null /layer/etc/systemd/system/systemd-firstboot.service" in ddi_element
    assert "ln -sf /dev/null /layer/etc/systemd/system/systemd-homed-firstboot.service" in ddi_element
    justfile = JUSTFILE.read_text(encoding="utf-8")
    assert "systemd.mask=systemd-homed-firstboot.service" in justfile
    assert "hostfwd=tcp:127.0.0.1:2222-:22" in justfile
    assert "systemd.wants=sshd.service" in justfile
    assert "ssh.authorized_keys.root=" in justfile
    assert "find dist/ -maxdepth 1 -type f -name 'bluefin-server-installer-*.raw.zst'" in justfile
    assert 'if [ "$ROOT_CODE" = "200" ]; then' in justfile
    assert '[ "$ROOT_CODE" = "503" ]' not in justfile
    assert "ln -sf /dev/null /layer/etc/systemd/system/audit-rules.service" in ddi_element
    assert "printf '127.0.0.1   localhost" in ddi_element
    assert "> /layer/etc/hosts" in ddi_element


def test_target_initramfs_preloads_sysext_filesystem_drivers() -> None:
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")

    assert (
        '--add-drivers "virtio virtio_blk virtio_pci virtio_scsi nvme nvme_core xfs erofs overlay zfs spl"'
        in installer_element
    )


def test_installer_loads_storage_drivers_and_settles_udev() -> None:
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")

    assert "modprobe -q nvme || true" in installer_element
    assert "modprobe -q nvme_core || true" in installer_element
    assert "modprobe -q usb-storage || true" in installer_element
    assert "modprobe -q uas || true" in installer_element
    assert "udevadm settle --timeout=15 || true" in installer_element
    assert "After=systemd-udev-settle.service" in installer_element
    assert "Wants=systemd-udev-settle.service" in installer_element

def test_interactive_installer_uses_local_virtual_console() -> None:
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")

    assert "TTYPath=/dev/tty0" in installer_element


def test_installer_and_ddi_strip_vmlinux_and_static_archives() -> None:
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")
    ddi_element = DDI_ELEMENT.read_text(encoding="utf-8")

    assert 'rm -f "/layer/usr/lib/modules/${KVER}/vmlinux"' in installer_element
    assert "find /layer -type f -name '*.a' -delete" in installer_element
    assert 'rm -f "/layer/usr/lib/modules/${KVER}/vmlinux"' in ddi_element
    assert "find /layer -type f -name '*.a' -delete" in ddi_element


def test_installer_medium_does_not_ship_an_unexecutable_fallback_image() -> None:
    """EFI/BOOT/BOOTX64.EFI must be a loader, not a whole live environment.

    The installer medium previously shipped a single UKI built with
    ``ukify build --linux --initrd``. With a ~382 MiB initrd that produced a
    434 MiB PE, and firmware loads it but never executes it. Measured against
    one OVMF build, one ESP and one QEMU invocation, varying only the image:

        SizeOfImage 0x020D1000 ( 34 MiB)  kernel boots
        SizeOfImage 0x03CCA000 ( 64 MiB)  kernel boots
        SizeOfImage 0x19E6D000 (434 MiB)  hangs after EntryPoint

    All three share ImageBase 0x14DF90000, so size is the variable. OVMF logs
    ``Loading driver at 0x0014DF90000 EntryPoint=0x0014DFA03C0`` and then goes
    silent; an attached target disk stays byte-identical.

    No other test can catch this. test-installer-artifact and the CI
    installer-test both boot the installer with ``-kernel``/``-initrd``, so the
    ESP is never executed and the medium's boot path is never exercised.
    """
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")

    assert "systemd-bootx64.efi" in installer_element, (
        "the medium must boot via systemd-boot, which reads the kernel and "
        "initrd as ordinary files rather than embedding them in a PE"
    )
    assert "/layer/boot/efi/loader/entries/bluefin-installer.conf" in installer_element, (
        "systemd-boot needs a type-1 loader entry naming the kernel and initrd"
    )
    assert "/layer/boot/efi/bluefin/initrd" in installer_element, (
        "the initrd must be a plain file on the ESP, not a PE section"
    )

    # The build must refuse to ship an oversized fallback image rather than
    # producing another medium that loads and never runs.
    # Which systemd-boot ships must be deterministic. `find / -name
    # systemd-bootx64.efi -print -quit` matches either the installer rootfs at
    # /layer or the target rootfs staged at /target-root, and takes whichever
    # the traversal reaches first — so the medium's bootloader would vary
    # between builds for no visible reason.
    assert "/layer/usr/lib/systemd/boot/efi/systemd-bootx64.efi" in installer_element, (
        "name the installer's own systemd-boot explicitly rather than searching"
    )
    # Scan effective lines only: the element's own comment names the wrong
    # spelling in order to warn against it, and matching that would flag the
    # warning as the defect.
    effective = "\n".join(
        line
        for line in installer_element.splitlines()
        if not line.lstrip().startswith("#")
    )
    assert not re.search(r"find / -name '?systemd-bootx64", effective), (
        "an unbounded find can pick the target rootfs copy instead of the "
        "installer's, making the shipped bootloader nondeterministic"
    )

    assert "BOOT_BYTES" in installer_element and "16777216" in installer_element, (
        "the build must fail when EFI/BOOT/BOOTX64.EFI exceeds a loader-sized "
        "ceiling; a 434 MiB image reached real hardware because nothing checked"
    )


def test_no_ukify_writes_to_the_media_fallback_path() -> None:
    """The regression, stated directly.

    The target OS keeps its UKI — at 64 MiB it boots, and systemd-sysupdate is
    built around replacing one. Only the *medium's* fallback path must not be a
    UKI carrying the live environment.
    """
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")

    assert not re.search(
        r"ukify build[^#]*?--output=/layer/boot/efi/EFI/BOOT/BOOTX64\.EFI",
        installer_element,
        flags=re.DOTALL,
    ), (
        "ukify must not write the medium's fallback image: with the installer "
        "initrd embedded it produces a 434 MiB PE that firmware cannot execute"
    )
