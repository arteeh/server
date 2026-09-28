kind: compose
description: Integrated initrd tree (initrd-stack minus debug/devel/doc/locale/tests).

build-depends:
- bluefin-server/initrd/initrd-stack.bst

config:
  exclude:
  - debug
  - devel
  - doc
  - locale
  - tests
  include-orphans: True
  # Ships a shell; integration builds the ld.so cache and hwdb.
  integrate: True
