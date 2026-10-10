//! The `dumps` object of `--report json` (RA8EMU-381): the `--dump-sym`
//! globals, `--dump-regs` and `--dump-mem` words, the same reads
//! report/dumps.zig and debug/mem_dump.zig print. A symbol the images do
//! not carry or a word the core will not read is null, never a number
//! nothing measured. The `--dump-sd` block and the `--watch` log follow
//! (RA8EMU-391, json_sd.zig and json_watched.zig).
const std = @import("std");
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const elf = @import("ra8_board").image.elf;
const cli = @import("../cli.zig");
const symbols = @import("../../../session/symbols.zig");
const registers = @import("../../../session/registers.zig");
const mem_dump = @import("../../../session/mem_dump.zig");
const place = @import("../../../session/place.zig");
const report_dumps = @import("dumps.zig");
const watchpoint = @import("../../../session/watchpoint.zig");
pub const json_sd = @import("json_sd.zig");
pub const json_watched = @import("json_watched.zig");
pub const json_regs = @import("json_regs.zig");
const Board = @import("ra8_board").board.Board;

/// What the dumps read from: the registers and memory as the run left them,
/// the image and the flags that asked. A `--cpu zig` run hands over its own
/// core's registers and store (RA8EMU-579, RA8EMU-580).
pub const Dumps = struct {
    registers: json_regs.Reader,
    memory: Guest,
    image: elf.Image,
    options: *const cli.Options,
    /// Reads the `--ns` image again for its symbols.
    io: std.Io,
    /// The `--watch` log as the run left it, null when nothing was watched.
    watched: ?watchpoint.Watched = null,
};

/// The `dumps` object, or null when nothing was handed over to read.
pub fn section(j: anytype, board: *Board, found: ?*const Dumps) !void {
    const of = found orelse return j.field("dumps", null);
    try j.open("dumps", '{');
    try globals(j, of);
    try regs(j, of.registers, of.memory, of.options.dump_regs);
    try memory(j, of.memory, of.image, of.options.memDumps());
    try json_sd.block(j, board, of.options.dump_sd);
    try json_watched.log(j, of.image, of.options.watch_place, if (of.watched) |*one| one else null);
    try j.close('}');
}

/// One row per `--dump-sym` name, looked up in the `--ns` image too.
fn globals(j: anytype, of: *const Dumps) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var images: [2]elf.Image = .{ of.image, undefined };
    var count: usize = 1;
    if (of.options.dumps().len != 0) {
        if (try report_dumps.nonSecure(arena.allocator(), of.io, of.options.*)) |second| {
            images[1] = second;
            count = 2;
        }
    }
    try j.open("symbols", '[');
    for (of.options.dumps()) |name| {
        const address = symbols.addressInAny(images[0..count], name);
        const value: ?u32 = if (address) |at| of.memory.readWord(at) catch null else null;
        try j.open(null, '{');
        try j.field("name", name);
        try j.field("address", address);
        try j.field("value", value);
        try j.close('}');
    }
    try j.close(']');
}

fn regs(j: anytype, from: json_regs.Reader, guest: Guest, asked: bool) !void {
    if (!asked) return j.field("registers", null);
    try j.open("registers", '{');
    for (registers.dumped) |named| {
        try j.field(named.name, from.register(named.which));
    }
    const sp: ?u32 = from.register(.sp);
    try j.open("stack", '[');
    for (0..registers.limits.stack_words) |index| {
        const value: ?u32 = if (sp) |base| guest.readWord(registers.stackWord(base, index)) catch null else null;
        try j.field(null, value);
    }
    try j.close(']');
    try j.close('}');
}

/// `memory` is the first `--dump-mem` place, as it always was, so a
/// one-place report reads the same. Two or more places also list every one
/// in order under `memory_places` (RA8EMU-488).
fn memory(j: anytype, core: Guest, image: elf.Image, asks: []const mem_dump.Ask) !void {
    if (asks.len == 0) return j.field("memory", null);
    try placeObject(j, "memory", core, image, asks[0].spec, asks[0].words);
    if (asks.len < 2) return;
    try j.open("memory_places", '[');
    for (asks) |ask| try placeObject(j, null, core, image, ask.spec, ask.words);
    try j.close(']');
}

fn placeObject(j: anytype, key: ?[]const u8, core: Guest, image: elf.Image, named: []const u8, asked: ?u32) !void {
    try j.open(key, '{');
    try j.field("place", named);
    const at = mem_dump.resolve(core, image, named) catch |err| {
        try j.field("address", null);
        try j.field("error", @errorName(err));
        try j.open("words", '[');
        try j.close(']');
        return j.close('}');
    };
    try j.field("address", at);
    try j.field("error", null);
    try j.open("words", '[');
    for (0..place.words(asked)) |step| {
        const index: u32 = @intCast(step);
        const value: ?u32 = core.readWord(at +% index * 4) catch null;
        try j.field(null, value);
    }
    try j.close(']');
    try j.close('}');
}
