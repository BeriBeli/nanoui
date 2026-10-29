const std = @import("std");
const dbmod = @import("fontdb.zig");
const cluster = @import("cluster_fallback.zig");
const fixture = @import("cluster_fallback_fixture.zig");
const a = std.testing.allocator;
fn database() dbmod.Db {
    var db = dbmod.Db.init(a, std.testing.io);
    db.scanned = true; // never inspect the user's installed fonts in leaf tests
    return db;
}
fn add(db: *dbmod.Db, tmp: *std.testing.TmpDir, name: []const u8, spec: fixture.Face) !u32 {
    const blob = fixture.Blob.init(spec);
    const path = try blob.write(tmp, name);
    defer a.free(path);
    const id: u32 = @intCast(db.faces.items.len);
    db.addFile(path);
    try std.testing.expectEqual(id + 1, @as(u32, @intCast(db.faces.items.len)));
    return id;
}
// Private lookup is injected by fontdb's test declaration.
pub fn Suite(comptime choose: anytype) type {
    return struct {
        fn snapshot(db: *dbmod.Db, face: u32) ?struct { bytes: []const u8, index: u32, digest: [32]u8 } {
            const font = db.load(face) orelse return null;
            return .{ .bytes = font.data, .index = db.faces.items[face].index, .digest = db.loaded.get(face).?.digest };
        }
        test "two databases share TTC bytes across independent teardown" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const blob = fixture.Blob.collection(.{ .family = "First", .codepoints = &.{'a'} }, .{ .family = "Second", .codepoints = &.{0x4e2d} });
            const path = try blob.write(&tmp, "shared.ttc");
            defer a.free(path);
            var first = database();
            var first_live = true;
            defer if (first_live) first.deinit();
            var second = database();
            var second_live = true;
            defer if (second_live) second.deinit();
            first.addFile(path);
            second.addFile(path);
            const one = snapshot(&first, 0).?;
            const two = snapshot(&second, 1).?;
            try std.testing.expect(one.bytes.ptr == two.bytes.ptr);
            try std.testing.expect(one.index != two.index);
            const pool = @import("font_sources.zig");
            first.deinit();
            first_live = false;
            try std.testing.expect(second.load(1).?.glyphIndex(0x4e2d) != 0);
            second.deinit();
            second_live = false;
            try std.testing.expectEqual(@as(usize, 0), pool.bytes());
        }

        test "whole cluster never mixes a base-only and accent-only face" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var db = database();
            defer db.deinit();
            const primary = try add(&db, &tmp, "base.ttf", .{ .family = "Base", .codepoints = &.{'e'} });
            _ = try add(&db, &tmp, "accent.ttf", .{ .family = "Accent", .codepoints = &.{0x301} });
            const whole = try add(&db, &tmp, "whole.ttf", .{ .family = "Whole", .codepoints = &.{ 'e', 0x301 } });
            try std.testing.expectEqual(whole, choose(&db, primary, "e\xcc\x81", 400, false).?);
            try std.testing.expectEqual(primary, choose(&db, primary, "e", 400, false).?);
            // Same first codepoint and same UTF-8 length, different combining mark.
            try std.testing.expect(choose(&db, primary, "e\xcc\x80", 400, false) == null);
            try std.testing.expectEqual(dbmod.MissingReason.missing_glyph, db.stats().last_missing);
        }

        test "scalar fallback cache includes weight and cluster key includes italic and primary" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var db = database();
            defer db.deinit();
            const primary = try add(&db, &tmp, "base.ttf", .{ .family = "Base", .codepoints = &.{'e'} });
            const regular = try add(&db, &tmp, "regular.ttf", .{ .family = "Style", .codepoints = &.{0x4e2d} });
            const bold = try add(&db, &tmp, "bold.ttf", .{ .family = "Style", .weight = 700, .codepoints = &.{0x4e2d} });
            const italic = try add(&db, &tmp, "italic.ttf", .{ .family = "Style", .italic = true, .codepoints = &.{0x4e2d} });
            // Exercise style-key separation using already loaded candidates;
            // arbitrary fallback intentionally prefers fonts already in use.
            _ = db.load(regular).?;
            _ = db.load(bold).?;
            _ = db.load(italic).?;
            try std.testing.expectEqual(regular, db.fallback('中', 400).?);
            try std.testing.expectEqual(bold, db.fallback('中', 700).?);
            try std.testing.expectEqual(italic, choose(&db, primary, "中", 400, true).?);
            try std.testing.expectEqual(regular, choose(&db, primary, "中", 400, false).?);
            try std.testing.expectEqual(italic, choose(&db, italic, "中", 400, false).?);
            try std.testing.expectEqual(regular, db.fallback('中', 400).?);
        }

        test "ZWJ VS and controls do not demand cmap glyphs but visible emoji modifiers do" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var db = database();
            defer db.deinit();
            const face = try add(&db, &tmp, "emoji.ttf", .{ .family = "Coverage only", .codepoints = &.{ 0x2642, 0x1f481 } });
            try std.testing.expectEqual(face, choose(&db, face, "💁‍♂️", 400, false).?);
            try std.testing.expectEqual(face, choose(&db, face, "\x00\x1b\xe2\x80\x8d\xf3\xa0\x84\x80", 400, false).?);
            try std.testing.expect(choose(&db, face, "💁🏻‍♂️", 400, false) == null);
            try std.testing.expectEqual(dbmod.MissingReason.missing_glyph, db.stats().last_missing);
        }

        test "long clusters bypass cache without losing coverage and exceed 16KiB explicitly" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var db = database();
            defer db.deinit();
            const face = try add(&db, &tmp, "accent.ttf", .{ .family = "Whole", .codepoints = &.{ 'e', 0x301 } });
            var long: [401]u8 = undefined;
            long[0] = 'e';
            for (0..200) |i| @memcpy(long[1 + 2 * i ..][0..2], "\xcc\x81");
            try std.testing.expectEqual(face, choose(&db, face, &long, 400, false).?);
            try std.testing.expectEqual(@as(u32, 0), db.found.count());
            const huge = try a.alloc(u8, cluster.max_cluster_bytes + 1);
            defer a.free(huge);
            @memset(huge, 'e');
            try std.testing.expect(choose(&db, face, huge, 400, false) == null);
            try std.testing.expectEqual(dbmod.MissingReason.cluster_limit, db.stats().last_missing);
            try std.testing.expectEqual(dbmod.Limit.cluster_bytes, db.stats().last_limit.?);
            try std.testing.expect(choose(&db, face, "\xff", 400, false) == null);
            try std.testing.expectEqual(dbmod.MissingReason.invalid_utf8, db.stats().last_missing);
        }

        test "source is identical registered bytes with cached whole-file digest and real TTC index" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const blob = fixture.Blob.collection(.{ .family = "First", .codepoints = &.{'a'} }, .{ .family = "Second", .codepoints = &.{0x4e2d} });
            const path = try blob.write(&tmp, "faces.ttc");
            defer a.free(path);
            var db = database();
            defer db.deinit();
            db.addFile(path);
            try std.testing.expectEqual(@as(usize, 2), db.faces.items.len);
            const loaded = db.load(1).?;
            const source = snapshot(&db, 1).?;
            try std.testing.expectEqual(@as(u32, 1), source.index);
            try std.testing.expect(source.bytes.ptr == loaded.data.ptr);
            try std.testing.expectEqualSlices(u8, blob.data[0..blob.len], source.bytes);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(source.bytes, &digest, .{});
            try std.testing.expectEqualSlices(u8, &digest, &source.digest);
            try std.testing.expectEqualSlices(u8, &source.digest, &snapshot(&db, 1).?.digest);
            try std.testing.expect(db.load(9999) == null and snapshot(&db, 9999) == null);
        }

        test "load hashmap allocation failure frees source and Loaded and never returns an unregistered pointer" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const blob = fixture.Blob.init(.{ .family = "Fault", .codepoints = &.{'e'} });
            const path = try blob.write(&tmp, "fault.ttf");
            defer a.free(path);
            var failing = std.testing.FailingAllocator.init(a, .{});
            var db = dbmod.Db.init(failing.allocator(), std.testing.io);
            defer db.deinit();
            db.scanned = true;
            db.addFile(path);
            try std.testing.expectEqual(@as(usize, 1), db.faces.items.len);
            // Immutable source storage has an independent lifetime. Db owns Loaded,
            // then its first map table; Linux also allocates a temporary path sentinel.
            failing.fail_index = failing.alloc_index + (if (@import("builtin").os.tag == .linux) @as(usize, 2) else 1);
            const allocated_before = failing.allocated_bytes;
            const freed_before = failing.freed_bytes;
            try std.testing.expect(db.load(0) == null);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(failing.allocated_bytes - allocated_before, failing.freed_bytes - freed_before);
            try std.testing.expectEqual(@as(u32, 0), db.loaded.count());
            try std.testing.expectEqual(@as(usize, 0), db.stats().loaded_bytes);
            try std.testing.expectEqual(@as(usize, 0), @import("font_sources.zig").bytes());
            try std.testing.expectEqual(dbmod.MissingReason.out_of_memory, db.stats().last_missing);
            failing.fail_index = std.math.maxInt(usize);
            try std.testing.expect(db.load(0) != null);
            try std.testing.expectEqual(@as(u32, 1), db.loaded.count());
        }

        test "source length and aggregate quotas reject before allocation without evicting old pointers" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const blob = fixture.Blob.init(.{ .family = "Budget", .codepoints = &.{'e'} });
            const path = try blob.write(&tmp, "small.ttf");
            defer a.free(path);
            var db = database();
            defer db.deinit();
            db.addFile(path);
            const original = db.load(0).?;
            const source = snapshot(&db, 0).?;
            // An explicit remaining-budget boundary, without allocating 128MiB merely
            // to test the arithmetic. Existing fonts remain available at the limit.
            db.metrics.loaded_bytes = dbmod.Limits.loaded_bytes;
            const duplicate = try a.dupe(u8, path);
            try db.faces.append(a, .{ .path = duplicate, .index = 0, .style = db.faces.items[0].style });
            try std.testing.expect(db.load(1) == null);
            try std.testing.expectEqual(dbmod.Limit.loaded_bytes, db.stats().last_limit.?);
            try std.testing.expect(db.load(0).? == original);
            try std.testing.expect(snapshot(&db, 0).?.bytes.ptr == source.bytes.ptr);
            var huge = try tmp.dir.createFile(std.testing.io, "large.ttf", .{});
            try huge.setLength(std.testing.io, dbmod.Limits.source_bytes + 1);
            huge.close(std.testing.io);
            const large_path = try tmp.dir.realPathFileAlloc(std.testing.io, "large.ttf", a);
            defer a.free(large_path);
            db.addFile(large_path);
            try std.testing.expectEqual(dbmod.Limit.source_bytes, db.stats().last_limit.?);
            try std.testing.expectEqual(@as(usize, 2), db.faces.items.len);
        }

        test "TTC face count scan file count and lookup cache stay bounded" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var db = database();
            defer db.deinit();
            var invalid: [12]u8 = @splat(0);
            @memcpy(invalid[0..4], "ttcf");
            std.mem.writeInt(u32, invalid[8..12], 0xffffffff, .big);
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "many.ttc", .data = &invalid });
            const path = try tmp.dir.realPathFileAlloc(std.testing.io, "many.ttc", a);
            defer a.free(path);
            db.addFile(path);
            try std.testing.expectEqual(dbmod.Limit.collection_faces, db.stats().last_limit.?);
            const face = try add(&db, &tmp, "base.ttf", .{ .family = "Base", .codepoints = &.{'e'} });
            for (0..cluster.max_entries + 8) |i| {
                var utf8: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(@intCast(0x4000 + i), &utf8);
                try std.testing.expect(choose(&db, face, utf8[0..n], 400, false) == null);
                try std.testing.expect(db.found.count() <= cluster.max_entries);
            }
            try std.testing.expectEqual(dbmod.Limit.lookup_entries, db.stats().last_limit.?);
            db.metrics.scanned_files = dbmod.Limits.scan_files;
            db.addFile(path);
            try std.testing.expectEqual(dbmod.Limit.scan_files, db.stats().last_limit.?);
        }

        test "arbitrary font probes stop at budget and newly loaded coverage invalidates negative cache" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var db = database();
            defer db.deinit();
            const primary = try add(&db, &tmp, "base.ttf", .{ .family = "Primary", .codepoints = &.{'e'} });
            const base = db.faces.items[primary];
            for (0..dbmod.Limits.arbitrary_probes) |i| {
                var style = base.style;
                const name = try std.fmt.bufPrint(&style.family, "Absent{d}", .{i});
                style.family_len = @intCast(name.len);
                try db.faces.append(a, .{ .path = try a.dupe(u8, base.path), .index = 0, .style = style });
            }
            const target = try add(&db, &tmp, "target.ttf", .{ .family = "Untried", .codepoints = &.{0x4e2d} });
            try std.testing.expect(choose(&db, primary, "中", 400, false) == null);
            try std.testing.expectEqual(dbmod.MissingReason.probe_limit, db.stats().last_missing);
            try std.testing.expect(!db.loaded.contains(target));
            _ = snapshot(&db, target).?;
            try std.testing.expectEqual(target, choose(&db, primary, "中", 400, false).?);
        }

        test "real pinned OpenSans and CJK TrueType sources retain exact data and cluster coverage" {
            var db = database();
            defer db.deinit();
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const latin = @embedFile("testdata/OpenSans-Regular.ttf");
            const original = @embedFile("testdata/Mplus1p-Regular.660E,6975,73E0,5EA6,8F38,6E05.ttf");
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "latin.ttf", .data = latin });
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cjk.ttf", .data = original });
            const latin_path = try tmp.dir.realPathFileAlloc(std.testing.io, "latin.ttf", a);
            defer a.free(latin_path);
            const cjk_path = try tmp.dir.realPathFileAlloc(std.testing.io, "cjk.ttf", a);
            defer a.free(cjk_path);
            db.addFile(latin_path);
            db.addFile(cjk_path);
            try std.testing.expectEqual(@as(usize, 2), db.faces.items.len);
            try std.testing.expectEqual(@as(u32, 0), choose(&db, 0, "e\xcc\x81", 400, false).?);
            try std.testing.expectEqual(@as(u32, 1), choose(&db, 0, "明", 400, false).?);
            try std.testing.expect(db.load(0).?.glyphIndex('明') == 0);
            const source = snapshot(&db, 1).?;
            try std.testing.expectEqualSlices(u8, original, source.bytes);
            try std.testing.expect(source.bytes.ptr == db.load(1).?.data.ptr);
            try std.testing.expectEqual(@as(u32, 0), source.index);
        }

        test "malformed table offsets and cmap offsets reject without overflow or partial registration" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var bad_table = fixture.Blob.init(.{ .family = "Bad table", .codepoints = &.{'e'} });
            std.mem.writeInt(u32, bad_table.data[20..24], 0xfffffffe, .big);
            const table_path = try bad_table.write(&tmp, "bad-table.ttf");
            defer a.free(table_path);
            var db = database();
            defer db.deinit();
            db.addFile(table_path);
            try std.testing.expectEqual(@as(usize, 0), db.faces.items.len);
            var bad_cmap = fixture.Blob.init(.{ .family = "Bad cmap", .codepoints = &.{'e'} });
            const t = try @import("font.zig").Tables.read(bad_cmap.data[0..bad_cmap.len], 0);
            std.mem.writeInt(u32, bad_cmap.data[t.cmap + 8 ..][0..4], 0xfffffff0, .big);
            const cmap_path = try bad_cmap.write(&tmp, "bad-cmap.ttf");
            defer a.free(cmap_path);
            db.addFile(cmap_path);
            try std.testing.expectEqual(@as(usize, 1), db.faces.items.len);
            try std.testing.expect(db.load(0) == null);
            try std.testing.expectEqual(dbmod.MissingReason.invalid_font, db.stats().last_missing);
            try std.testing.expectEqual(@as(u32, 0), db.loaded.count());
        }

        test "loaded face quota preserves all previously registered font pointers" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var db = database();
            defer db.deinit();
            _ = try add(&db, &tmp, "base.ttf", .{ .family = "Quota", .codepoints = &.{'e'} });
            const first = db.faces.items[0];
            for (0..dbmod.Limits.loaded_faces) |_| {
                try db.faces.append(a, .{ .path = try a.dupe(u8, first.path), .index = 0, .style = first.style });
            }
            const pointer = db.load(0).?;
            for (1..dbmod.Limits.loaded_faces) |i| try std.testing.expect(db.load(@intCast(i)) != null);
            try std.testing.expect(db.load(dbmod.Limits.loaded_faces) == null);
            try std.testing.expectEqual(dbmod.Limit.loaded_faces, db.stats().last_limit.?);
            try std.testing.expectEqual(dbmod.Limits.loaded_faces, db.stats().loaded_faces);
            try std.testing.expect(db.load(0).? == pointer);
            try std.testing.expect(snapshot(&db, 0).?.bytes.ptr == pointer.data.ptr);
        }

        test "large coverage misses release private candidates keep negative caches and leave room for a real new font" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var db = database();
            defer db.deinit();
            const primary = try add(&db, &tmp, "probe.ttf", .{ .family = "Pinned", .codepoints = &.{'e'} });
            const original = db.faces.items[primary];
            const large = try tmp.dir.createFile(std.testing.io, "probe.ttf", .{ .truncate = false });
            try large.setLength(std.testing.io, 4 << 20);
            large.close(std.testing.io);
            const pinned_font = db.load(primary).?;
            const pinned_source = snapshot(&db, primary).?;
            for (0..dbmod.Limits.arbitrary_probes) |i| {
                var style = original.style;
                const name = try std.fmt.bufPrint(&style.family, "Probe{d}", .{i});
                style.family_len = @intCast(name.len);
                try db.faces.append(a, .{ .path = try a.dupe(u8, original.path), .index = 0, .style = style });
            }
            const missing_a = "\xf4\x8f\xbf\xbf";
            const missing_b = "\xf4\x8f\xbf\xbe";
            try std.testing.expect(choose(&db, primary, missing_a, 400, false) == null);
            try std.testing.expect(choose(&db, primary, missing_b, 400, false) == null);
            const probes = db.stats().probe_releases;
            try std.testing.expectEqual(2 * dbmod.Limits.arbitrary_probes, probes);
            try std.testing.expect(db.stats().probe_released_bytes > dbmod.Limits.loaded_bytes);
            try std.testing.expectEqual(@as(usize, 4 << 20), db.stats().loaded_bytes);
            try std.testing.expectEqual(@as(usize, 1), db.stats().loaded_faces);
            try std.testing.expectEqual(@as(usize, 2), db.stats().lookup_entries);
            for (0..8) |_| {
                try std.testing.expect(choose(&db, primary, missing_a, 400, false) == null);
                try std.testing.expect(choose(&db, primary, missing_b, 400, false) == null);
            }
            try std.testing.expectEqual(probes, db.stats().probe_releases);
            try std.testing.expectEqual(@as(usize, 2), db.stats().lookup_entries);
            // Use the same immutable real font on every host. Missing candidates must
            // release their private snapshots so this new face still fits the budget.
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real.ttf", .data = @embedFile("testdata/OpenSans-Regular.ttf") });
            const path = try tmp.dir.realPathFileAlloc(std.testing.io, "real.ttf", a);
            defer a.free(path);
            const next: u32 = @intCast(db.faces.items.len);
            db.addFile(path);
            try std.testing.expectEqual(next + 1, @as(u32, @intCast(db.faces.items.len)));
            const added_font = db.load(next).?;
            try std.testing.expect(added_font.glyphIndex('f') != 0 and added_font.glyphIndex('i') != 0);
            try std.testing.expect(snapshot(&db, next) != null);
            try std.testing.expect(db.load(primary).? == pinned_font);
            const after = snapshot(&db, primary).?;
            try std.testing.expect(after.bytes.ptr == pinned_source.bytes.ptr);
            try std.testing.expectEqualSlices(u8, &pinned_source.digest, &after.digest);
        }

        test "temporary probe allocation failures never remove a published source or leak partial candidate data" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const blob = fixture.Blob.init(.{ .family = "Pinned", .codepoints = &.{'e'} });
            const path = try blob.write(&tmp, "fault-probe.ttf");
            defer a.free(path);
            // Candidate Loaded and negative-lookup table; Linux also needs the path.
            for (0..if (@import("builtin").os.tag == .linux) @as(usize, 3) else 2) |offset| {
                var failing = std.testing.FailingAllocator.init(a, .{});
                var db = dbmod.Db.init(failing.allocator(), std.testing.io);
                defer db.deinit();
                db.scanned = true;
                db.addFile(path);
                const pinned_font = db.load(0).?;
                const pinned_source = snapshot(&db, 0).?;
                var style = db.faces.items[0].style;
                @memcpy(style.family[0..5], "Probe");
                style.family_len = 5;
                try db.faces.append(db.gpa, .{ .path = try db.gpa.dupe(u8, path), .index = 0, .style = style });
                failing.fail_index = failing.alloc_index + offset;
                try std.testing.expect(choose(&db, 0, "中", 400, false) == null);
                try std.testing.expect(failing.has_induced_failure);
                try std.testing.expectEqual(@as(usize, 1), db.stats().loaded_faces);
                try std.testing.expectEqual(pinned_source.bytes.len, db.stats().loaded_bytes);
                try std.testing.expect(db.load(0).? == pinned_font);
                try std.testing.expect(snapshot(&db, 0).?.bytes.ptr == pinned_source.bytes.ptr);
                failing.fail_index = std.math.maxInt(usize);
            }
        }

        test "stable invalid font candidates retain diagnostic negative caches without repeated reads" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var db = database();
            defer db.deinit();
            const primary = try add(&db, &tmp, "base.ttf", .{ .family = "Pinned", .codepoints = &.{'e'} });
            _ = db.load(primary).?;
            var broken = fixture.Blob.init(.{ .family = "Broken cmap", .codepoints = &.{'e'} });
            const tables = try @import("font.zig").Tables.read(broken.data[0..broken.len], 0);
            std.mem.writeInt(u32, broken.data[tables.cmap + 8 ..][0..4], 0xfffffff0, .big);
            const path = try broken.write(&tmp, "broken.ttf");
            defer a.free(path);
            db.addFile(path);
            try std.testing.expect(choose(&db, primary, "中", 400, false) == null);
            try std.testing.expect(choose(&db, primary, "文", 400, false) == null);
            const failed = db.stats().failed_loads;
            try std.testing.expectEqual(@as(usize, 2), db.stats().lookup_entries);
            for (0..8) |_| {
                try std.testing.expect(choose(&db, primary, "中", 400, false) == null);
                try std.testing.expect(choose(&db, primary, "文", 400, false) == null);
                try std.testing.expectEqual(dbmod.MissingReason.invalid_font, db.stats().last_missing);
            }
            try std.testing.expectEqual(failed, db.stats().failed_loads);
        }

        test "registered memory fonts share owned sources and respect load budgets" {
            var blob = fixture.Blob.init(.{ .family = "Bundled", .codepoints = &.{'a'} });
            var first = database();
            defer first.deinit();
            var second = database();
            defer second.deinit();
            first.addMemory(blob.data[0..blob.len]);
            second.addMemory(blob.data[0..blob.len]);
            try std.testing.expectEqual(@as(usize, 1), first.faces.items.len);
            try std.testing.expectEqual(@as(u32, 0), first.family("Bundled", 400, false).?);
            const one = snapshot(&first, 0).?;
            const two = snapshot(&second, 0).?;
            try std.testing.expect(one.bytes.ptr == two.bytes.ptr);
            try std.testing.expect(one.bytes.ptr != blob.data[0..].ptr);
            blob.data[0] = 0xff;
            try std.testing.expectEqual(@as(u8, 0), one.bytes[0]);

            var limited = database();
            defer limited.deinit();
            limited.addMemory(two.bytes);
            limited.metrics.loaded_bytes = dbmod.Limits.loaded_bytes;
            try std.testing.expect(limited.load(0) == null);
            try std.testing.expectEqual(dbmod.Limit.loaded_bytes, limited.stats().last_limit.?);
            try std.testing.expectEqual(@as(usize, 0), limited.loaded.count());
        }

        test "registered memory fonts reject malformed collections and bound face counts" {
            var db = database();
            defer db.deinit();
            db.addMemory("short");
            try std.testing.expectEqual(@as(usize, 0), db.faces.items.len);
            try std.testing.expectEqual(dbmod.MissingReason.invalid_font, db.stats().last_missing);
            var bad = [_]u8{ 't', 't', 'c', 'f', 0, 1, 0, 0, 0xff, 0xff, 0xff, 0xff };
            db.addMemory(&bad);
            try std.testing.expectEqual(dbmod.Limit.collection_faces, db.stats().last_limit.?);
            const blob = fixture.Blob.init(.{ .family = "Bounded", .codepoints = &.{'a'} });
            for (0..dbmod.Limits.faces + 1) |_| db.addMemory(blob.data[0..blob.len]);
            try std.testing.expectEqual(dbmod.Limits.faces, db.faces.items.len);
            try std.testing.expectEqual(dbmod.Limit.faces, db.stats().last_limit.?);
        }
    };
}
