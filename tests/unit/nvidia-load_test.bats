#!/usr/bin/env bats
#
# Unit tests for files/nvidia/sysext/nvidia-load (ExecStart= of
# nvidia-load.service in the NVIDIA driver sysexts).
#
# The helper runs against a fake /sys and /proc/driver/nvidia/gpus in
# BATS_TEST_TMPDIR. modprobe and bluefin-sysext-modules are logging stubs:
# the latter "binds" the GPUs listed in NVIDIA_STUB_BINDS by creating their
# /proc/driver/nvidia/gpus/<address> directories, as the real driver does.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SCRIPT="${REPO_ROOT}/files/nvidia/sysext/nvidia-load"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    LOG="${BATS_TEST_TMPDIR}/calls.log"
    SYSFS="${BATS_TEST_TMPDIR}/sys"
    GPUS="${BATS_TEST_TMPDIR}/proc/driver/nvidia/gpus"
    mkdir -p "${STUB_DIR}" "${SYSFS}/bus/pci/devices" "${SYSFS}/bus/pci/drivers/nouveau" "${GPUS}"
    : > "${LOG}"

    cat > "${STUB_DIR}/modprobe" <<EOF
#!/usr/bin/env bash
echo "modprobe \$*" >> "${LOG}"
exit \${MODPROBE_RC:-0}
EOF
    cat > "${STUB_DIR}/bluefin-sysext-modules" <<EOF
#!/usr/bin/env bash
echo "bluefin-sysext-modules \$*" >> "${LOG}"
for gpu in \${NVIDIA_STUB_BINDS:-}; do mkdir -p "${GPUS}/\${gpu}"; done
exit \${HELPER_RC:-0}
EOF
    chmod +x "${STUB_DIR}/modprobe" "${STUB_DIR}/bluefin-sysext-modules"
}

# add_device <address> <vendor> <class> [driver]: a PCI device in the fake sysfs.
add_device() {
    local dev="${SYSFS}/bus/pci/devices/$1"
    mkdir -p "${dev}" "${SYSFS}/bus/pci/drivers/${4:-none}"
    echo "$2" > "${dev}/vendor"
    echo "$3" > "${dev}/class"
    if [ -n "${4:-}" ]; then
        ln -s "../../../bus/pci/drivers/$4" "${dev}/driver"
    fi
}

run_helper() {
    run env PATH="${STUB_DIR}:${PATH}" NVIDIA_LOAD_SYSFS="${SYSFS}" NVIDIA_LOAD_GPUS="${GPUS}" \
        NVIDIA_LOAD_HELPER="${STUB_DIR}/bluefin-sysext-modules" bash "${SCRIPT}" "$@"
}

@test "without an NVIDIA display controller it fails and loads nothing" {
    add_device 0000:00:01.0 0x8086 0x030000
    add_device 0000:00:02.0 0x10de 0x040300 snd_hda_intel
    run_helper
    [ "$status" -eq 1 ]
    [[ "$output" == *"no NVIDIA display controller"* ]]
    [ ! -s "${LOG}" ]
}

@test "a free GPU is loaded without touching nouveau" {
    add_device 0000:02:00.0 0x10de 0x030000
    NVIDIA_STUB_BINDS=0000:02:00.0 run_helper
    [ "$status" -eq 0 ]
    ! grep -q '^modprobe ' "${LOG}"
    grep -qx 'bluefin-sysext-modules nvidia nvidia-uvm nvidia-modeset nvidia-drm' "${LOG}"
    [[ "$output" == *"nvidia drives 0000:02:00.0"* ]]
}

@test "a GPU bound to nouveau: nouveau is removed before nvidia loads" {
    add_device 0000:02:00.0 0x10de 0x030000 nouveau
    NVIDIA_STUB_BINDS=0000:02:00.0 run_helper
    [ "$status" -eq 0 ]
    [ "$(cat "${LOG}")" = "$(printf '%s\n' 'modprobe -r nouveau' \
        'bluefin-sysext-modules nvidia nvidia-uvm nvidia-modeset nvidia-drm')" ]
    [[ "$output" == *"nouveau holds 0000:02:00.0"* ]]
}

@test "nouveau in use: each held GPU is unbound through sysfs" {
    add_device 0000:01:00.0 0x10de 0x030000 nouveau
    add_device 0000:02:00.0 0x10de 0x030000 nouveau
    add_device 0000:03:00.0 0x10de 0x030000 vfio-pci
    MODPROBE_RC=1 NVIDIA_STUB_BINDS="0000:01:00.0 0000:02:00.0" run_helper
    [ "$status" -eq 0 ]
    # Each address is a separate write to the sysfs attribute (the fake file
    # keeps the last one); the GPU held by another driver is left alone.
    [ "$(cat "${SYSFS}/bus/pci/drivers/nouveau/unbind")" = 0000:02:00.0 ]
    [[ "$output" == *"unbinding 0000:01:00.0 from it"* ]]
    [[ "$output" == *"unbinding 0000:02:00.0 from it"* ]]
    [[ "$output" != *"0000:03:00.0 from it"* ]]
    grep -qx 'bluefin-sysext-modules nvidia nvidia-uvm nvidia-modeset nvidia-drm' "${LOG}"
}

@test "a mixed host: succeeds with the supported GPU and warns about the other" {
    add_device 0000:01:00.0 0x10de 0x030000 nouveau
    add_device 0000:02:00.0 0x10de 0x030000 nouveau
    NVIDIA_STUB_BINDS=0000:02:00.0 run_helper
    [ "$status" -eq 0 ]
    [[ "$output" == *"warning: 0000:01:00.0 is not driven by nvidia"* ]]
    [[ "$output" == *"Turing and newer"* ]]
    [[ "$output" == *"nvidia drives 0000:02:00.0"* ]]
}

@test "no GPU came up although the modules loaded: fails" {
    add_device 0000:01:00.0 0x10de 0x030000
    run_helper
    [ "$status" -eq 1 ]
    [[ "$output" == *"no NVIDIA GPU is driven by nvidia"* ]]
}

@test "the module loader's failure is the helper's exit status" {
    add_device 0000:01:00.0 0x10de 0x030000 nouveau
    HELPER_RC=1 run_helper
    [ "$status" -eq 1 ]
    [[ "$output" == *"bluefin-sysext-modules failed (exit 1)"* ]]
    grep -qx 'modprobe -r nouveau' "${LOG}"
}

@test "a 3D controller counts as a GPU" {
    add_device 0000:04:00.0 0x10de 0x030200 nouveau
    NVIDIA_STUB_BINDS=0000:04:00.0 run_helper
    [ "$status" -eq 0 ]
    grep -qx 'modprobe -r nouveau' "${LOG}"
}
