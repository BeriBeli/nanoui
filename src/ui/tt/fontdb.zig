//! The fonts installed: found in the system's font folders once, each
//! face known by its family, weight, italics and width, and loaded when
//! first used. Matching a style picks the family's nearest face; a
//! character a font lacks is found in the fallback families, then in any
//! face that has it.
const std = @import("std");
const builtin = @import("builtin");
const font = @import("font.zig");
const files = @import("file_io.zig");
const cluster = @import("cluster_fallback.zig");
const bounds = @import("cluster_fallback_bounds.zig");
const sources = @import("font_sources.zig");
pub const MissingReason = cluster.MissingReason;
pub const Limits = struct {
    pub const source_bytes = 64 << 20;
    pub const loaded_bytes = 128 << 20;
    pub const loaded_faces = 128;
    pub const faces = 4096;
    pub const collection_faces = 256;
    pub const scan_files = 8192;
    pub const directory_entries = 32768;
    pub const fallback_names = 32;
    pub const family_bytes = 256;
    pub const path_bytes = 4096;
    pub const arbitrary_probes = 48;
};
pub const Limit = enum { source_bytes, loaded_bytes, loaded_faces, faces, collection_faces, scan_files, directory_entries, fallback_names, family_bytes, path_bytes, lookup_entries, cluster_bytes };
pub const Source = struct { bytes: []const u8, index: u32, digest: [32]u8 };
pub const Stats = struct {
    faces: usize = 0,
    scanned_files: usize = 0,
    loaded_faces: usize = 0,
    loaded_bytes: usize = 0,
    lookup_entries: usize = 0,
    fallback_names: usize = 0,
    generation: u64 = 1,
    limit_hits: u64 = 0,
    cache_resets: u64 = 0,
    failed_loads: u64 = 0,
    probe_releases: u64 = 0,
    probe_released_bytes: u64 = 0,
    last_limit: ?Limit = null,
    last_missing: MissingReason = .none,
};

pub const Face = struct {
    path: []const u8,
    index: u32,
    style: font.Style,
    /// A font the app brought (`ui.registerFont`): its bytes, not a file.
    memory: ?[]const u8 = null,
};

const Loaded = struct {
    data: []const u8,
    source: *sources.Source,
    font: font.Font,
    digest: [32]u8,
};

const android = builtin.abi.isAndroid();
/// Families tried when the theme names none (or one not installed):
/// Android's own first there.
const sans = (if (android) [_][]const u8{"Roboto"} else [_][]const u8{}) ++ [_][]const u8{ "Inter", "Geist", "Segoe UI", "Noto Sans", "Cantarell", "Ubuntu", "DejaVu Sans", "Liberation Sans", "Arial", "Helvetica" };
const monos = (if (android) [_][]const u8{ "Droid Sans Mono", "Cutive Mono" } else [_][]const u8{}) ++ [_][]const u8{ "JetBrains Mono", "Geist Mono", "Cascadia Mono", "Consolas", "Noto Sans Mono", "DejaVu Sans Mono", "Ubuntu Mono", "Liberation Mono", "Menlo", "Courier New" };
/// Where characters a font lacks are looked for first.
const fallbacks = [_][]const u8{ "WenQuanYi Zen Hei", "Noto Sans CJK SC", "Noto Sans SC", "Noto Sans", "DejaVu Sans", "Segoe UI Symbol", "Noto Sans Symbols", "Noto Sans Symbols2", "Arial Unicode MS", "Symbola" };

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn env(name: [*:0]const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    const v = getenv(name) orelse return null;
    return std.mem.span(v);
}

pub const Db = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    faces: std.ArrayList(Face) = .empty,
    loaded: std.AutoHashMapUnmanaged(u32, *Loaded) = .empty,
    scanned: bool = false,
    /// Keys own the entire small cluster, primary, weight, italic and generation.
    found: std.AutoHashMapUnmanaged(cluster.Key, cluster.Result) = .empty,
    fallback_names: []const []const u8 = &.{},
    generation: u64 = 1,
    metrics: Stats = .{},
    bundled: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Db {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(db: *Db) void {
        for (db.faces.items) |f| db.gpa.free(f.path);
        db.faces.deinit(db.gpa);
        var it = db.loaded.valueIterator();
        while (it.next()) |l| {
            sources.release(l.*.source);
            db.gpa.destroy(l.*);
        }
        db.loaded.deinit(db.gpa);
        db.found.deinit(db.gpa);
        for (db.fallback_names) |name| db.gpa.free(name);
        if (db.fallback_names.len != 0) db.gpa.free(db.fallback_names);
    }

    pub fn stats(db: *const Db) Stats {
        var result = db.metrics;
        result.faces = db.faces.items.len;
        result.loaded_faces = db.loaded.count();
        result.lookup_entries = db.found.count();
        result.fallback_names = db.fallback_names.len;
        result.generation = db.generation;
        return result;
    }
    pub fn sharedSourceBytes(_: *const Db) usize {
        return sources.bytes();
    }

    fn limit(db: *Db, value: Limit) void {
        db.metrics.last_limit = value;
        db.metrics.limit_hits +|= 1;
        db.metrics.last_missing = .resource_limit;
    }

    fn clearLookup(db: *Db) void {
        db.found.clearRetainingCapacity();
        db.metrics.cache_resets +|= 1;
    }

    /// Transactional owned copies. Content-equal updates do not allocate or
    /// invalidate caches; allocation/validation failure preserves the old list.
    pub fn setFallbacks(db: *Db, names: []const []const u8) !bool {
        if (names.len > Limits.fallback_names) {
            db.limit(.fallback_names);
            return error.TooManyFallbacks;
        }
        var same = names.len == db.fallback_names.len;
        for (names, 0..) |name, i| {
            if (name.len == 0 or name.len > Limits.family_bytes or std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) {
                db.limit(.family_bytes);
                return error.InvalidFallbackFamily;
            }
            if (same and !std.mem.eql(u8, name, db.fallback_names[i])) same = false;
        }
        if (same) return false;
        if (db.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        const owned = try db.gpa.alloc([]const u8, names.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |name| db.gpa.free(name);
            db.gpa.free(owned);
        }
        for (names, 0..) |name, i| {
            owned[i] = try db.gpa.dupe(u8, name);
            initialized += 1;
        }
        for (db.fallback_names) |name| db.gpa.free(name);
        if (db.fallback_names.len != 0) db.gpa.free(db.fallback_names);
        db.fallback_names = owned;
        db.generation += 1;
        db.clearLookup();
        return true;
    }

    /// Adds the faces of fonts the app registered since last asked.
    fn addBundled(db: *Db) void {
        const all = @import("../font_registry.zig").registered();
        while (db.bundled < all.len) : (db.bundled += 1) db.addMemory(all[db.bundled]);
    }

    /// Adds the faces of a font file's bytes, kept by the caller.
    pub fn addMemory(db: *Db, data: []const u8) void {
        if (data.len < 12) {
            db.metrics.last_missing = .invalid_font;
            return;
        }
        if (data.len > Limits.source_bytes) {
            db.limit(.source_bytes);
            return;
        }
        const count = font.faces(data);
        if (count > Limits.collection_faces) {
            db.limit(.collection_faces);
            return;
        }
        for (0..count) |i| {
            if (db.faces.items.len >= Limits.faces) {
                db.limit(.faces);
                break;
            }
            const t = bounds.tables(data, @intCast(i)) catch continue;
            const style = font.Style.read(data, t);
            if (style.family_len == 0) continue;
            const owned = db.gpa.dupe(u8, "") catch return;
            db.faces.append(db.gpa, .{ .path = owned, .index = @intCast(i), .style = style, .memory = data }) catch {
                db.gpa.free(owned);
                return;
            };
            db.clearLookup();
        }
    }

    /// Adds the faces of the fonts in the system's font folders, after
    /// those the app brought.
    pub fn scan(db: *Db) void {
        db.addBundled();
        if (db.scanned) return;
        db.scanned = true;
        var buf: [1024]u8 = undefined;
        switch (builtin.os.tag) {
            .windows => {
                db.scanDir("C:\\Windows\\Fonts");
                // Under Wine, the Linux system's fonts are on drive Z:.
                if (db.faces.items.len < 8) db.scanDir("Z:\\usr\\share\\fonts");
            },
            .macos => {
                for ([_][]const u8{ "/System/Library/Fonts", "/Library/Fonts" }) |d| db.scanDir(d);
                if (env("HOME")) |home| db.scanDir(std.fmt.bufPrint(&buf, "{s}/Library/Fonts", .{home}) catch return);
            },
            else => if (android) {
                for ([_][]const u8{ "/system/fonts", "/product/fonts" }) |d| db.scanDir(d);
            } else {
                for ([_][]const u8{ "/usr/share/fonts", "/usr/local/share/fonts" }) |d| db.scanDir(d);
                if (env("HOME")) |home| {
                    db.scanDir(std.fmt.bufPrint(&buf, "{s}/.local/share/fonts", .{home}) catch return);
                    db.scanDir(std.fmt.bufPrint(&buf, "{s}/.fonts", .{home}) catch return);
                }
            },
        }
    }

    pub fn scanDir(db: *Db, path: []const u8) void {
        if (path.len > Limits.path_bytes) {
            db.limit(.path_bytes);
            return;
        }
        if (builtin.os.tag == .linux and !android) {
            files.scan(path, db, struct {
                fn found(ctx: *anyopaque, p: []const u8) void {
                    const d: *Db = @ptrCast(@alignCast(ctx));
                    d.addFile(p);
                }
            }.found);
            return;
        }
        var dir = std.Io.Dir.cwd().openDir(db.io, path, .{ .iterate = true }) catch return;
        defer dir.close(db.io);
        var walker = dir.walk(db.gpa) catch return;
        defer walker.deinit();
        var entries: usize = 0;
        while (walker.next(db.io) catch null) |e| {
            entries += 1;
            if (entries > Limits.directory_entries) {
                db.limit(.directory_entries);
                break;
            }
            if (e.kind != .file and e.kind != .sym_link) continue;
            const ext = std.fs.path.extension(e.basename);
            if (!std.ascii.eqlIgnoreCase(ext, ".ttf") and !std.ascii.eqlIgnoreCase(ext, ".ttc")) continue;
            var full: [1024]u8 = undefined;
            const p = std.fmt.bufPrint(&full, "{s}{c}{s}", .{ path, std.fs.path.sep, e.path }) catch continue;
            db.addFile(p);
        }
    }

    /// Reads only bounded TrueType sources; TTC counts are checked before the
    /// loop. The full bounded buffer avoids reading uninitialized table pages.
    pub fn addFile(db: *Db, path: []const u8) void {
        if (db.metrics.scanned_files >= Limits.scan_files) {
            db.limit(.scan_files);
            return;
        }
        db.metrics.scanned_files += 1;
        if (path.len > Limits.path_bytes) {
            db.limit(.path_bytes);
            return;
        }
        if (db.faces.items.len >= Limits.faces) {
            db.limit(.faces);
            return;
        }
        for (db.faces.items) |face| if (std.mem.eql(u8, face.path, path)) return;
        const data = db.readBounded(path, Limits.source_bytes) orelse return;
        defer db.gpa.free(data);
        const count = font.faces(data);
        if (count > Limits.collection_faces) {
            db.limit(.collection_faces);
            return;
        }
        for (0..count) |i| {
            if (db.faces.items.len >= Limits.faces) {
                db.limit(.faces);
                break;
            }
            const t = bounds.tables(data, @intCast(i)) catch continue;
            const style = font.Style.read(data, t);
            if (style.family_len == 0) continue;
            const owned = db.gpa.dupe(u8, path) catch {
                db.metrics.last_missing = .out_of_memory;
                return;
            };
            db.faces.append(db.gpa, .{ .path = owned, .index = @intCast(i), .style = style }) catch {
                db.gpa.free(owned);
                db.metrics.last_missing = .out_of_memory;
                return;
            };
            db.clearLookup();
        }
    }

    fn readBounded(db: *Db, path: []const u8, budget: usize) ?[]u8 {
        return db.readBoundedWith(path, budget, db.gpa);
    }
    fn readBoundedWith(db: *Db, path: []const u8, budget: usize, allocator: std.mem.Allocator) ?[]u8 {
        const file = files.File.open(db.gpa, db.io, path) catch |err| {
            db.metrics.last_missing = if (err == error.OutOfMemory) .out_of_memory else .io;
            return null;
        };
        defer file.close();
        const len = file.length() catch |err| {
            if (err == error.FontTooLarge) db.limit(.source_bytes) else db.metrics.last_missing = .io;
            return null;
        };
        if (len > Limits.source_bytes) {
            db.limit(.source_bytes);
            return null;
        }
        if (len > budget) {
            db.limit(.loaded_bytes);
            return null;
        }
        if (len < 12) {
            db.metrics.last_missing = .invalid_font;
            return null;
        }
        const data = allocator.alloc(u8, len) catch {
            db.metrics.last_missing = .out_of_memory;
            return null;
        };
        file.readPositionalAll(data, 0) catch {
            allocator.free(data);
            db.metrics.last_missing = .io;
            return null;
        };
        return data;
    }

    /// The face of `family` nearest `weight` and `italic`, null when the
    /// family has none.
    pub fn family(db: *Db, name: []const u8, weight: u16, italic: bool) ?u32 {
        db.scan();
        var best: ?u32 = null;
        var best_score: u32 = std.math.maxInt(u32);
        for (db.faces.items, 0..) |f, i| {
            if (!std.ascii.eqlIgnoreCase(f.style.name(), name)) continue;
            const dw: u32 = @abs(@as(i32, f.style.weight) - @as(i32, weight));
            const score = dw + @as(u32, if (f.style.italic != italic) 1000 else 0);
            if (score < best_score) {
                best_score = score;
                best = @intCast(i);
            }
        }
        return best;
    }

    /// The face for a style: its family if installed, else the first
    /// installed of the defaults.
    pub fn match(db: *Db, name: ?[]const u8, weight: u16, italic: bool, mono: bool) ?u32 {
        if (name) |n| if (db.family(n, weight, italic)) |f| return f;
        for (if (mono) &monos else &sans) |n| if (db.family(n, weight, italic)) |f| return f;
        db.scan();
        for (db.faces.items, 0..) |f, i| if (f.style.mono == mono) return @intCast(i);
        return if (db.faces.items.len > 0) 0 else null;
    }

    fn readFace(db: *Db, face: Face, budget: usize) ?[]u8 {
        const data = face.memory orelse return db.readBoundedWith(face.path, budget, std.heap.page_allocator);
        if (data.len > Limits.source_bytes) {
            db.limit(.source_bytes);
            return null;
        }
        if (data.len > budget) {
            db.limit(.loaded_bytes);
            return null;
        }
        return std.heap.page_allocator.dupe(u8, data) catch {
            db.metrics.last_missing = .out_of_memory;
            return null;
        };
    }

    /// A face's font, loaded on first use (null if it cannot be read).
    pub fn load(db: *Db, face: u32) ?*const font.Font {
        return db.loadImpl(face, true);
    }

    fn loadImpl(db: *Db, face: u32, invalidate_lookup: bool) ?*const font.Font {
        if (db.loaded.get(face)) |l| return &l.font;
        if (face >= db.faces.items.len) {
            db.metrics.last_missing = .invalid_font;
            return null;
        }
        if (db.loaded.count() >= Limits.loaded_faces) {
            db.limit(.loaded_faces);
            return null;
        }
        const f = db.faces.items[face];
        const owned = db.readFace(f, Limits.loaded_bytes - db.metrics.loaded_bytes) orelse {
            db.metrics.failed_loads +|= 1;
            return null;
        };
        const held_source = sources.internOwned(owned) catch {
            db.metrics.last_missing = .out_of_memory;
            db.metrics.failed_loads +|= 1;
            return null;
        };
        const data = held_source.bytes;
        const t = bounds.tables(data, f.index) catch {
            sources.release(held_source);
            db.metrics.last_missing = .invalid_font;
            db.metrics.failed_loads +|= 1;
            return null;
        };
        bounds.cmap(data, t) catch {
            sources.release(held_source);
            db.metrics.last_missing = .invalid_font;
            db.metrics.failed_loads +|= 1;
            return null;
        };
        const parsed = font.Font.init(data, f.index) catch {
            sources.release(held_source);
            db.metrics.last_missing = .invalid_font;
            db.metrics.failed_loads +|= 1;
            return null;
        };
        const l = db.gpa.create(Loaded) catch {
            sources.release(held_source);
            db.metrics.last_missing = .out_of_memory;
            db.metrics.failed_loads +|= 1;
            return null;
        };
        l.* = .{ .data = data, .source = held_source, .font = parsed, .digest = held_source.digest };
        l.font.data = l.data;
        db.loaded.put(db.gpa, face, l) catch {
            db.gpa.destroy(l);
            sources.release(held_source);
            db.metrics.last_missing = .out_of_memory;
            db.metrics.failed_loads +|= 1;
            return null;
        };
        db.metrics.loaded_bytes += data.len;
        // Loading a previously untried face can satisfy a prior negative
        // fallback result. Never evict fonts: the atlas borrows their pointers.
        if (invalidate_lookup) db.clearLookup();
        return &l.font;
    }

    /// Borrowed until Db.deinit, identical to load(face).data; no second file
    /// read and no font substitution between shaping and outline rasterization.
    pub fn source(db: *Db, face: u32) ?Source {
        _ = db.load(face) orelse return null;
        const loaded = db.loaded.get(face).?;
        return .{ .bytes = loaded.data, .index = db.faces.items[face].index, .digest = loaded.digest };
    }

    /// A face that has `cp`, for text its font lacks.
    pub fn fallback(db: *Db, cp: u21, weight: u16) ?u32 {
        var text: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &text) catch {
            db.metrics.last_missing = .invalid_utf8;
            return null;
        };
        return db.choose(null, text[0..len], weight, false);
    }

    /// text is exactly one VT-owned grapheme, never a paragraph. The caller
    /// keeps VT cell width; this method only selects one face for the full text.
    pub fn clusterFace(db: *Db, primary: u32, text: []const u8, weight: u16, italic: bool) ?u32 {
        return db.choose(primary, text, weight, italic);
    }

    fn choose(db: *Db, primary: ?u32, text: []const u8, weight: u16, italic: bool) ?u32 {
        db.metrics.last_missing = cluster.validate(text);
        if (db.metrics.last_missing != .none) {
            if (db.metrics.last_missing == .cluster_limit) {
                db.limit(.cluster_bytes);
                db.metrics.last_missing = .cluster_limit;
            }
            return null;
        }
        db.scan();
        if (primary != null and primary.? >= db.faces.items.len) {
            db.metrics.last_missing = .invalid_font;
            return null;
        }
        const key = cluster.key(primary, text, weight, italic, db.generation);
        if (key) |k| if (db.found.get(k)) |cached| {
            db.metrics.last_missing = cached.reason;
            return cached.face;
        };
        const result = db.findCluster(primary, text, weight, italic);
        if (result != null) db.metrics.last_missing = .none else if (db.metrics.last_missing == .none) db.metrics.last_missing = .missing_glyph;
        // Resource/IO/OOM failures may recover; don't cache them. Structurally
        // invalid font sources are stable within this scanned Db generation;
        // preserve their reason in the negative cache instead of rereading them.
        if (key) |k| if (db.metrics.last_missing == .none or db.metrics.last_missing == .missing_glyph or db.metrics.last_missing == .probe_limit or db.metrics.last_missing == .invalid_font) {
            if (db.found.count() >= cluster.max_entries) {
                const reason = db.metrics.last_missing;
                db.limit(.lookup_entries);
                db.clearLookup();
                db.metrics.last_missing = reason;
            }
            db.found.put(db.gpa, k, .{ .face = result, .reason = db.metrics.last_missing }) catch {};
        };
        return result;
    }

    fn covers(db: *Db, face: u32, text: []const u8) bool {
        const was_loaded = db.loaded.contains(face);
        const loaded = db.loadImpl(face, false) orelse return false;
        const covered = cluster.covers(loaded, text);
        if (covered and !was_loaded) db.clearLookup();
        if (!covered and !was_loaded) {
            // This new candidate has only reached this private synchronous
            // coverage check. It has never reached TextSystem/runFont/atlas or
            // a public source() caller. Existing published fonts are NEVER
            // removed, including when their coverage check fails here.
            const entry = db.loaded.fetchRemove(face).?;
            const candidate = entry.value;
            std.debug.assert(&candidate.font == loaded);
            db.metrics.loaded_bytes -= candidate.data.len;
            db.metrics.probe_releases +|= 1;
            db.metrics.probe_released_bytes +|= candidate.data.len;
            sources.release(candidate.source);
            db.gpa.destroy(candidate);
        }
        return covered;
    }

    fn styleScore(style: font.Style, weight: u16, italic: bool) u32 {
        return @as(u32, @intCast(@abs(@as(i32, style.weight) - @as(i32, weight)))) + @as(u32, if (style.italic == italic) 0 else 1000);
    }

    fn findCluster(db: *Db, primary: ?u32, text: []const u8, weight: u16, italic: bool) ?u32 {
        if (primary) |face| if (db.covers(face, text)) return face;
        for (db.fallback_names) |name| if (db.family(name, weight, italic)) |face| if (db.covers(face, text)) return face;
        for (fallbacks) |name| if (db.family(name, weight, italic)) |face| if (db.covers(face, text)) return face;
        // Already loaded faces cost no additional source memory. Pick the best
        // matching style deterministically, not hash-table iteration order.
        var best: ?u32 = null;
        var best_score: u32 = std.math.maxInt(u32);
        for (db.faces.items, 0..) |face, i| {
            if (!db.loaded.contains(@intCast(i))) continue;
            const rank = styleScore(face.style, weight, italic);
            if (rank < best_score and db.covers(@intCast(i), text)) {
                best = @intCast(i);
                best_score = rank;
            }
        }
        if (best != null) return best;
        // At most 48 additional families are inspected, using each family's
        // nearest style; large font installations cannot cause unbounded loads.
        var tries: usize = 0;
        var tried: [Limits.arbitrary_probes]u32 = undefined;
        for (db.faces.items, 0..) |face, i| {
            if (i > 0 and std.ascii.eqlIgnoreCase(db.faces.items[i - 1].style.name(), face.style.name())) continue;
            const candidate = db.family(face.style.name(), weight, italic) orelse continue;
            if (db.loaded.contains(candidate)) continue;
            if (std.mem.indexOfScalar(u32, tried[0..tries], candidate) != null) continue;
            if (tries >= Limits.arbitrary_probes) {
                if (db.metrics.last_missing == .none) db.metrics.last_missing = .probe_limit;
                break;
            }
            tried[tries] = candidate;
            tries += 1;
            if (db.covers(candidate, text)) return candidate;
        }
        return null;
    }
};
