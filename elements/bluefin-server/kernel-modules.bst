kind: manual
description: |
  FSDK kernel image plus its modules, signed with our module key
  (files/boot-keys/linux-module-cert.key) and zstd-compressed. The kernel
  trusts the matching certificate through the linux-module-cert override,
  so lockdown accepts exactly these modules and ones we sign later (ZFS).
  Mirrors freedesktop-sdk's vm/boot/efi-secure/signed-modules.bst.

build-depends:
- base/base-stack.bst
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/findutils.bst
- freedesktop-sdk.bst:components/kmod.bst
- freedesktop-sdk.bst:components/linux.bst
- freedesktop-sdk.bst:components/openssl.bst
- freedesktop-sdk.bst:components/sign-file.bst
- freedesktop-sdk.bst:components/zstd.bst
- bluefin-server/keys/boot-keys.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - |
    set -eu
    mkdir -p "%{install-root}%{indep-libdir}"
    cp -rT %{indep-libdir}/modules "%{install-root}%{indep-libdir}/modules"
    for kdir in "%{install-root}%{indep-libdir}"/modules/*/; do
      rm -f "${kdir}vmlinux" "${kdir}System.map" "${kdir}build"
    done

  - |
    set -eu
    openssl x509 -inform PEM -outform DER \
      -in /boot-keys/modules/linux-module-cert.crt -out module-cert.der
    find "%{install-root}%{indep-libdir}/modules" -type f -name '*.ko.zst' -exec zstd -d --rm -q {} ';'
    find "%{install-root}%{indep-libdir}/modules" -type f -name '*.ko' \
      -exec sign-file sha512 /boot-keys/linux-module-cert.key module-cert.der {} ';' \
      -exec zstd -19 --rm -q {} ';'

  - |
    set -eu
    for kver in $(ls "%{install-root}%{indep-libdir}/modules"); do
      depmod -b "%{install-root}%{prefix}" "${kver}"
    done
