kind: manual
description: |
  CoreOS Ignition, built from the upstream release tarball for the
  systemd-native initrd (no dracut). Installs %{bindir}/ignition, which the
  units in bluefin-server/initrd/initrd-ignition.bst run as
  `ignition --platform=metal --root=/sysroot --stage=<stage>`.

  Offline Go build: the release tarball commits vendor/ and upstream's
  ./build script sets GOFLAGS=-mod=vendor. cgo is required (CGO_ENABLED=1 in
  ./build): internal/exec/util/blkid.go links libblkid, and
  internal/exec/util/user_group_lookup.go does chrooted getpwnam/getgrnam.

  Link-time distro settings (internal/distro/distro.go):
    selinuxRelabel=false               no SELinux policy; true would exec setfiles
    writeAuthorizedKeysFragment=false  write ~/.ssh/authorized_keys, which the
                                       stock sshd AuthorizedKeysFile reads,
                                       instead of ~/.ssh/authorized_keys.d/ignition

  ignition-validate is not built: it is a host-side linter and has no use in
  the initrd.

build-depends:
- base/base-stack.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-go.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/util-linux-libs.bst

variables:
  ignition-version: v2.27.0
  # Same as FSDK's Go elements: keep DWARF uncompressed for the stripper.
  optimize-debug: "false"
  ignition-ldflags: >-
    %{go_ldflags}
    -X github.com/coreos/ignition/v2/internal/distro.selinuxRelabel=false
    -X github.com/coreos/ignition/v2/internal/distro.writeAuthorizedKeysFragment=false

environment:
  GOPATH: "%{build-root}/.go"
  GOCACHE: "%{build-root}/.cache/go-build"
  GOPROXY: "off"
  GOTOOLCHAIN: local

config:
  build-commands:
  # ./build appends `-X .../internal/version.Raw=${VERSION}` to GLDFLAGS and
  # builds with -buildmode=pie; its `export GOFLAGS=-mod=vendor` replaces
  # FSDK's GOFLAGS, so FSDK's %{go_ldflags} is passed back in via GLDFLAGS.
  - |
    VERSION='%{ignition-version}' \
    BIN_PATH="${PWD}/bin" \
    GLDFLAGS='%{ignition-ldflags}' \
    ./build ignition

  - |
    stamped="$(./bin/ignition -version)"
    echo "${stamped}"
    [ "${stamped}" = 'Ignition %{ignition-version}' ]

  install-commands:
  - install -Dm755 bin/ignition "%{install-root}%{bindir}/ignition"

  - |
    %{install-extra}

sources:
- kind: tar
  url: github:coreos/ignition/archive/refs/tags/%{ignition-version}.tar.gz
  ref: 9d70c163d5dca6c236a0883c58784d2d38116b1d6bc8380c824ff18abfb3bbb8
