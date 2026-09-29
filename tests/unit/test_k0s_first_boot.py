"""Contracts for retry-safe k0s sysext first-boot activation."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVICE = (
    ROOT / "files" / "os" / "systemd" / "system" / "k0s-first-boot.service"
)
FETCH_SERVICE = (
    ROOT
    / "files"
    / "os"
    / "systemd"
    / "system"
    / "k0s-first-boot-fetch.service"
)
PRESET = (
    ROOT
    / "files"
    / "os"
    / "systemd"
    / "system-preset"
    / "80-bluefin-k0s-first-boot.preset"
)
NETWORK = ROOT / "files" / "os" / "systemd" / "network" / "20-wired.network"
NETWORK_PRESET = (
    ROOT
    / "files"
    / "os"
    / "systemd"
    / "system-preset"
    / "80-bluefin-networkd.preset"
)
ELEMENT = ROOT / "elements" / "bluefin-server" / "os-k0s-first-boot.bst"
NETWORK_ELEMENT = ROOT / "elements" / "bluefin-server" / "os-networkd.bst"
K0S_UPDATE_ELEMENT = (
    ROOT / "elements" / "bluefin-server" / "os-k0s-sysupdate.bst"
)
STACK = ROOT / "elements" / "bluefin-server" / "os-stack.bst"


def test_seeded_install_skips_the_network_fetch() -> None:
    assert FETCH_SERVICE.is_file(), "the conditional k0s fetch unit is missing"
    fetch_service = FETCH_SERVICE.read_text(encoding="utf-8")
    first_boot = SERVICE.read_text(encoding="utf-8")

    assert "ConditionPathExists=!/var/lib/k0s/k0s.raw" in fetch_service
    assert (
        "ExecStart=/usr/bin/systemd-sysupdate --component=k0s update"
        in fetch_service
    )
    assert "systemd-sysupdate" not in first_boot


def test_missing_seed_fetches_before_activation_without_blocking_activation_retry() -> None:
    assert FETCH_SERVICE.is_file(), "the conditional k0s fetch unit is missing"
    fetch_service = FETCH_SERVICE.read_text(encoding="utf-8")
    first_boot = SERVICE.read_text(encoding="utf-8")

    assert "Type=oneshot" in fetch_service
    assert "Restart=on-failure" in fetch_service
    assert "ConditionPathExists=!/var/lib/k0s/k0s.raw" in fetch_service
    assert "Before=k0s-first-boot.service" in fetch_service
    assert "Wants=k0s-first-boot-fetch.service" in first_boot
    assert "Requires=k0s-first-boot-fetch.service" not in first_boot
    assert "After=k0s-first-boot-fetch.service" in first_boot
    assert (
        "ExecStartPre=/usr/bin/test -e /var/lib/k0s/k0s.raw"
        in first_boot
    )
    assert (
        "ExecStart=/usr/bin/install -D -m 0644 "
        "/var/lib/k0s/k0s.raw /run/extensions/k0s.raw"
    ) in first_boot
    assert "ExecStart=/usr/bin/systemd-sysext refresh" in first_boot


def test_k0s_first_boot_retries_until_controller_starts() -> None:
    service = SERVICE.read_text(encoding="utf-8")

    assert "ConditionPathExists=" not in service
    assert "Wants=network-online.target" in service
    assert "After=network-online.target" in service
    assert "Before=multi-user.target" not in service
    assert "Type=oneshot" in service
    assert "StateDirectory=k0s" in service
    assert "Restart=on-failure" in service
    assert (
        "ExecStart=/usr/bin/systemd-sysupdate --component=k0s update"
        not in service
    )
    assert "ExecStart=/usr/bin/systemd-sysupdate update" not in service
    assert "ExecStart=/usr/bin/systemctl enable --now systemd-sysext.service" not in service
    assert "ExecStart=/usr/bin/systemd-sysext refresh" in service
    assert "kubeflex" not in service, "the KubeStellar sysext seeds its own state"
    assert "ExecStart=/usr/bin/systemctl daemon-reload" in service
    assert "systemctl enable --now k0scontroller.service" in service
    assert "[ -s /etc/k0s/token ]" in service and "k0sworker.service" in service
    assert (
        "ExecStartPost=/usr/bin/touch /var/lib/k0s/.first-boot-complete"
        not in service
    )
    assert "ConditionFirstBoot" not in service


def test_k0s_first_boot_is_packaged_but_opt_in() -> None:
    assert not PRESET.exists(), "k0s is opt-in: no preset may enable k0s-first-boot"
    opt_in = PRESET.parent / "80-bluefin-opt-in.preset"
    lines = opt_in.read_text(encoding="utf-8").splitlines()
    assert "disable k0s-first-boot.service" in lines, (
        "FSDK has no 'disable *' default, so the unit must be disabled explicitly"
    )
    assert "path: files/os/systemd/system" in ELEMENT.read_text(encoding="utf-8")
    assert "target: /usr/lib/systemd/system" in ELEMENT.read_text(encoding="utf-8")
    assert (
        "bluefin-server/os-k0s-first-boot.bst"
        in STACK.read_text(encoding="utf-8")
    )


def test_installed_os_configures_wired_dhcp_with_networkd() -> None:
    assert NETWORK.read_text(encoding="utf-8") == (
        "[Match]\n"
        "Name=e*\n"
        "\n"
        "[Network]\n"
        "DHCP=ipv4\n"
    )
    assert NETWORK_PRESET.read_text(encoding="utf-8") == (
        "enable systemd-networkd.service\n"
    )
    network_element = NETWORK_ELEMENT.read_text(encoding="utf-8")
    assert "path: files/os/systemd/network" in network_element
    assert "target: /usr/lib/systemd/network" in network_element
    assert "bluefin-server/os-networkd.bst" in STACK.read_text(encoding="utf-8")


def test_k0s_sysupdate_transfer_is_packaged_as_a_component() -> None:
    element = K0S_UPDATE_ELEMENT.read_text(encoding="utf-8")
    assert "path: files/os/sysupdate.k0s.d" in element
    assert "target: /usr/lib/sysupdate.k0s.d" in element
    assert (
        "bluefin-server/os-k0s-sysupdate.bst"
        in STACK.read_text(encoding="utf-8")
    )


def test_presets_sort_between_ignition_and_fsdk_defaults() -> None:
    # systemd reads preset files from every directory in filename order and
    # the first matching line wins. Ignition enables units through
    # /etc/systemd/system-preset/20-ignition.preset, so a vendor preset that
    # sorts before it (e.g. 20-bluefin-sshd.preset: "disable sshd.service")
    # silently overrides a node config's `enabled: true`. Vendor presets must
    # still sort before FSDK's 90-systemd.preset to take effect at all.
    preset_dir = PRESET.parent
    presets = sorted(p.name for p in preset_dir.glob("*.preset"))
    assert presets, f"no presets found in {preset_dir}"
    for name in presets:
        assert "20-ignition.preset" < name < "90-systemd.preset", (
            f"{name} must sort after 20-ignition.preset (so Ignition can "
            "enable units Bluefin disables) and before 90-systemd.preset"
        )


def test_etc_resolv_conf_symlink_is_seeded_for_kubelet() -> None:
    # FSDK 26.08 ships no /etc/resolv.conf rule (upstream systemd leaves the
    # symlink to the distro), and this DDI boots with an empty /etc, so
    # without an explicit tmpfiles.d rule the symlink never exists and
    # kubelet fails every pod sandbox with
    # "open /etc/resolv.conf: no such file or directory".
    conf = (
        ROOT / "files" / "os" / "tmpfiles.d" / "20-bluefin-resolv.conf"
    )
    assert conf.is_file(), "resolv.conf tmpfiles rule is missing"
    lines = [
        line
        for line in conf.read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    ]
    assert lines == [
        "L /etc/resolv.conf - - - - ../run/systemd/resolve/resolv.conf"
    ]

    element = (
        ROOT / "elements" / "bluefin-server" / "os-resolv-conf.bst"
    ).read_text(encoding="utf-8")
    assert "path: files/os/tmpfiles.d" in element
    assert "target: /usr/lib/tmpfiles.d" in element
    assert (
        "bluefin-server/os-resolv-conf.bst" in STACK.read_text(encoding="utf-8")
    )
