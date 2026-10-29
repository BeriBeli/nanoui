# Upstream v0.8.0 migration and downstream review

The stable baseline is upstream `v0.8.0`, commit
`8e2c690acf363f7fbd0393ef84a6231ecfc12dfb`, merged into the existing
maintenance history. The release-to-release review covers `v0.7.1..v0.8.0`;
upstream main is not the baseline.

The release adds text areas, focus traversal, drag/drop, accessibility,
macOS display-link pacing, motion helpers, CPU/OpenGL rendering parity and
Objective-C large-struct returns on x86_64. It still requires Zig 0.17.0.

## Which downstream changes are still needed?

The five historical patch groups were reviewed by responsibility. After Letty
moved product policy to its own code, obsolete application extensions were
removed; compatibility fixes remain internal to the framework. The decisions
below describe the current tree, including that cleanup.

| Historical group / fix | Decision for 0.8.0 | Reason and current boundary |
| --- | --- | --- |
| Font resources and memory | Keep internal fixes; retire product APIs | Retain bounded discovery/fallback, shared immutable snapshots, owned theme names, cache invalidation, allocation cleanup and idle arena recovery. Remove grid placement, run-shaper hooks, source/lease exports, custom features and configured fallback lists. |
| Native input and atlases | Partially replace | Use upstream focus, text editing, drag/drop, cursor and event modules. Retain complete physical button edges, responsive discrete wheel steps, color-emoji ink masks, allocation diagnostics and safe atlas replacement. Restore upstream button enums; remove terminal metadata and the atlas inspection export. |
| GTK 3 / X11 | Keep | Upstream's general GTK/OpenGL path does not provide this fork's guaranteed GTK 3 CPU path, synchronous owned/bounded IME delivery, reentrant teardown and coalesced dirty-region presentation. Terminal point/DPI conversion belongs to the application. |
| CPU damage and opaque fill | Keep and adapt | Upstream improves CPU/shadow rendering, but does not replace the fork's retained backing/tracker or bounded failure handling. Compare all 144-byte instance fields; include rotated and knockout-shadow bounds. Groups force full redraw; ordinary text/cursor changes retain partial redraw. Opaque-fill acceleration falls back for rotated/circular quads. |
| Image sink lifetime | Keep | Upstream binds new surfaces before callbacks, covering part of the original problem. It still assigns the sink directly: the fork's `bindSink` must also migrate an existing CPU atlas, and CPU sync must not overwrite sink uploads. |
| Native font I/O | Keep | The versioned x86_64 `fstat` adapter is still required by the glibc 2.17 target. No application font-I/O exports or C shim is introduced. |
| Light font support and named matching | Retire product extension | Restore upstream's four `Weight` tags and native font constructor. Letty registers/selects its 300-weight faces and applies features through its own shaping boundary. |
| Shifted AppKit menu accelerators | Keep | The shared parser remains lowercase; AppKit needs the shifted uppercase equivalent for combinations such as Cmd+Shift+P. Preserve upstream selector support too. |

## Retired or consolidated code

- Delete `src/ui/scrollbar.zig`: upstream `scroll.zig` supplies shared scrollbar
  geometry, track clicks and dragging. Keep the fork's consumed-release
  behavior so releasing a thumb cannot activate content below it.
- Delete `src/ui/surface_tracking.zig`: upstream `surface_events.zig` now owns
  tracking areas and event-driven accessibility updates. The old per-frame
  Reduce Motion query is unnecessary.
- Remove the duplicate surface resize state and the old in-file AppKit event
  implementation. Keep native pointer fixes in upstream's event module without
  adding application input fields.
- Use the existing smoothing-preference reader for both glyph masks instead
  of maintaining a second preference cache. Preserve the new upstream
  dark-on-light mask and the fork's color-emoji mask.
- Move the rotation-aware CPU glyph routine into the existing `raster_text`
  leaf; retain native Windows coverage handling without duplicate routines.
- Keep upstream's image decode budgets, cache compaction, shadow kernels,
  text editing, focus traversal and Objective-C ABI fixes directly.

The AppKit adapter keeps physical button presses separately from `Input.down`.
Upstream ends a UI context-menu gesture by clearing `Input.down`; using that
flag as the release gate would drop a terminal's raw right-button release.
The shared physical-button adapter delivers each owned release once and rejects
duplicates. The Tester uses the same adapter; a field-focus/widget regression
verifies complete raw right/middle edges without primary widget activation.

The historical `Surface.glyphAtlasTexture` inspection hook is removed. Hidden
presentation and portable atlas uploads still use the private presenter path;
framework fixtures exercise resource lifetime without an application export.
The retained CPU workload regression accesses damage types inside the framework,
so the benchmark no longer needs `ui.CpuDamage` or `ui.gpu` aliases.

Removed interfaces include `gridText`, `.glyph_run`, `gridLayout`, `shapeGrid`,
`findGridCell`, `setRunShaper`, `FontFeature`, `TextStyle.features`,
`setFallbacks`, `FontSources`, `Db.source`, `Db.clusterFace`, `Weight.light`,
`FocusedText.editable`, `Context.points_to_logical`, `Input.mouse_button`,
`Input.scroll_lines` and `Input.scroll_started`. An API contract regression
runs under both text backends. Shared font snapshots and bounded fallback tests
remain private, including independent database teardown, TTC indexing, source
quotas, allocation failure cleanup and immutable registered font data.

The standalone X11 benchmark also releases its new growable `TextBuffer`
when the owning process fixture or test state ends.

The [macOS presentation follow-up](macos-presentation.md) rejects stale-size
drawables, restores transaction-owned resize presentation, and separates UI
wake deadlines from display cadence.

## Verification scope

The migration adds regressions for transform-only damage, rotated glyph/image/
quad/shadow output, knockout shadows, pulse/velocity comparison, grouped opacity
updates/removal, and rejection of nonfinite new fields. Retained/scissored output
is compared byte-for-byte with a complete CPU draw. Existing raw-secondary
focus and primary-gesture regressions remain enabled alongside upstream tests.

Native Metal tests require macOS GPU access; sandbox initialization failures
are environment failures and must not be accepted as rendering evidence.
Portable tests, cross-builds and static ABI checks do not establish execution
on Linux 3.10/glibc 2.17, real X11/VDI latency or system IME acceptance.


Earlier v0.8.0 merge verification on macOS arm64 with Zig 0.17.0 (before API cleanup):

- Native framework: 284 passed, 1 skipped; portable: 267 passed, 7 skipped.
- Native examples and the line-limit check passed.
- Linux x86_64 kernel 3.10/glibc 2.17 baseline CPU and aarch64 builds passed;
  the x86_64 test binary also cross-compiled. All shipped x86_64 ELF files
  passed the static ABI audit.
- Windows x86_64/aarch64 and iOS device/simulator builds passed.
- Standalone X11 benchmark host checks and Linux packaging/ABI checks passed.

Android was not built because this host has no Android SDK/NDK. No Linux
container runtime was available, so Linux test execution and oldest-target,
remote X11/VDI and system IME acceptance remain external checks.

## API cleanup verification

On macOS arm64 with Zig 0.17.0, the cleaned framework passes 280 native tests
(2 skipped) and 270 portable tests (7 skipped). Upstream-facing `ui` exports,
`TextStyle`, `Weight` and the input model are restored to the stable baseline;
contract tests reject the retired extensions under both text backends.

Native examples, Linux x86_64 kernel 3.10/glibc 2.17 baseline CPU and aarch64,
Windows x86_64/aarch64, and iOS device/simulator builds pass. The x86_64 Linux
test executable cross-compiles. Android packaging cannot complete on this host
because the Android SDK/NDK is unavailable; no Linux container runtime is
installed. Target execution, remote X11/VDI performance and system IME acceptance
remain external checks.

The standalone benchmark host tests pass using upstream's public CPU canvas;
the private bounded backing has its own pixel/damage regression. The Linux
benchmark package and all three desktop example ELF files pass the static
2.17 ABI audit. All 21 standalone GTK input/IME handler fixtures and the
600-line guard pass. These results do not substitute for target execution.
