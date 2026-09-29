# patches/

`patch_queue` sources apply every file in a directory, in file name order,
on top of the junction they belong to. `just validate` fails if one no longer
applies.

## freedesktop-sdk/

Applied to the freedesktop-sdk junction (`elements/freedesktop-sdk.bst`).
Every patch that edits an FSDK element (0002-0006) changes that element's
cache key and the keys of everything that depends on it, so those artifacts
come from the Bluefin cache or a local build, never from FSDK's cache. Keep
the queue short.

| Patch | Why | Upstream status | Drop when |
|---|---|---|---|
| `0001-project.conf-Add-GNOME-CAS-servers.patch` | Adds the GNOME artifact and source cache to FSDK's own `project.conf`, so the junction pulls from it without per-user BuildStream config. Taken from gnome-build-meta. | Downstream by design (GNOME carries it too). | GNOME's cache stops serving FSDK 26.08 artifacts. gnome-50 builds on FSDK 25.08, so check the hit rate before the next FSDK minor. |
| `0002-glib-stage1-disable-tests.patch` | `-Dtests=false` for the bootstrap glib: building its tests ran the uninstalled `glib-compile-resources` before libgio existed and failed with exit 127 in from-source bootstrap builds (projectbluefin/server#50). | Not reported upstream. | A from-source build of `components/_private/glib-stage1.bst` passes without it. |
| `0003-gobject-introspection-base-library-symlinks.patch` | Remote-execution (BuildBarn) builds: creates the uninstalled SONAME links for `libgirepository-1.0.so.1` and sets `LD_LIBRARY_PATH` before ninja runs `g-ir-compiler` (projectbluefin/server#53). | Not reported upstream. | Builds no longer run under remote execution, or they pass without it. |
| `0004-gdk-pixbuf-library-symlinks.patch` | Same failure for `gdk-pixbuf-print-mime-types` and `libgdk_pixbuf-2.0.so.0` (projectbluefin/server#55). | Not reported upstream. | As 0003. |
| `0005-appstream-library-symlinks.patch` | Same failure for `appstreamcli` and `libappstream.so.5` / `libappstream-compose.so.0` in `appstream` and `appstream-minimal` (projectbluefin/server#57). | Not reported upstream. | As 0003. |
| `0006-linux-kubernetes-cilium-networking.patch` | Builds VXLAN, GENEVE, the tc BPF classifier/action, ingress qdisc, INET_DIAG (+TCP/UDP, DIAG_DESTROY) and `NOTRACK` for Cilium and the kubeadm/k0s sysexts. Written into `fdsdk-config.sh`, so FSDK's expected-config check fails the build if Kconfig drops one. | Not proposed upstream. | FSDK's kernel config enables them. |

### Hardcoded library versions in 0003-0005

These three patches name the full library file each link points at:

| Patch | Link target | Pinned component (FSDK 26.08.0) |
|---|---|---|
| 0003 | `libgirepository-1.0.so.1.0.0` | gobject-introspection 1.86.0 |
| 0004 | `libgdk_pixbuf-2.0.so.0.4400.7` | gdk-pixbuf 2.44.7 |
| 0005 | `libappstream.so.1.1.6`, `libappstream-compose.so.1.1.6` | appstream 1.1.6 |

An FSDK point release that bumps one of these components leaves the patch
applying cleanly but its links dangling, and remote builds fail again with
exit 127. On every FSDK bump, compare these names with the component
versions in the new FSDK ref and update the patch in the same change.
