kind: compose
description: Integrated OS tree (os-stack minus debug/devel/doc/tests) for the /usr image.

build-depends:
- bluefin-server/os-stack.bst

config:
  exclude:
  - debug
  - devel
  - doc
  - tests
  include-orphans: True
  # Ships a shell; integration builds the ld.so cache and hwdb.
  integrate: True
