# Upstream v0.8.0 migration and downstream review

The stable baseline is upstream `v0.8.0`, commit
`8e2c690acf363f7fbd0393ef84a6231ecfc12dfb`, merged into the existing
maintenance history. The release-to-release review covers `v0.7.1..v0.8.0`;
upstream main is not the baseline.

The release adds text areas, focus traversal, drag/drop, accessibility,
macOS display-link pacing, motion helpers, CPU/OpenGL rendering parity and
Objective-C large-struct returns on x86_64. It still requires Zig 0.17.0.

## Which downstream changes are still needed?

The five historical application patches are framework commits now. They must
be reviewed by responsibility, rather than reapplied wholesale or discarded
because upstream changed the same files.

| Historical group / fix | Decision for 0.8.0 | Reason and current boundary |
| --- | --- | --- |
| Font, grid and memory | Keep and adapt | Upstream still lacks the fork's immutable font-source leases, bounded cluster fallback, run-shaper hook, terminal grid placement, feature-aware cache keys and idle arena recovery. New tabular/rounded/tracking options are incorporated into these paths. |
| Native input and atlases | Partially replace | Use upstream focus, text editing, drag/drop, cursor and event modules. Retain terminal raw button edges, discrete wheel steps/line metadata, gesture boundaries, color-emoji ink masks, allocation diagnostics and safe atlas replacement. |
| GTK 3 / X11 | Keep | Upstream's general GTK/OpenGL path does not provide this fork's guaranteed GTK 3 CPU path, synchronous owned/bounded IME delivery, reentrant teardown, typography handling and coalesced dirty-region presentation. |
| CPU damage and opaque fill | Keep and adapt | Upstream improves CPU/shadow rendering, but does not replace the fork's retained backing/tracker or bounded failure handling. Compare all 144-byte instance fields; include rotated and knockout-shadow bounds. Groups force full redraw; ordinary text/cursor changes retain partial redraw. Opaque-fill acceleration falls back for rotated/circular quads. |
| Image sink lifetime | Keep | Upstream binds new surfaces before callbacks, covering part of the original problem. It still assigns the sink directly: the fork's `bindSink` must also migrate an existing CPU atlas, and CPU sync must not overwrite sink uploads. |
| Native font I/O | Keep | The versioned x86_64 `fstat` adapter is still required by the glibc 2.17 target. No application font-I/O exports or C shim is introduced. |
| Light font support and named matching | Keep | Upstream still has no `.light` in `Weight`; retain the portable 300-weight mapping and native Light constructor. Named OpenType 300 faces also require the fork's -0.23 CoreText trait, separately from the system constructor's -0.4, and its regression test. |
| Shifted AppKit menu accelerators | Keep | The shared parser remains lowercase; AppKit needs the shifted uppercase equivalent for combinations such as Cmd+Shift+P. Preserve upstream selector support too. |

## Retired or consolidated code

- Delete `src/ui/scrollbar.zig`: upstream `scroll.zig` supplies shared scrollbar
  geometry, track clicks and dragging. Keep the fork's consumed-release
  behavior so releasing a thumb cannot activate content below it.
- Delete `src/ui/surface_tracking.zig`: upstream `surface_events.zig` now owns
  tracking areas and event-driven accessibility updates. The old per-frame
  Reduce Motion query is unnecessary.
- Remove the duplicate surface resize state and the old in-file AppKit event
  implementation. Adapt terminal wheel metadata in upstream's event module.
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

Hidden v0.8.0 surfaces defer presentation and portable glyph uploads. The
`Surface.glyphAtlasTexture` inspection hook resolves that upload through the
same path as the presenter, so owned offscreen pixel fixtures do not assume
that a hidden frame has already allocated a GPU atlas.

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


Verified on macOS arm64 with Zig 0.17.0:

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
