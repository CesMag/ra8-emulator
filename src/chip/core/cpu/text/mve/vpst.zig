//! Text for VPST and its VPT-block suffix pattern, per DDI0553 B5.5.
const Instr = @import("../../instr.zig").Instr;
const ops = @import("../../ops/mve/vpst.zig");
const text = @import("../text.zig");

pub const Pattern = struct {
    name: []const u8,
    suffixes: [4]u8,
    len: u3,
};

/// The architectural mask encodings and then/else decorators from DDI0553.
pub const patterns = [_]Pattern{
    .{ .name = "", .suffixes = .{ 0, 0, 0, 0 }, .len = 0 },
    .{ .name = "vpstttt", .suffixes = .{ 't', 't', 't', 't' }, .len = 4 },
    .{ .name = "vpsttt", .suffixes = .{ 't', 't', 't', 0 }, .len = 3 },
    .{ .name = "vpsttte", .suffixes = .{ 't', 't', 't', 'e' }, .len = 4 },
    .{ .name = "vpstt", .suffixes = .{ 't', 't', 0, 0 }, .len = 2 },
    .{ .name = "vpsttee", .suffixes = .{ 't', 't', 'e', 'e' }, .len = 4 },
    .{ .name = "vpstte", .suffixes = .{ 't', 't', 'e', 0 }, .len = 3 },
    .{ .name = "vpsttet", .suffixes = .{ 't', 't', 'e', 't' }, .len = 4 },
    .{ .name = "vpst", .suffixes = .{ 't', 0, 0, 0 }, .len = 1 },
    .{ .name = "vpsteee", .suffixes = .{ 't', 'e', 'e', 'e' }, .len = 4 },
    .{ .name = "vpstee", .suffixes = .{ 't', 'e', 'e', 0 }, .len = 3 },
    .{ .name = "vpsteet", .suffixes = .{ 't', 'e', 'e', 't' }, .len = 4 },
    .{ .name = "vpste", .suffixes = .{ 't', 'e', 0, 0 }, .len = 2 },
    .{ .name = "vpstett", .suffixes = .{ 't', 'e', 't', 't' }, .len = 4 },
    .{ .name = "vpstet", .suffixes = .{ 't', 'e', 't', 0 }, .len = 3 },
    .{ .name = "vpstete", .suffixes = .{ 't', 'e', 't', 'e' }, .len = 4 },
};

pub fn pattern(instr: Instr) Pattern {
    return patterns[ops.mask(instr)];
}

pub fn print(instr: Instr, out: *text.Text) void {
    out.put("{s}", .{pattern(instr).name});
}
