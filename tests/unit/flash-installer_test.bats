#!/usr/bin/env bats
#
# Unit tests for the `flash-installer` recipe in the top-level Justfile.
#
# `flash-installer` is the only recipe in the repository that destroys data: it
# pipes an exported installer image straight onto a block device with `dd`.
# Its seven guards — device argument required, target must not be the disk
# backing the running system, target must have nothing mounted off it, target
# must be a block device, exactly one exported image must exist, and the
# operator must confirm — are the only thing standing between a typo and a
# wiped disk.
#
# The recipe is never run against a real device. Each test runs `just` inside a
# private sandbox directory holding a copy of the Justfile, and `sudo`, `dd`,
# `zstd` and `lsblk` are replaced by logging stubs on PATH, so the write path
# records its arguments instead of performing them.
#
# Only one edit is applied to the copied Justfile: the block-device guard
# `[ ! -b ... ]` becomes `[ ! -e ... ]`, because an unprivileged test cannot
# create a device node (mknod is refused inside a user namespace). The fake
# device is a regular file instead. `test_block_device_guard_shape` asserts
# that the substitution matched exactly once, so if the guard is ever reworded
# or dropped the suite fails loudly rather than silently testing nothing.
#
# `lsblk` and `findmnt` are scriptable stubs: the guards added for the
# running-system and mounted-partition checks read them, so each test drives
# them through STUB_* environment variables rather than depending on whatever
# the host's real block topology happens to be.

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

    make_stub sudo 0
    make_stub dd 0
    make_stub zstd 0
    make_topology_stubs

    # Default topology: target is an unrelated, unmounted disk. Individual
    # tests override these to drive a specific guard.
    export STUB_ROOT_SRC="composefs:0000"
    export STUB_SYSROOT_SRC="/dev/nvme0n1p2"
    export STUB_PKNAME="nvme0n1"
    export STUB_TARGET_KNAME="sdz"
    export STUB_MOUNTPOINTS=""
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

# Scriptable `lsblk` and `findmnt`.
#
# The running-system and mounted-partition guards query real block topology, so
# a fixed stub would either always fire or never fire depending on the host.
# These answer from STUB_* variables, letting each test state the topology it
# is testing. Both still log, so assert_nothing_written stays meaningful.
make_topology_stubs() {
    cat > "${STUB_DIR}/lsblk" <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "${LOG}"
case " \$* " in
    *" KNAME "*)        printf '%s\n' "\${STUB_TARGET_KNAME:-}" ;;
    *" PKNAME "*)       printf '%s\n' "\${STUB_PKNAME:-}" ;;
    *MOUNTPOINTS*)      printf '%s\n' "\${STUB_MOUNTPOINTS:-}" ;;
esac
exit 0
EOF
    chmod +x "${STUB_DIR}/lsblk"

    cat > "${STUB_DIR}/findmnt" <<EOF
#!/usr/bin/env bash
echo "findmnt \$*" >> "${LOG}"
case " \$* " in
    *" /sysroot "*)     printf '%s\n' "\${STUB_SYSROOT_SRC:-}" ;;
    *" / "*)            printf '%s\n' "\${STUB_ROOT_SRC:-}" ;;
esac
exit 0
EOF
    chmod +x "${STUB_DIR}/findmnt"
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
    grep -qF 'dd of={{DEVICE}}' "$JUSTFILE"
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

# --- guard: the target must not back the running system -------------------

@test "flash-installer refuses the disk the running system is installed on" {
    export STUB_TARGET_KNAME="nvme0n1"
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"disk backing the running system"* ]]
    assert_nothing_written
}

@test "flash-installer resolves the system disk through /sysroot when / is composefs" {
    # The regression this guard was rewritten for. On composefs/ostree hosts —
    # Bluefin itself — `findmnt -no SOURCE /` returns a composefs digest, not a
    # device. A guard that consults only / silently passes the root disk
    # through. The real device is mounted at /sysroot.
    export STUB_ROOT_SRC="composefs:99f5c50825f9ab07"
    export STUB_SYSROOT_SRC="/dev/nvme0n1p2"
    export STUB_TARGET_KNAME="nvme0n1"
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"/sysroot is on /dev/nvme0n1p2"* ]]
    assert_nothing_written
}

@test "flash-installer allows an unrelated disk while the system disk is known" {
    export STUB_TARGET_KNAME="sdb"
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "y"
    [ "$status" -eq 0 ]
    assert_log "of=${FAKE_DEV}"
}

# --- guard: the target must have nothing mounted off it -------------------

@test "flash-installer refuses a device with a mounted partition" {
    export STUB_MOUNTPOINTS="/run/media/jorge/bluefin-root"
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"has mounted partitions"* ]]
    assert_nothing_written
}

@test "flash-installer tells the operator how to unmount rather than just refusing" {
    export STUB_MOUNTPOINTS="/run/media/jorge/bluefin-root"
    seed_image "bluefin-server-installer-1.0.raw.zst"
    run_flash "$FAKE_DEV" "y"
    [[ "$output" == *"Unmount them first"* ]]
}

# --- guard: exactly one exported image ------------------------------------

@test "flash-installer refuses to guess between two exported installers" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    seed_image "bluefin-server-installer-2.0.raw.zst"
    run_flash "$FAKE_DEV" "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to guess"* ]]
    assert_nothing_written
}

@test "flash-installer names both candidates so the operator can remove one" {
    seed_image "bluefin-server-installer-1.0.raw.zst"
    seed_image "bluefin-server-installer-2.0.raw.zst"
    run_flash "$FAKE_DEV" "y"
    [[ "$output" == *"bluefin-server-installer-1.0.raw.zst"* ]]
    [[ "$output" == *"bluefin-server-installer-2.0.raw.zst"* ]]
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
    assert_log "of=${FAKE_DEV}"
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
