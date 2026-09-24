"""Contracts for the seeded root credential and SSH login policy.

The shipped DDI seeds a well-known default root password for local console
bring-up only. This file pins the two safety contracts around it:

- the password is expired at first login (shadow last-change field 0, the
  `chage -d 0` equivalent), so every install is forced onto a per-install
  secret before any shell is granted; and
- the effective SSH policy never allows the seeded password (or any password)
  over the network.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DDI_ELEMENT = REPO_ROOT / "elements" / "oci" / "bluefin-server-ddi.bst"
SSHD_DROPIN = REPO_ROOT / "files" / "os" / "ssh" / "sshd_config.d" / "bluefin-server.conf"
ISSUE_FILE = REPO_ROOT / "files" / "os" / "issue.d" / "40-kubestellar.issue"


def _root_shadow_fields(ddi_element: str) -> list[str]:
    match = re.search(
        r"printf '(root:[^']*)", ddi_element
    )
    assert match, "DDI element must seed a root account into /etc/shadow"
    shadow_line = match.group(1).split("\\n")[0]
    fields = shadow_line.split(":")
    assert fields[0] == "root", "seeded shadow line must be the root account"
    assert len(fields) == 9, "seeded shadow line must have all 9 shadow fields"
    return fields


def test_root_password_is_expired_for_first_login_rotation() -> None:
    ddi_element = DDI_ELEMENT.read_text(encoding="utf-8")
    fields = _root_shadow_fields(ddi_element)

    # shadow field 2 is the last-change date: 0 means expired, so login
    # (console included) forces a password rotation before any shell.
    assert fields[2] == "0", (
        "seeded root password must be expired at first login (last-change 0); "
        "a fixed date leaves the well-known default usable indefinitely"
    )


def test_root_password_uses_no_fixed_build_date() -> None:
    ddi_element = DDI_ELEMENT.read_text(encoding="utf-8")
    fields = _root_shadow_fields(ddi_element)

    # Regression guard: a fixed last-change date (e.g. 19700) ships the same
    # usable credential in every image with no rotation enforced.
    assert fields[2] != "19700"


def test_sshd_dropin_never_permits_password_authentication() -> None:
    sshd = SSHD_DROPIN.read_text(encoding="utf-8")

    assert re.search(r"^PermitRootLogin\s+prohibit-password$", sshd, re.MULTILINE)
    assert re.search(r"^PasswordAuthentication\s+no$", sshd, re.MULTILINE)
    assert re.search(r"^KbdInteractiveAuthentication\s+no$", sshd, re.MULTILINE)
    assert not re.search(r"^PermitRootLogin\s+yes$", sshd, re.MULTILINE)
    assert not re.search(r"^PasswordAuthentication\s+yes$", sshd, re.MULTILINE)


def test_console_banner_discloses_forced_password_change() -> None:
    banner = ISSUE_FILE.read_text(encoding="utf-8")

    assert "Default login: root / bluefin" in banner
    assert "password change forced at first login" in banner
