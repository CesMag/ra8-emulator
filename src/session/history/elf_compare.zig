//! Two builds of one program, side by side: the header, the entry point,
//! the load segments and the symbol table. A regression replay reports this
//! before it runs anything, so a divergence can be read against what the
//! rebuild actually changed.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const symbols = @import("../symbols.zig");

pub const Error = elf.Error || error{OutOfMemory};

/// What one image says about itself.
pub const Side = struct {
    identity: [16]u8,
    entry: u32,
    flags: u32,
    segments: u16,
    symbols: usize,
};

pub const Report = struct {
    original: Side,
    rebuilt: Side,
    /// Load segments, matched by index, whose address, size or flags differ.
    segments_moved: u32 = 0,
    /// Load segments with the same layout whose bytes differ.
    segments_changed: u32 = 0,
    /// The lowest address at which a same-layout segment's bytes differ.
    first_changed_address: ?u32 = null,
    symbols_added: u32 = 0,
    symbols_removed: u32 = 0,
    symbols_moved: u32 = 0,
    symbols_resized: u32 = 0,
    /// The first symbol, in the rebuilt table's order, that was added, moved
    /// or resized; borrowed from the rebuilt image's bytes.
    first_changed_symbol: ?[]const u8 = null,

    pub fn identical(self: Report) bool {
        return std.mem.eql(u8, &self.original.identity, &self.rebuilt.identity);
    }

    /// Whether the two images agree on everything but their bytes' content:
    /// header, entry, layout and symbols.
    pub fn sameShape(self: Report) bool {
        return self.original.entry == self.rebuilt.entry and self.original.flags == self.rebuilt.flags and
            self.original.segments == self.rebuilt.segments and self.segments_moved == 0 and
            self.symbols_added == 0 and self.symbols_removed == 0 and self.symbols_moved == 0 and self.symbols_resized == 0;
    }
};

fn sideOf(bytes: []const u8, image: elf.Image) Side {
    const head = image.header();
    return .{
        .identity = @import("root.zig").identity(bytes),
        .entry = head.e_entry,
        .flags = head.e_flags,
        .segments = head.e_phnum,
        .symbols = symbols.count(image),
    };
}

pub fn compare(allocator: std.mem.Allocator, original_bytes: []const u8, rebuilt_bytes: []const u8) Error!Report {
    const original = try elf.Image.init(original_bytes);
    const rebuilt = try elf.Image.init(rebuilt_bytes);
    var report: Report = .{ .original = sideOf(original_bytes, original), .rebuilt = sideOf(rebuilt_bytes, rebuilt) };
    compareSegments(&report, original, rebuilt);
    try compareSymbols(allocator, &report, original, rebuilt);
    return report;
}

fn compareSegments(report: *Report, original: elf.Image, rebuilt: elf.Image) void {
    const count = @max(original.segmentCount(), rebuilt.segmentCount());
    var index: u16 = 0;
    while (index < count) : (index += 1) {
        const a = original.loadSegment(index);
        const b = rebuilt.loadSegment(index);
        if (a == null and b == null) continue;
        if (a == null or b == null) {
            report.segments_moved += 1;
            continue;
        }
        const x = a.?;
        const y = b.?;
        if (x.vaddr != y.vaddr or x.paddr != y.paddr or x.memsz != y.memsz or x.flags != y.flags or x.bytes.len != y.bytes.len) {
            report.segments_moved += 1;
            continue;
        }
        const at = std.mem.indexOfDiff(u8, x.bytes, y.bytes) orelse continue;
        report.segments_changed += 1;
        const address = x.paddr + @as(u32, @intCast(at));
        if (report.first_changed_address == null or address < report.first_changed_address.?) report.first_changed_address = address;
    }
}

fn table(allocator: std.mem.Allocator, image: elf.Image) Error!std.StringHashMap(symbols.Named) {
    var map = std.StringHashMap(symbols.Named).init(allocator);
    errdefer map.deinit();
    var walk = symbols.Walk.init(image);
    while (walk.next()) |symbol| try map.put(symbol.name, symbol);
    return map;
}

/// Symbols are matched by name, so a name the table repeats counts once.
fn compareSymbols(allocator: std.mem.Allocator, report: *Report, original: elf.Image, rebuilt: elf.Image) Error!void {
    var before = try table(allocator, original);
    defer before.deinit();
    var after = try table(allocator, rebuilt);
    defer after.deinit();
    var kept = after.iterator();
    while (kept.next()) |entry| {
        const old = before.get(entry.key_ptr.*) orelse {
            report.symbols_added += 1;
            continue;
        };
        const moved = old.value != entry.value_ptr.value;
        report.symbols_moved += @intFromBool(moved);
        report.symbols_resized += @intFromBool(!moved and old.size != entry.value_ptr.size);
    }
    var gone = before.keyIterator();
    while (gone.next()) |name| report.symbols_removed += @intFromBool(!after.contains(name.*));
    var walk = symbols.Walk.init(rebuilt);
    while (walk.next()) |symbol| {
        const old = before.get(symbol.name);
        if (old == null or old.?.value != symbol.value or old.?.size != symbol.size) {
            report.first_changed_symbol = symbol.name;
            return;
        }
    }
}
