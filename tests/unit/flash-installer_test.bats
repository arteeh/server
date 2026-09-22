#!/usr/bin/env bats
#
# Unit tests for the `flash-installer` recipe in the top-level Justfile.
#
# `flash-installer` is the only recipe in the repository that destroys data: it
# pipes an exported installer image straight onto a block device with `dd`.
# Its guards (device argument required, device must be a block device, the
# device must not back the running system, nothing may be mounted off it,
# exactly one exported image must exist, the image must pass `zstd -t`, the
# operator must confirm, and the write must survive a sha256 readback plus a
# partition-table and PARTLABEL check) are the only thing standing between a
# typo and a wiped disk, and none of them were exercised.
#
# The recipe is never run against a real device. Each test runs `just` inside a
# private sandbox directory holding a copy of the Justfile, and `dd`, `zstd`,
# `lsblk`, `blockdev`, `sfdisk`, `partprobe` and `udevadm` are replaced by
# stubs on PATH that log their arguments and return a scripted exit status
# instead of touching a device. The `sudo` stub logs its arguments and then
# executes them, so privileged steps land on those same stubs.
#
# Only one edit is applied to the copied Justfile: the block-device guard
# `[ ! -b ... ]` becomes `[ ! -e ... ]`, because an unprivileged test cannot
# create a device node (mknod is refused inside a user namespace). The fake
# device is a regular file instead. `test_block_device_guard_shape` asserts
# that the substitution matched exactly once, so if the guard is ever reworded
# or dropped the suite fails loudly rather than silently testing nothing.

setup() {
    if ! command -v just >/dev/null 2>&1; then
        skip "just is not installed"
    fi

    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    JUSTFILE="${REPO_ROOT}/Justfile"
    SANDBOX="${BATS_TEST_TMPDIR}/sandbox"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    LOG="${BATS_TEST_TMPDIR}/calls.log"
    FAKE_DEV="${BATS_TEST_TMPDIR}/fake-block-device"

    mkdir -p "$STUB_DIR" "$SANDBOX/dist"
    : > "$LOG"
    : > "$FAKE_DEV"

    # The recipe reads no repository state other than dist/, but the Justfile's
    # top-level backtick assignments inspect elements/freedesktop-sdk.bst. Copy
    # it so loading the sandbox Justfile behaves exactly like the real one.
    mkdir -p "${SANDBOX}/elements"
    cp "${REPO_ROOT}/elements/freedesktop-sdk.bst" "${SANDBOX}/elements/"

    sed 's/\[ ! -b /[ ! -e /' "$JUSTFILE" > "${SANDBOX}/Justfile"
    cat > "${STUB_DIR}/sudo" <<EOF
#!/usr/bin/env bash
echo "sudo \$*" >> "${LOG}"
"\${@}"
EOF
    chmod +x "${STUB_DIR}/sudo"
    make_dd_stub 0
    make_zstd_stub 0 0
    make_blockdev_stub 0 0
    make_stub partprobe 0
    make_stub udevadm 0
    make_sfdisk_stub 0 0
    make_lsblk_stub "bluefin-installer-data"
}
# make_stub <name> <exit-code>
#
# Records the invocation in $LOG and exits with the requested status without
# doing any of the real work.
make_stub() {
    cat > "${STUB_DIR}/$1" <<EOF
#!/usr/bin/env bash
echo "$1 \$*" >> "${LOG}"
exit $2
EOF
    chmod +x "${STUB_DIR}/$1"
}

make_blockdev_stub() {
    local flushbufs_exit="${1:-0}"
    local rereadpt_exit="${2:-0}"
    cat > "${STUB_DIR}/blockdev" <<EOF
#!/usr/bin/env bash
echo "blockdev \$*" >> "\${LOG}"
if [[ " \$* " == *"--flushbufs"* ]]; then
    exit ${flushbufs_exit}
fi
if [[ " \$* " == *"--rereadpt"* ]]; then
    exit ${rereadpt_exit}
fi
exit 0
EOF
    chmod +x "${STUB_DIR}/blockdev"
}

make_sfdisk_stub() {
    local relocate_exit="${1:-0}"
    local verify_exit="${2:-0}"
    cat > "${STUB_DIR}/sfdisk" <<EOF
#!/usr/bin/env bash
echo "sfdisk \$*" >> "\${LOG}"
if [[ " \$* " == *"--relocate"* ]]; then
    exit ${relocate_exit}
fi
if [[ " \$* " == *"--verify"* ]]; then
    exit ${verify_exit}
fi
exit 0
EOF
    chmod +x "${STUB_DIR}/sfdisk"
}

make_zstd_stub() {
    local test_exit="${1:-0}"
    local decompress_exit="${2:-0}"
    cat > "${STUB_DIR}/zstd" <<EOF
#!/usr/bin/env bash
if [ -n "\${LOG:-}" ]; then
    echo "zstd \$*" >> "\${LOG}"
fi
if [[ " \$* " == *"-t "* ]]; then
    exit ${test_exit}
fi
if [[ " \$* " == *"-dc "* ]]; then
    if [ "${decompress_exit}" -ne 0 ]; then
        exit ${decompress_exit}
    fi
    printf 'dummy-decompressed-payload\n'
    exit 0
fi
exit 0
EOF
    chmod +x "${STUB_DIR}/zstd"
}

make_dd_stub() {
    local mismatch="${1:-0}"
    cat > "${STUB_DIR}/dd" <<EOF
#!/usr/bin/env bash
if [ -n "\${LOG:-}" ]; then
    echo "dd \$*" >> "\${LOG}"
fi
if [[ " \$* " == *"of="* ]]; then
    cat > /dev/null
fi
if [[ " \$* " == *"if="* ]]; then
    if [ "${mismatch}" -ne 0 ]; then
        printf 'corrupted-readback\n'
    else
        printf 'dummy-decompressed-payload\n'
    fi
fi
EOF
    chmod +x "${STUB_DIR}/dd"
}
make_lsblk_stub() {
    local label="${1:-}"
    cat > "${STUB_DIR}/lsblk" <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "${LOG}"
if [[ " \$* " == *" -o PARTLABEL "* ]]; then
    echo "${label}"
fi
exit 0
EOF
    chmod +x "${STUB_DIR}/lsblk"
}

# seed_image <filename>
#
# Places an exported installer artefact where the recipe looks for it.
seed_image() {
    : > "${SANDBOX}/dist/$1"
}

# run_flash <device> [confirm-answer]
run_flash() {
    local device="$1"
    local answer="${2:-}"
    run env PATH="${STUB_DIR}:${PATH}" \
        just --justfile "${SANDBOX}/Justfile" \
             --working-directory "${SANDBOX}" \
             flash-installer "${device}" <<<"${answer}"
}

# Nothing may reach the disk in any of the refusal paths.
assert_nothing_written() {
    refute_log "sudo "
    refute_log "dd "
    refute_log "zstd "
}

assert_log() {
    if ! grep -qF -- "$1" "$LOG"; then
        echo "expected call log to contain: $1" >&2
        cat "$LOG" >&2
        return 1
    fi
}

refute_log() {
    if grep -qF -- "$1" "$LOG"; then
        echo "expected call log NOT to contain: $1" >&2
        cat "$LOG" >&2
        return 1
    fi
}

# --- guard: the substitution the sandbox relies on ------------------------

@test "the recipe still guards on -b so the sandbox substitution is honest" {
    run grep -cF '[ ! -b "{{DEVICE}}" ]' "$JUSTFILE"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "the recipe still writes through dd so the stubs intercept the real path" {
    grep -qF 'zstd -dc "$1" | dd of="$2"' "$JUSTFILE"
}

# --- guard 1: device argument is mandatory --------------------------------

@test "flash-installer with no device refuses and writes nothing" {
    run_flash ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"Must specify a target block device"* ]]
    assert_nothing_written
}

@test "flash-installer with no device lists candidate disks to help the operator" {
    run_flash ""
    [[ "$output" == *"Available writable disk devices"* ]]
    assert_log "lsblk "
}

# --- guard 2: the target must be a block device ---------------------------

@test "flash-installer rejects a path that is not a block device" {
    run_flash "${BATS_TEST_TMPDIR}/not-a-device"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a valid block device"* ]]
    assert_nothing_written
}

# --- guard 3: an exported image must exist --------------------------------

@test "flash-installer refuses when dist/ holds no exported installer" {
    run_flash "$FAKE_DEV"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No exported installer found"* ]]
    [[ "$output" == *"just build-installer && just export-installer"* ]]
    assert_nothing_written
}

@test "flash-installer ignores dist/ artefacts that are not installer images" {
    seed_image "bluefin-server-ddi-1.0.raw"
    seed_image "checksums.txt"
    run_flash "$FAKE_DEV"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No exported installer found"* ]]
    assert_nothing_written
}

# --- guard 4: interactive confirmation ------------------------------------

@test "flash-installer aborts when the operator declines" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "n"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Aborted."* ]]
    assert_nothing_written
}

@test "flash-installer aborts on an empty answer" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"Aborted."* ]]
    assert_nothing_written
}

@test "flash-installer aborts on an answer that merely starts with a vowel" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "yolo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Aborted."* ]]
    assert_nothing_written
}

@test "flash-installer warns that the target will be destroyed before asking" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "n"
    [[ "$output" == *"COMPLETELY DESTROYED"* ]]
    assert_log "lsblk "
}

@test "flash-installer proceeds on a bare y" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "y"
    [ "$status" -eq 0 ]
    assert_log "sudo "
}

@test "flash-installer proceeds on an uppercase Y" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "Y"
    [ "$status" -eq 0 ]
    assert_log "sudo "
}

@test "flash-installer proceeds on yes" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "yes"
    [ "$status" -eq 0 ]
    assert_log "sudo "
}

# --- the write itself -----------------------------------------------------

@test "flash-installer decompresses the discovered image onto the given device" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "y"
    [ "$status" -eq 0 ]
    assert_log "dist/bluefin-server-installer-1.0.raw.zst"
    # The image and the device are passed as positional arguments to the root
    # shell, never interpolated into the script it runs.
    assert_log "conv=fsync bash dist/bluefin-server-installer-1.0.raw.zst ${FAKE_DEV}"
}

@test "flash-installer never interpolates the image path into the root shell script" {
    grep -qF "zstd -dc \"\$1\"" "$JUSTFILE"
    ! grep -qF "zstd -dc '\${IMG}'" "$JUSTFILE"
}

@test "flash-installer refuses when dist/ holds more than one installer image" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    seed_image "bluefin-server-installer-2.0.raw.zst"
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"installer images in dist/; refusing to guess"* ]]
    assert_nothing_written
}

@test "flash-installer writes with the flags that make the image bootable" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "y"
    assert_log "bs=4M"
    assert_log "iflag=fullblock"
    assert_log "oflag=direct"
    assert_log "conv=fsync"
}

@test "flash-installer reports success only after the write is attempted" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "y"
    [[ "$output" == *"Successfully flashed"* ]]
}

@test "flash-installer finds only top-level dist artefacts and verifies partlabel" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    mkdir -p "${SANDBOX}/dist/nested"
    : > "${SANDBOX}/dist/nested/bluefin-server-installer-9.9.raw.zst"
    run_flash "$FAKE_DEV" "y"
    [ "$status" -eq 0 ]
    assert_log "dist/bluefin-server-installer-1.0.raw.zst"
    refute_log "nested"
    assert_log "blockdev --rereadpt ${FAKE_DEV}"
    assert_log "udevadm trigger --subsystem-match=block"
    assert_log "udevadm settle --timeout=10"
    [[ "$output" == *"Verifying partition table"* ]]
    [[ "$output" == *"Verified: 'bluefin-installer-data'"* ]]
    [[ "$output" == *"Successfully flashed"* ]]
}

@test "flash-installer fails with error and no success message when bluefin-installer-data is absent" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    make_lsblk_stub ""
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Verifying partition table"* ]]
    [[ "$output" == *"ERROR: 'bluefin-installer-data' partition label not detected"* ]]
    [[ "$output" != *"Successfully flashed"* ]]
}

@test "flash-installer fails with error when both blockdev --rereadpt and partprobe fail" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    make_blockdev_stub 0 1
    make_stub partprobe 1
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: Failed to reread partition table"* ]]
    [[ "$output" != *"Successfully flashed"* ]]
}

@test "flash-installer fails with error when blockdev --flushbufs fails" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    make_blockdev_stub 1 0
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" != *"Successfully flashed"* ]]
}

@test "flash-installer fails with error when sfdisk --verify fails" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    make_sfdisk_stub 0 1
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" != *"Successfully flashed"* ]]
}

@test "flash-installer fails with error when zstd -dc fails in write pipeline despite passing zstd -t" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    make_zstd_stub 0 1
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" != *"Successfully flashed"* ]]
}

@test "flash-installer fails with error when readback bytes hash differently" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    make_dd_stub 1
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not contain what was written"* ]]
    [[ "$output" != *"Successfully flashed"* ]]
}

# --- guard: the device must not back the running system -------------------

@test "flash-installer refuses a device backing a btrfs root with a subvolume source" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    cat > "${STUB_DIR}/findmnt" <<EOF
#!/usr/bin/env bash
echo "findmnt \$*" >> "${LOG}"
if [[ " \$* " == *" / "* ]]; then
    echo "/dev/sda2[/root]"
fi
exit 0
EOF
    chmod +x "${STUB_DIR}/findmnt"
    cat > "${STUB_DIR}/lsblk" <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "${LOG}"
if [[ "\$*" == "-no KNAME ${FAKE_DEV}" ]]; then
    echo "sda"
fi
# Only an unbracketed device node resolves; /dev/sda2[/root] must not.
if [[ "\$*" == "-no PKNAME /dev/sda2" ]]; then
    echo "sda"
fi
exit 0
EOF
    chmod +x "${STUB_DIR}/lsblk"
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is the disk backing the running system"* ]]
    assert_log "lsblk -no PKNAME /dev/sda2"
    assert_nothing_written
}

@test "flash-installer refuses a partition on the disk backing the running system" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    cat > "${STUB_DIR}/findmnt" <<EOF
#!/usr/bin/env bash
echo "findmnt \$*" >> "${LOG}"
if [[ " \$* " == *" / "* ]]; then
    echo "/dev/sda2"
fi
exit 0
EOF
    chmod +x "${STUB_DIR}/findmnt"
    # The target is a partition node: its KNAME is sda3, which never matches
    # the sda that / resolves to. Only resolving the target to its parent disk
    # catches this.
    cat > "${STUB_DIR}/lsblk" <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "${LOG}"
if [[ "\$*" == "-no PKNAME ${FAKE_DEV}" ]]; then
    echo "sda"
fi
if [[ "\$*" == "-no KNAME ${FAKE_DEV}" ]]; then
    echo "sda3"
fi
if [[ "\$*" == "-no PKNAME /dev/sda2" ]]; then
    echo "sda"
fi
exit 0
EOF
    chmod +x "${STUB_DIR}/lsblk"
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is the disk backing the running system"* ]]
    assert_log "lsblk -no PKNAME ${FAKE_DEV}"
    assert_nothing_written
}

# --- guard: nothing may be mounted off the device -------------------------

# make_mount_lsblk_stub <mountpoints-exit> <mountpoint-exit> <mount-output>
#
# Models lsblk versions with and without the MOUNTPOINTS column (util-linux
# >= 2.37) so the fallback and the fail-closed path can both be exercised.
make_mount_lsblk_stub() {
    local mountpoints_exit="$1" mountpoint_exit="$2" mount_output="${3:-}"
    cat > "${STUB_DIR}/lsblk" <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "${LOG}"
if [[ " \$* " == *" -o MOUNTPOINTS "* ]]; then
    [ ${mountpoints_exit} -ne 0 ] && exit ${mountpoints_exit}
    echo "${mount_output}"
    exit 0
fi
if [[ " \$* " == *" -o MOUNTPOINT "* ]]; then
    [ ${mountpoint_exit} -ne 0 ] && exit ${mountpoint_exit}
    echo "${mount_output}"
    exit 0
fi
exit 0
EOF
    chmod +x "${STUB_DIR}/lsblk"
}

@test "flash-installer falls back to MOUNTPOINT when lsblk predates MOUNTPOINTS" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    make_mount_lsblk_stub 1 0 "/run/media/operator/usb"
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"has mounted partitions"* ]]
    assert_log "lsblk -n -o MOUNTPOINT ${FAKE_DEV}"
    assert_nothing_written
}

@test "flash-installer refuses when the mount state cannot be read at all" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    make_mount_lsblk_stub 1 1 ""
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not read the mount state"* ]]
    assert_nothing_written
}
