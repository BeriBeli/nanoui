# macOS interaction and presentation

The macOS surface uses `CADisplayLink` to pace active animation. It acquires
its Metal drawable only when rendering. A `CAMetalDisplayLink` can reserve a
drawable before AppKit changes the window geometry; delaying its presentation
until a later callback separates new window geometry from new pixels.

The Metal layer delegates `displayLayer:` to the surface and requests display
when its bounds change. Resize builds and presents in that Core Animation
transaction, including programmatic resize, zoom and tiling. Live resize pauses
the animation link; the layer owns rendering until the final synchronous frame
at `viewDidEndLiveResize`. Equal-size notifications do no work. A reentrant
geometry change during UI construction discards that layout and requests a new
one. Teardown clears the delegate and invalidates the display link.

The renderer still rejects supplied drawables whose pixel dimensions differ
from the layer's current `drawableSize`. A failed presentation retains its
pending resize transaction for retry. Direct acquisition also restores the
renderer contract used by UIKit surfaces, which do not supply a drawable.

UI wake deadlines such as cursor blinks are independent of display cadence.
Distant deadlines pause the link and arm one owned `NSTimer` in common run-loop
modes. Input cancels that timer immediately. Near deadlines and GPU animation
keep the link active. Teardown cancels the timer, and callbacks revalidate its
identity. Older macOS without the view display-link API uses the same deadline
timer and bounded animation tick fallback.

`tests_surface_resize.zig` drives the actual NSView and layer callbacks through
repeated size changes, checks transaction ownership and successful presentation,
requires a final frame without further input, and rejects a mid-build resize.
`tests_drawable_size.zig` checks a stale 1×1 supplied target and recovery.
`tests_surface_pacing.zig` checks the real display link, input wakeup, near
UI deadlines, GPU animation, cancellation and an actual run-loop timer callback.
All use private objects without showing a window or posting system input.

These checks establish scheduling and presentation contracts. Physical-window
acceptance still requires resize, hover, scroll, and native panels on the
display where an artifact was reported.
