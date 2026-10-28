# Linux/X11 fork maintenance

The stable baseline is upstream v0.8.0. This fork owns its old-Linux and
X11/VDI compatibility code, regression tests and standalone benchmark.
Letty consumes a full commit and checksum-verified source archive directly;
it does not replay nanoui patches or supply framework font I/O symbols.

## Owned implementation

The five former Letty patch groups are committed as framework source:
bounded font discovery/cluster fallback, immutable source leases, grid shaping,
frame arena recovery, native pointer/scroll/modifier input, glyph-atlas lifetime,
GTK 3 CPU/X11 surfaces and owned IME queues, bounded backing/damage tracking,
opaque fills, and native image-sink initialization/migration.

The libc font adapter is implemented in Zig (`src/ui/tt/file_io.zig`) and
uses the versioned x86_64 glibc fstat ABI on the supported delivery target.
It has no lt_* application callback boundary. Other platforms retain their
native Zig I/O. Core regression tests embed licensed immutable font fixtures;
no sibling application or HarfBuzz checkout is required.

The [benchmark](../tools/x11-bench/README.md) measures the actual bounded
CPU backing used by the supported GTK 3 path. Snapshot and workload tests run
offscreen. Its Linux package includes source hashes and an ELF ABI audit.
Old benchmark reports continue to certify only their recorded implementations.

The v0.8.0 merge retains the fork's image-sink binding, color-font masks,
font-feature cache keys, raw pointer buttons and terminal wheel metadata.
Native secondary clicks also reach upstream context menus without activating
primary widgets. macOS built-in scroll views use upstream display pacing;
product wheel consumers keep their discrete steps, horizontal delta and phase.

The release adds text areas and focus traversal, drag/drop and accessibility,
macOS display-link pacing, text effects, motion helpers and CPU/OpenGL shadow
parity. The 144-byte draw instance includes transforms, pulse and velocity;
damage comparison validates all fields and encloses rotated/knockout shadows.
Grouped opacity redraws fully because its offscreen composition spans children.
The fork retains its numeric mouse contract (1 left, 2 right, 3 middle), maps
upstream Tester button helpers to it, and suppresses primary UI gestures on raw
secondary presses. Color-glyph masks and failure-aware atlas replacement also
remain active alongside the release's dark-on-light glyph masks.

See the [0.8.0 migration review](nanoui-0.8.0-migration.md) for the downstream
keep/replace decisions and retired implementations.

## Maintenance checks

Use Zig 0.17.0, serialize builds, and retain stable source while checking:

```sh
zig build lines
zig build test -Doptimize=ReleaseSafe
zig build test -Dportable=true -Doptimize=ReleaseSafe
python3 tools/build-x11-bench.py --native
python3 tools/build-x11-bench.py
zig build -Dtarget=x86_64-linux.3.10-gnu.2.17 -Dcpu=baseline -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
zig build $(sh tools/ios/zig-lib.sh) -Dtarget=aarch64-ios-simulator -Doptimize=ReleaseSafe
```

The maintenance branch CI runs framework and benchmark checks, including a
private Linux Xvfb functional smoke test. Run oldest-target Linux, X11/VDI,
input methods, remote scrolling and client-visible latency checks separately.
Cross-compilation and static ABI checks do not establish target acceptance.
