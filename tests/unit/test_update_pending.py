"""Executed coverage for bluefin-update-pending.

After a rollback systemd-sysupdate still reports the failed version as
pending; bluefin-update-pending says no while that version's UKI has no tries
left, so the kured flag and the nightly reboot do not bring the node back to
it. It runs here against a fake systemd-sysupdate.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
UNITS = ROOT / "files" / "os" / "systemd" / "system"
PENDING = ROOT / "files" / "os" / "update-check" / "usr" / "libexec" / "bluefin-update-pending"
BOOTED = "26.09.3"


def executable(path: Path, body: str) -> None:
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def test_pending_is_executable_bash() -> None:
    assert PENDING.read_text(encoding="utf-8").startswith("#!/usr/bin/bash\n")
    assert PENDING.stat().st_mode & stat.S_IXUSR
    subprocess.run(["bash", "-n", str(PENDING)], check=True)


def test_kured_flag_and_nightly_reboot_both_use_it() -> None:
    kured = (UNITS / "systemd-sysupdate.service.d" / "20-kured.conf").read_text(encoding="utf-8")
    interlock = (UNITS / "systemd-sysupdate-reboot.service.d" / "20-interlock.conf").read_text(encoding="utf-8")
    assert "if /usr/libexec/bluefin-update-pending; then touch /run/reboot-required; fi" in kured
    assert "systemd-sysupdate pending" not in kured
    assert "ExecCondition=/usr/libexec/bluefin-update-pending\n" in interlock


needs_analyze = pytest.mark.skipif(not shutil.which("systemd-analyze"), reason="needs systemd-analyze")


def pending(tmp_path: Path, *, sysupdate_pending: bool, ukis: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
    sysupdate = tmp_path / "systemd-sysupdate"
    executable(sysupdate, f'[ "$1" = pending ] && exit {0 if sysupdate_pending else 1}\nexit 99\n')
    boot = tmp_path / "boot"
    (boot / "EFI" / "Linux").mkdir(parents=True)
    for uki in ukis:
        (boot / "EFI" / "Linux" / uki).touch()
    os_release = tmp_path / "os-release"
    os_release.write_text(f'IMAGE_VERSION="{BOOTED}"\n', encoding="utf-8")
    env = dict(
        os.environ,
        BLUEFIN_SYSUPDATE=str(sysupdate),
        BLUEFIN_BOOT_PATH=str(boot),
        BLUEFIN_OS_RELEASE=str(os_release),
    )
    return subprocess.run([str(PENDING)], capture_output=True, text=True, env=env, timeout=30)


@needs_analyze
def test_pending_update_with_tries_left(tmp_path: Path) -> None:
    result = pending(tmp_path, sysupdate_pending=True, ukis=("bluefin-server-26.09.4+2-1.efi", "bluefin-server-26.09.3.efi"))
    assert result.returncode == 0, result.stdout + result.stderr


@needs_analyze
def test_nothing_pending(tmp_path: Path) -> None:
    result = pending(tmp_path, sysupdate_pending=False, ukis=("bluefin-server-26.09.3.efi",))
    assert result.returncode == 1, result.stdout + result.stderr


@needs_analyze
@pytest.mark.parametrize("uki", ["bluefin-server-26.09.4+0-3.efi", "bluefin-server-26.09.10+0.efi"])
def test_update_that_failed_its_tries_is_not_pending(tmp_path: Path, uki: str) -> None:
    # After the rollback systemd-sysupdate still reports it as pending.
    result = pending(tmp_path, sysupdate_pending=True, ukis=(uki, "bluefin-server-26.09.3.efi"))
    assert result.returncode == 1, result.stdout + result.stderr
    assert f"is installed but failed its boot tries ({uki}); staying on {BOOTED}" in result.stdout


@needs_analyze
def test_older_exhausted_uki_does_not_block_a_newer_update(tmp_path: Path) -> None:
    result = pending(
        tmp_path,
        sysupdate_pending=True,
        ukis=("bluefin-server-26.09.2+0-3.efi", "bluefin-server-26.09.3.efi", "bluefin-server-26.09.5+3-0.efi"),
    )
    assert result.returncode == 0, result.stdout + result.stderr
