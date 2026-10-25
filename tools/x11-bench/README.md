# nanoui X11 forwarding benchmark

A standalone native nanoui application for measuring the GTK 3 CPU path over
SSH X11 forwarding or VDI. It has no PTY, Ghostty, shell, browser or Letty runtime.
It builds directly against this nanoui checkout, including its bounded retained CPU damage
renderer and versioned libc font-I/O path for x86_64 Linux 3.10/glibc 2.17.

## Build

From the nanoui repository root, using exactly Zig 0.17.0 and Python 3:

```sh
python3 tools/build-x11-bench.py --zig=/absolute/path/to/zig
```

This cross-builds `x86_64-linux.3.10-gnu.2.17`, baseline CPU, ReleaseSafe,
audits the ELF and creates `zig-out/packages/nanoui-x11-bench-linux-x86_64.tar.gz`.
The archive includes the binary, optional collector, nanoui license and a manifest
with the binary hash, actual nanoui/benchmark source hashes and checkout revision.
A dirty checkout is recorded explicitly; its hashes describe the source built.
No compiler or Python is needed to run the binary itself.

The benchmark runtime baseline is GTK 3.22.30+, GLib 2.56.1+, Cairo 1.15.12+,
glibc 2.17+, Linux 3.10+, and installed TrueType/OpenType fonts. Check the actual
libraries on the CentOS 7.9 host; its distribution name alone is insufficient.
This benchmark uses nanoui's built-in text shaper. It has no sibling-repository,
vendor checkout or HarfBuzz dependency. The Linux process selects GTK 3, X11 and
CPU rendering explicitly, even when GTK 4 or OpenGL is installed.

## Run on CentOS 7.9 through the intended connection

Copy and extract the archive on the server. Establish X11 forwarding from the
client with an X server running, using your usual authorized SSH configuration:

```sh
ssh -X user@server
echo "$DISPLAY"
cd nanoui-x11-bench-linux-x86_64
GDK_BACKEND=x11 NANOUI_GTK=3 NANOUI_RENDERER=cpu ./nanoui-x11-bench > suite.json
```

The benchmark verifies the actual display is X11 and runs the CPU renderer.
Keep the test window visible and uncovered on the client. Do not resize or
interact during automated comparisons. Repeat under the same window size,
display scale, network route, X server and desktop/VDI settings. Record those
settings, SSH compression and an independently measured link RTT. A localhost
DISPLAY or SSH environment variable does not itself prove remote presentation.

The default suite warms each workload for 2 seconds and measures it for 10:

| Mode | Workload |
| --- | --- |
| `idle` | Static text; no recurring redraw requests |
| `small` | Only one 32×24 logical-pixel color patch changes |
| `scroll` | One-row terminal-style text advance per requested update |
| `full` | Whole-window color changes and deterministic changing tiles |
| `input` | Separate manual typing, IME, click acknowledgement and wheel test |

`scroll` models a terminal output viewport; it does not use XCopyArea or promise
a toolkit scroll-blit optimization. `full` stresses a repeatable tile payload,
not random per-pixel image/video entropy.

```sh
# One workload at a controlled offered rate (maximum, without catch-up bursts).
GDK_BACKEND=x11 ./nanoui-x11-bench --mode=scroll --fps=60 --seconds=30 > scroll.json

# Manual interaction; JSON contains counts/timings, never typed text.
GDK_BACKEND=x11 ./nanoui-x11-bench --mode=input --seconds=60 > input.json

# Diagnostic: X server synchronization after every paint cycle.
GDK_BACKEND=x11 ./nanoui-x11-bench --mode=scroll --sync > scroll-sync.json

# Optional collector: environment, process peak RSS, hash and benchmark JSON.
python3 run.py --output=ssh-no-compression.json \
  --label='client X server/version; direct LAN; ssh -C off; RTT 2 ms' -- \
  --mode=suite --fps=30
```

Run separate sessions to compare your usual SSH compression enabled/disabled,
local X11 versus forwarding, or different RTTs. The app does not change network
settings. With a high RTT, `--sync` deliberately serializes paint cycles and can
substantially reduce throughput. Compare it as a separate diagnostic condition.

## Read the results

JSON stdout is separate from progress/error stderr. A successful run exits zero
and has `complete: true`, valid CPU backing and GTK paint evidence for changing
automated stages. Static idle and untouched input can have zero paint cycles.
Closing early exits nonzero with an incomplete report. The collector
marks invalid runs and refuses to overwrite an existing result file.

- `requests`, `coalesced_requests`: offered workload updates and those added
  while an earlier update still awaited the GTK boundary; not network packets.
- `gtk_paint_cycles_per_second`: GTK frame-clock after-paint cycles with a new
  nanoui frame and valid backing. These are application-side cycles, not verified
  client display FPS. Exposures, user input and GTK scheduling affect the count.
- `request_to_after_paint_ms`: oldest pending update request to the GTK boundary.
  Coalesced updates share a sample; an unpainted tail is reported separately.
- `after_paint_interval_ms`: cadence between observed cycles, with p50/p95/max.
- `sampled_build_ms`, `sampled_layout_ms`, `sampled_display_list_ms`: the latest
  nanoui frame sampled at each paint cycle. They exclude CPU rasterization,
  Cairo, network transfer and client composition, and can miss coalesced builds.
- `input_dispatch_to_after_paint_ms`: first input observed by the view to the
  next boundary, coalescing multiple events. Excludes client-to-server transit;
  event counts are app dispatch batches, not physical key counts.
- `x_server_sync_ms`: optional GDK/X11 synchronization time, including flushing
  pending work. It is not a pure network ping or a physical display timestamp.
- `cpu_percent_one_core`: process CPU time/wall time, where 100% is one core.
  The collector adds process peak RSS in KiB for the entire run, not each stage.

Timing histograms have bounded memory, 1 ms upper bins through 2000 ms and an
explicit overflow count. If a quantile falls in overflow it reports the maximum
conservatively. Empty samples are null. Timers offer at most the requested FPS,
skip missed deadlines and never enqueue catch-up bursts. Idle/input modes have
one timing wakeup per second and no benchmark-driven periodic redraws.
Warmup and the first entry frame can affect initial timing samples.

For real key-to-photon latency, record the client input and acknowledgement
counter with a suitable external/client-side measurement. For traffic, measure
the relevant SSH connection externally (or use an isolated X11 tracing tool),
recording direction and compression. The app does not report dirty pixels as
wire bytes, nor GTK completion as proof the remote user has seen the frame.

## Performance acceptance criteria

The initial product target is stable 30-update/s terminal interaction, prompt
typing feedback and negligible idle CPU. The thresholds below are proposed
project acceptance targets, not industry standards or measured guarantees.
Calibrate them against the actual server hardware and forwarding connection.

### Controlled test procedure

Use a 1100×720 window, fixed display scale and 30 FPS, with `--sync` disabled.
Warm each stage for 5 seconds, measure for 30 seconds and repeat three times.
Keep the window visible and uncovered, leave automated stages untouched and
hold the server load, client X server, network route and SSH compression fixed.
Record independently measured RTT and its variation. Start with RTT at or below
10 ms; establish a separate baseline for higher-latency connections.

```sh
python3 run.py --output=run-1.json \
  --label='X server/version; scale; RTT and variation; SSH compression setting' -- \
  --mode=suite --width=1100 --height=720 --fps=30 --seconds=30 --warmup=5
```

Repeat with `run-2.json` and `run-3.json`. Run the manual input stage separately:

```sh
python3 run.py --output=input-1.json --label='same environment as suite' -- \
  --mode=input --width=1100 --height=720 --seconds=60 --warmup=5
```

Report each run and the median/range across runs; do not hide a failing run in
an average. Investigate failures and repeat under controlled conditions before
accepting. The collector's `valid: true` means the benchmark completed
successfully; it does not automatically evaluate these acceptance thresholds.
Collected metrics are under `benchmark.results`; direct binary output uses
`results`.

### Application-side targets

Apply throughput and update-timing targets to `small` and `scroll`. Evaluate
`idle` and `input` separately; zero idle paint cycles are expected and valid.

| Criterion | Initial acceptance target |
| --- | --- |
| Correctness, all modes | No crash, corrupted pixels, stale regions, lost/duplicated input or input reordering |
| Idle CPU | `idle.cpu_percent_one_core` ≤1%; a few stage-entry/maintenance frames are allowed |
| Small-update and scrolling throughput | `gtk_paint_cycles_per_second` ≥27, or 90% of the 30-update/s target |
| Paint cadence | `after_paint_interval_ms.p95_upper` ≤50 ms |
| Update response | `request_to_after_paint_ms.p95_upper` ≤67 ms; recurring samples above 200 ms indicate stalls |
| Pending-update coalescing | `coalesced_requests / requests` ≤5%; this measures application-side accumulation, not packet loss |
| Input processing | `input_dispatch_to_after_paint_ms.p95_upper` ≤50 ms, with sufficient actual input samples |

P95 describes approximately the slowest boundary met by 95% of samples; a good
mean cannot compensate for poor tail latency. Check sample counts and maxima.
Null timing values and zero input samples do not establish an input pass. Aim
for at least 100 input timing samples, extending or repeating manual runs as
needed. Input timing samples may coalesce multiple dispatched events.
Inspect `unpainted_request` as well: the timed stage can end with one pending
update, which is excluded from completed latency samples.

Treat `full` as a stress characterization workload initially, without requiring
30 paint cycles/s. Record its throughput, stalls and CPU, then compare changes
on identical hardware. Set active CPU and memory budgets from the deployment's
capacity requirements. Investigate repeatable CPU or p95 regressions above 10%
against an established baseline, accounting for run-to-run variation.

### Client-visible acceptance

The application-side table alone cannot certify the forwarding experience.
GTK's [after-paint signal](https://docs.gtk.org/gdk3/signal.FrameClock.after-paint.html)
ends frame processing; [presentation time](https://docs.gtk.org/gdk3/method.FrameTimings.get_presentation_time.html)
is a separate measurement. Measure input and visible acknowledgement together
on the client, using suitable recording or external instrumentation.

- Input-to-visible-feedback p95: target ≤100 ms; 100–200 ms needs improvement;
  sustained values above 200 ms fail the proposed daily-terminal experience
  target. The 100 ms goal follows the general immediate-response guideline in
  [Nielsen's response-time limits](https://www.nngroup.com/articles/response-times-3-important-limits/);
  these acceptance bands are project choices, not a benchmark standard.
- Scrolling: continuous visible updates, without recurring freezes followed by
  large jumps. Application-side paint cycles are not verified display FPS.
- Memory: after warmup, a longer sustained run should approach a stable level
  instead of growing continuously. Sample current process memory over time;
  the collector's whole-run peak RSS alone cannot establish this.
- Bandwidth: measure the relevant SSH connection externally, with the same
  workload, rate and compression. JSON contains no wire-byte measurement.
  Compare small-region traffic with full updates and set a budget appropriate
  to the available link.

Accept the connection only after the controlled application-side runs and the
client-visible checks pass. Keep `--sync` results separate: synchronization
adds round-trip waiting and is diagnostic, not the normal-throughput gate.

## Developer checks without a visible window

```sh
python3 tools/build-x11-bench.py --native
zig-out/x11-bench-native/bin/nanoui-x11-bench --mode=scroll \
  --nanoui-snapshot=/tmp/nanoui-x11-scroll.png
```

The optional `zig build x11-bench` and `zig build test-x11-bench` steps also
build/check the tool directly; it is separate from the default examples.
The host build always uses portable CPU text/rendering. Unit checks exercise
argument validation, bounded histogram quantiles, workloads and private in-process
input with `ui.Tester`, plus the optional collector reporting checks. Screenshots
are functional checks; they bypass GTK/X11 presentation. Under a private Xvfb
on Linux, run a short live smoke test:

```sh
xvfb-run -a env GDK_BACKEND=x11 NANOUI_GTK=3 NANOUI_RENDERER=cpu \
  ./nanoui-x11-bench --seconds=1 --warmup=0 > xvfb-smoke.json
```

Cross-build/ABI checks, host snapshots and Xvfb are not CentOS 7.9 or real
X11/VDI performance acceptance. Keep the package manifest with target reports.
The Linux CI job includes the benchmark tests and a private Xvfb live smoke run.
For the repository's Linux test container, build `test-bin` and
`x11-bench-test-bin` for its architecture, then run `nanoui-tests` and
`nanoui-x11-bench-tests` there. A cross-built test executable is not evidence
that those tests ran.

The nanoui version of this benchmark measures this checkout's bounded CPU
backing/damage and GTK backend, the same implementation consumed by Letty. Earlier `letty-x11-bench` packages measure Letty's separate patched
source; keep those packages/manifests as historical evidence and do not mix
their results with this tool without recording that implementation difference.
