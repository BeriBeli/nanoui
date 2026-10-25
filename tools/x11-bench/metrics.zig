const std = @import("std");

// Fixed histograms avoid retaining per-frame samples. Percentiles are upper
// bin edges (1 ms resolution through 2 s), with an explicit overflow count.
pub const Histogram = struct {
    bins: [2001]u32 = @splat(0),
    count: u64 = 0,
    sum: f64 = 0,
    max: f64 = 0,
    overflow: u64 = 0,

    pub fn add(self: *Histogram, ms: f64) void {
        if (!std.math.isFinite(ms) or ms < 0) return;
        self.count += 1;
        self.sum += ms;
        self.max = @max(self.max, ms);
        if (ms > 2000) self.overflow += 1 else self.bins[@intFromFloat(@ceil(ms))] += 1;
    }
    fn percentile(self: *const Histogram, fraction: f64) ?f64 {
        if (self.count == 0) return null;
        const target: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(self.count)) * fraction));
        var total: u64 = 0;
        for (self.bins, 0..) |n, i| {
            total += n;
            if (total >= target) return @floatFromInt(i);
        }
        return self.max;
    }
    pub fn report(self: *const Histogram) Report {
        return .{ .count = self.count, .mean = if (self.count == 0) null else self.sum / @as(f64, @floatFromInt(self.count)), .p50_upper = self.percentile(0.50), .p95_upper = self.percentile(0.95), .max = if (self.count == 0) null else self.max, .over_2000_ms = self.overflow };
    }
    pub const Report = struct { count: u64, mean: ?f64, p50_upper: ?f64, p95_upper: ?f64, max: ?f64, over_2000_ms: u64 };
};

pub fn cpuSeconds() f64 {
    var t: std.c.timespec = undefined;
    if (std.c.clock_gettime(.PROCESS_CPUTIME_ID, &t) != 0) return 0;
    return @as(f64, @floatFromInt(t.sec)) + @as(f64, @floatFromInt(t.nsec)) / 1e9;
}

test "bounded histograms handle empty sets, quantiles and overflow" {
    var h: Histogram = .{};
    try std.testing.expect(h.report().mean == null);
    h.add(0.2);
    h.add(10.2);
    h.add(3000);
    h.add(std.math.nan(f64));
    const r = h.report();
    try std.testing.expectEqual(@as(u64, 3), r.count);
    try std.testing.expectEqual(@as(f64, 11), r.p50_upper.?);
    try std.testing.expectEqual(@as(f64, 3000), r.p95_upper.?);
    try std.testing.expectEqual(@as(u64, 1), r.over_2000_ms);
}
