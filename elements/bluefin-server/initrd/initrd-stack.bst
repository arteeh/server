kind: stack
description: |
  systemd-native initrd userspace (no dracut). Brings up the network,
  downloads the /usr DDI with systemd-importd (rd.systemd.pull= or the
  import.pull credential), attaches it with systemd-loop@, opens dm-verity
  from usrhash=, and switches into a tmpfs root with /usr mounted read-only.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/ca-certificates.bst
- freedesktop-sdk.bst:integration/extra-fs.bst
- freedesktop-sdk.bst:integration/ldconfig.bst
- freedesktop-sdk.bst:components/systemd.bst
- freedesktop-sdk.bst:components/kmod.bst
- freedesktop-sdk.bst:components/util-linux.bst
- freedesktop-sdk.bst:components/cryptsetup.bst
# device-mapper udev rules: libdevmapper is built with udev sync and waits
# for them, so without this systemd-veritysetup never finishes.
- freedesktop-sdk.bst:components/lvm2.bst
- freedesktop-sdk.bst:components/curl.bst
# verify=signature: gpgv/gpg plus the image keyring for SHA256SUMS.gpg
- freedesktop-sdk.bst:components/gnupg.bst
- bluefin-server/os-sysupdate-keys.bst
- bluefin-server/os-release.bst
- bluefin-server/initrd/initrd-config.bst
# Opt-in: runs only when an ignition.config / ignition.config.url credential is passed
- bluefin-server/initrd/initrd-ignition-stack.bst
