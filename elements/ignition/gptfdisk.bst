kind: manual
description: |
  sgdisk from GPT fdisk, for Ignition's disks stage in the initrd.

  Ignition v2.27.0 partitions exclusively through sgdisk
  (internal/sgdisk/sgdisk.go, internal/distro/distro.go sgdiskCmd); there is
  no sfdisk backend, build tag or config switch (upstream WIP:
  coreos/ignition#1929). FSDK 26.08 ships no gptfdisk element, so build only
  the non-interactive sgdisk here (gdisk/cgdisk/fixparts are not needed and
  cgdisk would pull in ncurses).

build-depends:
- base/base-stack.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/popt.bst
- freedesktop-sdk.bst:components/util-linux-libs.bst

variables:
  gptfdisk-version: 1.0.10

config:
  build-commands:
  # Same override as Fedora's gdisk.spec: FSDK's CXXFLAGS/LDFLAGS plus the
  # Makefile's large-file define. UTF-16 labels (ICU) stay disabled, as upstream.
  - |
    make -j%{max-jobs} sgdisk \
      CXXFLAGS="${CXXFLAGS} -D_FILE_OFFSET_BITS=64" \
      LDFLAGS="${LDFLAGS}"

  install-commands:
  - install -Dm755 sgdisk "%{install-root}%{bindir}/sgdisk"
  - install -Dm644 sgdisk.8 "%{install-root}%{mandir}/man8/sgdisk.8"

  - |
    %{install-extra}

sources:
- kind: tar
  url: sourceforge_download:project/gptfdisk/gptfdisk/%{gptfdisk-version}/gptfdisk-%{gptfdisk-version}.tar.gz
  ref: 2abed61bc6d2b9ec498973c0440b8b804b7a72d7144069b5a9209b2ad693a282
