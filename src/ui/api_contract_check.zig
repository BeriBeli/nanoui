//! Guard the upstream application boundary while retaining private fixes.
const std = @import("std");
const ui = @import("ui.zig");
const input = @import("input.zig");
const TextSystem = @import("text.zig").TextSystem;
test "historical product extensions are absent from the framework API" {
    inline for (.{ "FontFeature", "gridText", "FontSources", "CpuDamage", "gpu" }) |name|
        try std.testing.expect(!@hasDecl(ui, name));
    inline for (.{ "gridLayout", "shapeGrid", "setFallbacks", "setRunShaper" }) |name|
        try std.testing.expect(!@hasDecl(TextSystem, name));
    inline for (.{ "mouse_button", "scroll_lines", "scroll_started" }) |name|
        try std.testing.expect(!@hasField(input.Input, name));
    try std.testing.expect(!@hasField(input.FocusedText, "editable"));
    try std.testing.expect(!@hasField(ui.TextStyle, "features"));
    try std.testing.expect(!@hasField(ui.Context, "points_to_logical"));
    try std.testing.expect(!@hasDecl(ui.Tester, "findGridCell"));
    if (comptime @import("builtin").os.tag == .macos)
        try std.testing.expect(!@hasDecl(ui.Surface, "glyphAtlasTexture"));
    inline for (.{ "source", "clusterFace", "setFallbacks", "sharedSourceBytes" }) |name|
        try std.testing.expect(!@hasDecl(@import("tt/fontdb.zig").Db, name));
    try std.testing.expect(!@hasDecl(@import("tt/font_sources.zig"), "retain"));
    try std.testing.expectEqual(@as(input.Button, .left), (input.Input{}).button);
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(ui.Weight).@"enum".field_names.len);
}
