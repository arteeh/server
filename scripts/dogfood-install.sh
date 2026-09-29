#!/usr/bin/env bash
# End-to-end A/B check in QEMU with Secure Boot:
#   1. boot <dir> diskless and run systemd-sysinstall onto a blank disk
#   2. boot the installed disk (usr slot A, persistent root)
#   3. with <next-dir>: systemd-sysupdate to that version over HTTP, reboot,
#      and confirm the node runs it from slot B with a boot-counted UKI
#   4. with <broken-dir>: update to it, corrupt its slot, and confirm boot
#      counting rolls the node back to <next-dir> on its own
# The updates verify the signed SHA256SUMS and have the optional "zfs"
# sysupdate feature enabled, so the ZFS sysext follows the OS in lock-step
# and must still be active after the rollback.
# Usage: dogfood-install.sh <dir> [<next-dir> [<broken-dir>]]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dir="$(realpath "${1:?usage: $0 <dir> [<next-dir>]}")"
next="${2:+$(realpath "$2")}"
broken="${3:+$(realpath "$3")}"
state="$(realpath "${DOGFOOD_STATE:-dist/dogfood-install}")"
rm -rf "${state}"
mkdir -p "${state}"
truncate -s 16G "${state}/disk.raw"

export DOGFOOD_STATE_DISK="${state}/disk.raw"
export DOGFOOD_VARS="${state}/vars.fd"
run() { DOGFOOD_EXTRA_PROBE="$2" bash "${here}/dogfood-diskless.sh" "$1" --check; }

cat > "${state}/install.probe" <<'EOF'
systemctl start run-bluefin-boot.mount
kernel="$(ls /run/bluefin/boot/EFI/Linux/bluefin-server-[0-9]*.efi)"
rc=0
systemd-sysinstall --erase=yes --confirm=no --variables=yes --reboot=no \
    --definitions=/run/bluefin/boot/bluefin/repart.d \
    --kernel="${kernel}" /dev/vdb > /run/sysinstall.log 2>&1 || rc=$?
echo "PROBE install=${rc}"
tail -n 15 /run/sysinstall.log | sed 's/^/PROBE-LOG /'
lsblk -no NAME,PARTLABEL,SIZE /dev/vdb | sed 's/^/PROBE-LOG /'
EOF

cat > "${state}/disk.probe" <<'EOF'
echo "PROBE usr-part=$(lsblk -rsno PARTLABEL /dev/mapper/usr | grep bluefin_usr_ | tr '\n' ' ')"
echo "PROBE zfs=$(systemctl is-active zfs.target) $(ls /var/lib/extensions 2>/dev/null | tr '\n' ' ')"
echo "PROBE boot-entry=$(bootctl status 2>/dev/null | sed -n 's/^ *Current Entry: *//p' | head -n1)"
echo "PROBE firstboot-ran=$(systemctl show -P ConditionResult systemd-firstboot.service)"
bootctl list --no-pager 2>/dev/null | sed -n 's/^ *\(title\|id\): */PROBE-LOG \1 /p'
systemctl start boot-complete.target 2>/dev/null || true
echo "PROBE ukis=$(ls /boot/EFI/Linux 2>/dev/null | tr '\n' ' ')"
EOF

cat > "${state}/update.probe" <<'EOF'
mkdir -p /etc/sysupdate.d/zfs.feature.d
printf '[Feature]\nEnabled=true\n' > /etc/sysupdate.d/zfs.feature.d/enable.conf
for f in /usr/lib/sysupdate.d/*.transfer; do
    sed -e 's|^Path=https://.*|Path=http://10.0.2.2:8765/|' \
        "${f}" > "/etc/sysupdate.d/${f##*/}"
done
rc=0
systemd-sysupdate update > /run/sysupdate.log 2>&1 || rc=$?
echo "PROBE update=${rc}"
tail -n 15 /run/sysupdate.log | sed 's/^/PROBE-LOG /'
timeout 60 systemd-sysupdate list --no-pager 2>&1 | sed 's/^/PROBE-LOG /'
EOF

echo "==> 1/4 diskless boot + systemd-sysinstall"
run "${dir}" "${state}/install.probe" | tee "${state}/1-install.log"
grep -q 'PROBE install=0' "${state}/1-install.log"

echo "==> 2/4 boot the installed disk"
DOGFOOD_BOOT=disk run "${dir}" "${state}/disk.probe" | tee "${state}/2-disk.log"
grep -q 'PROBE root=xfs' "${state}/2-disk.log"

[ -n "${next}" ] || { echo "PASS: installed and booted from disk"; exit 0; }

echo "==> 3/4 systemd-sysupdate to $(basename "${next}")"
DOGFOOD_TIMEOUT="${DOGFOOD_UPDATE_TIMEOUT:-900}" DOGFOOD_BOOT=disk run "${next}" "${state}/update.probe" | tee "${state}/3-update.log"
grep -q 'PROBE update=0' "${state}/3-update.log"

echo "==> 4/4 boot the updated disk"
DOGFOOD_BOOT=disk run "${next}" "${state}/disk.probe" | tee "${state}/4-updated.log"
new_ver="$(ls "${next}"/bluefin-server-[0-9]*.efi | sed -n 's|.*/bluefin-server-\(.*\)\.efi$|\1|p')"
grep -q "PROBE os=bluefin-server ${new_ver}" "${state}/4-updated.log"
grep -q "PROBE zfs=active" "${state}/4-updated.log"
[ -n "${broken}" ] || { echo "PASS: installed, updated A->B and booted ${new_ver}"; exit 0; }

bad_ver="$(ls "${broken}"/bluefin-server-[0-9]*.efi | sed -n 's|.*/bluefin-server-\(.*\)\.efi$|\1|p')"
sed "s|^echo \"PROBE update=|dd if=/dev/urandom of=/dev/disk/by-partlabel/bluefin_usr_${bad_ver} bs=1M count=64 conv=fsync 2>/dev/null \&\& echo PROBE corrupted=${bad_ver}\necho \"PROBE update=|" \
    "${state}/update.probe" > "${state}/break.probe"

echo "==> 5/6 update to ${bad_ver} and corrupt its slot"
DOGFOOD_TIMEOUT="${DOGFOOD_UPDATE_TIMEOUT:-900}" DOGFOOD_BOOT=disk run "${broken}" "${state}/break.probe" | tee "${state}/5-break.log"
grep -q "PROBE corrupted=${bad_ver}" "${state}/5-break.log"

echo "==> 6/6 boot: ${bad_ver} must fail its tries and fall back to ${new_ver}"
DOGFOOD_TIMEOUT="${DOGFOOD_ROLLBACK_TIMEOUT:-1500}" DOGFOOD_BOOT=disk run "${broken}" "${state}/disk.probe" | tee "${state}/6-rollback.log"
grep -q "PROBE os=bluefin-server ${new_ver}" "${state}/6-rollback.log"
grep -q "bluefin-server-${bad_ver}+0-3.efi" "${state}/6-rollback.log"
grep -q "PROBE zfs=active" "${state}/6-rollback.log"
echo "PASS: installed, updated A->B, and rolled back from a broken ${bad_ver} to ${new_ver}"
