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

fn compareSymbols(allocator: std.mem.Allocator, report: *Report, original: elf.Image, rebuilt: elf.Image) Error!void {
    var before = std.StringHashMap(symbols.Named).init(allocator);
    defer before.deinit();
    var walk = symbols.Walk.init(original);
    while (walk.next()) |symbol| try before.put(symbol.name, symbol);
    var seen: u32 = 0;
    walk = symbols.Walk.init(rebuilt);
    while (walk.next()) |symbol| {
        const old = before.get(symbol.name) orelse {
            report.symbols_added += 1;
            if (report.first_changed_symbol == null) report.first_changed_symbol = symbol.name;
            continue;
        };
        seen += 1;
        const moved = old.value != symbol.value;
        const resized = old.size != symbol.size;
        report.symbols_moved += @intFromBool(moved);
        report.symbols_resized += @intFromBool(resized and !moved);
        if ((moved or resized) and report.first_changed_symbol == null) report.first_changed_symbol = symbol.name;
    }
    report.symbols_removed = @intCast(before.count() -| seen);
}
