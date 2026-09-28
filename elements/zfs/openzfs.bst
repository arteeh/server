kind: manual
description: |
  OpenZFS userspace (zpool, zfs, zed, libzfs, mount.zfs, udev rules, systemd
  units) plus the spl and zfs kernel modules, built out of tree against the
  FSDK kernel build tree at /usr/src/linux-<release>.

  Modules land unsigned in /usr/lib/modules/<release>/extra/;
  zfs/openzfs-signed.bst signs them, so rotating the module key does not
  rebuild ZFS. Nothing is installed under /etc: a systemd-sysext only
  overlays /usr, so upstream's /etc files are relocated to
  /usr/share/zfs/etc/ and seeded by tmpfiles.d.

  No runtime `depends:` on purpose: zfs/openzfs-signed.bst and
  oci/zfs-sysext.bst stage this artifact at a private location, and a
  runtime dependency would be staged there with it. The shared libraries
  come from the base OS image; oci/zfs-sysext.bst ships libtirpc, the only
  one the image lacks.

(@):
- include/zfs.yml

build-depends:
- base/base-stack.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst
# Kernel build tree (/usr/src/linux-<release>) and the kbuild host tools
# it needs: objtool links libelf, modules_install may zstd-compress.
- freedesktop-sdk.bst:components/linux.bst
- freedesktop-sdk.bst:components/elfutils.bst
- freedesktop-sdk.bst:components/kmod.bst
- freedesktop-sdk.bst:components/zstd.bst
# Userspace libraries.
- freedesktop-sdk.bst:components/libtirpc.bst
- freedesktop-sdk.bst:components/openssl.bst
- freedesktop-sdk.bst:components/systemd-libs.bst
- freedesktop-sdk.bst:components/util-linux-libs.bst
- freedesktop-sdk.bst:components/zlib.bst
# dlopen()ed at runtime for keylocation=https://.
- freedesktop-sdk.bst:components/curl.bst

sources:
- kind: tar
  url: github:openzfs/zfs/releases/download/zfs-%{zfs-version}/zfs-%{zfs-version}.tar.gz
  ref: 2a3c70d55a37cc71618a95a60e81ad66530201eb118d37741dc92efcf848c8b1

config:
  configure-commands:
  - |
    set -eu
    kver="$(ls "%{indep-libdir}/modules")"
    if [ "$(echo "${kver}" | wc -w)" -ne 1 ]; then
      echo "ERROR: expected exactly one kernel in %{indep-libdir}/modules, found: ${kver}" >&2
      exit 1
    fi
    ksrc="%{prefix}/src/linux-${kver}"
    if [ ! -f "${ksrc}/Module.symvers" ]; then
      echo "ERROR: ${ksrc} is not a kernel build tree (no Module.symvers)" >&2
      exit 1
    fi

    ./configure \
      --prefix="%{prefix}" \
      --exec-prefix="%{exec_prefix}" \
      --bindir="%{bindir}" \
      --sbindir="%{sbindir}" \
      --libdir="%{libdir}" \
      --libexecdir="%{libexecdir}" \
      --includedir="%{includedir}" \
      --datadir="%{datadir}" \
      --mandir="%{mandir}" \
      --sysconfdir="%{sysconfdir}" \
      --localstatedir="%{localstatedir}" \
      --runstatedir=/run \
      --enable-shared \
      --disable-static \
      --with-config=all \
      --with-linux="${ksrc}" \
      --with-linux-obj="${ksrc}" \
      --with-mounthelperdir="%{bindir}" \
      --with-udevdir="%{indep-libdir}/udev" \
      --with-udevruledir="%{indep-libdir}/udev/rules.d" \
      --enable-systemd \
      --with-systemdunitdir="%{indep-libdir}/systemd/system" \
      --with-systemdpresetdir="%{indep-libdir}/systemd/system-preset" \
      --with-systemdgeneratordir="%{indep-libdir}/systemd/system-generators" \
      --with-systemdmodulesloaddir="%{indep-libdir}/modules-load.d" \
      --with-dracutdir="%{indep-libdir}/dracut" \
      --disable-sysvinit \
      --disable-pyzfs \
      --with-python=no \
      --disable-pam \
      --with-tirpc \
      --without-libunwind

  build-commands:
  - make -j%{max-jobs}

  install-commands:
  # INSTALL_MOD_PATH puts the modules under /usr/lib/modules (kbuild
  # appends /lib/modules/<release>/extra); INSTALL_MOD_STRIP drops their
  # debug info before openzfs-signed.bst signs them.
  - |
    set -eu
    make -j1 install \
      DESTDIR="%{install-root}" \
      INSTALL_MOD_PATH="%{install-root}%{prefix}" \
      INSTALL_MOD_STRIP=1 \
      bashcompletiondir="%{datadir}/bash-completion/completions"
    find "%{install-root}" -name '*.la' -delete

  - |
    set -eu
    kver="$(ls "%{indep-libdir}/modules")"
    for m in spl zfs; do
      if [ ! -e "%{install-root}%{indep-libdir}/modules/${kver}/extra/${m}.ko" ] &&
         [ ! -e "%{install-root}%{indep-libdir}/modules/${kver}/extra/${m}.ko.zst" ]; then
        echo "ERROR: ${m}.ko was not installed to %{indep-libdir}/modules/${kver}/extra" >&2
        exit 1
      fi
    done

  # Drop what a non-root-on-ZFS, systemd-only sysext does not use:
  # dracut and initramfs-tools hooks (the UKI initrd never imports pools),
  # the ZFS Test Suite, dev helper scripts, and module build metadata
  # (/usr/src/zfs-<version>) that no other element builds against.
  - |
    set -eu
    root="%{install-root}"
    rm -rf \
      "${root}%{indep-libdir}/dracut" \
      "${root}%{datadir}/initramfs-tools" \
      "${root}%{datadir}/zfs/zfs-tests" \
      "${root}%{datadir}/zfs/test-runner" \
      "${root}%{datadir}/zfs/runfiles" \
      "${root}%{prefix}/src"
    rm -f \
      "${root}%{datadir}/zfs/zfs-helpers.sh" \
      "${root}%{datadir}/zfs/zfs-tests.sh" \
      "${root}%{datadir}/zfs/zfs.sh" \
      "${root}%{datadir}/zfs/zimport.sh" \
      "${root}%{datadir}/zfs/zloop.sh" \
      "${root}%{bindir}/raidz_test" \
      "${root}%{bindir}/ztest"

  # systemd-sysext merges only /usr and /opt, so /etc content in the image
  # would be ignored. Paths compiled into the binaries stay on /etc (zed.d,
  # zpool.d, zpool.cache, zfs-list.cache), where they remain writable; the
  # upstream defaults move to /usr/share/zfs/etc/ and tmpfiles.d seeds the two
  # directories zed and `zpool status -c` need. zfs-functions is dropped: only
  # the SysV init scripts and initramfs-tools hooks source it. /etc/default/zfs
  # is kept as a reference copy; the units read it with EnvironmentFile=-.
  - |
    set -eu
    root="%{install-root}"
    rm -f "${root}%{sysconfdir}/zfs/zfs-functions"
    mkdir -p "${root}%{datadir}/zfs"
    mv "${root}%{sysconfdir}" "${root}%{datadir}/zfs/etc"

    install -d "${root}%{indep-libdir}/tmpfiles.d"
    cat > "${root}%{indep-libdir}/tmpfiles.d/zfs.conf" <<EOF
    d %{sysconfdir}/zfs 0755 root root -
    C %{sysconfdir}/zfs/zed.d - - - - %{datadir}/zfs/etc/zfs/zed.d
    C %{sysconfdir}/zfs/zpool.d - - - - %{datadir}/zfs/etc/zfs/zpool.d
    EOF

    install -d "${root}%{indep-libdir}/systemd/system/zfs-zed.service.d"
    cat > "${root}%{indep-libdir}/systemd/system/zfs-zed.service.d/10-seed-etc.conf" <<EOF
    [Service]
    ExecStartPre=-%{bindir}/systemd-tmpfiles --create zfs.conf
    EOF

  # 90-zfs.rules calls /sbin/modprobe; point it at the usr-merged path.
  - |
    set -eu
    sed -i 's|/sbin/modprobe|%{bindir}/modprobe|g' \
      "%{install-root}%{indep-libdir}/udev/rules.d/90-zfs.rules"

  - |
    set -eu
    for entry in "%{install-root}"/* "%{install-root}"/.[!.]*; do
      [ -e "${entry}" ] || [ -L "${entry}" ] || continue
      if [ "${entry}" != "%{install-root}%{prefix}" ]; then
        echo "ERROR: installed outside %{prefix}: ${entry#%{install-root}}" >&2
        exit 1
      fi
    done

  # FSDK's stripper treats bare .ko files as ELF objects and dwz rejects
  # them; modules are already stripped (INSTALL_MOD_STRIP=1), so compress
  # them here. openzfs-signed.bst decompresses, signs and recompresses.
  - |
    set -eu
    find "%{install-root}%{indep-libdir}/modules" -type f -name '*.ko' -exec zstd -19 --rm -q {} ';'
