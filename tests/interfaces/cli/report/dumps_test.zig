//! Covers src/interfaces/cli/report/dumps.zig: the `--dump-sym` line a
//! memory-probe verdict reads, the `--dump-regs` line and the `--dump-sd` block.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const store_board = @import("../store_board.zig");
const elf = ra8.board.image.elf;
const cli = cli_app.cli;
const report_dumps = cli_app.report.dumps;
const Builder = @import("../../../session/symbol_image.zig").Builder;

fn dumped(core: store_board.Guest, image: elf.Image, names: []const []const u8, into: []u8) ![]const u8 {
    var options: cli.Options = .{ .path = "probe.elf" };
    for (names, 0..) |name, index| options.dump[index] = name;
    options.dump_count = names.len;
    var stream: std.Io.Writer = .fixed(into);
    try report_dumps.dumpSymbols(&stream, std.testing.io, core, image, options);
    return stream.buffered();
}

test "a dumped global prints its address and value, a missing one says so" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    try core.writeWord(0x2200_0100, 216662);
    var buffer: [1024]u8 = undefined;
    const image = try elf.Image.init(Builder.build(&buffer, &.{"g_alive"}, &.{0x2200_0100}));
    var out: [256]u8 = undefined;
    const text = try dumped(core, image, &.{ "g_alive", "g_missing" }, &out);
    try std.testing.expectEqualStrings(
        "  dump-sym      : g_alive @0x22000100 = 216662 (0x00034E56)\n" ++
            "  dump-sym      : g_missing <unresolved>\n",
        text,
    );
}

test "no dump asked for prints nothing" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    var buffer: [1024]u8 = undefined;
    const image = try elf.Image.init(Builder.build(&buffer, &.{"g_alive"}, &.{0x2200_0100}));
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try dumped(core, image, &.{}, &out));
}

const Regs = ra8.chip.core.cpu.regs.Regs;

fn registerLine(regs: *const Regs, core: store_board.Guest, into: []u8) ![]const u8 {
    const options: cli.Options = .{ .path = "probe.elf", .dump_regs = true };
    var stream: std.Io.Writer = .fixed(into);
    try report_dumps.dumpRegisters(&stream, .{ .zig = regs }, core, options);
    return stream.buffered();
}

test "--dump-regs prints the engine run's register line and the words at sp" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    var regs: Regs = .{ .msp = 0x2200_0200, .lr = 0x0200_0101, .pc = 0x0200_0040 };
    for (0..4) |n| regs.set(@intCast(n), 0x10 + @as(u32, @intCast(n)));
    regs.set(12, 0xC);
    for (0..4) |n| try core.writeWord(0x2200_0200 + @as(u32, @intCast(n * 4)), 0xA0 + @as(u32, @intCast(n)));
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "  dump-regs     : r0 0x00000010 r1 0x00000011 r2 0x00000012 r3 0x00000013\n" ++
            "                  r12 0x0000000C sp 0x22000200 lr 0x02000101 pc 0x02000040\n" ++
            "                  [sp+0] 0x000000A0 [sp+4] 0x000000A1 [sp+8] 0x000000A2 [sp+12] 0x000000A3\n",
        try registerLine(&regs, core, &out),
    );
}

test "--dump-regs says a stack word it cannot read is unreadable" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    const regs: Regs = .{ .msp = 0xFFFF_FFF8 };
    var out: [512]u8 = undefined;
    const text = try registerLine(&regs, core, &out);
    try std.testing.expect(std.mem.indexOf(u8, text, "[sp+0] <unreadable>") != null);
}

test "no --dump-regs prints nothing" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const regs: Regs = .{};
    var out: [64]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&out);
    try report_dumps.dumpRegisters(&stream, .{ .zig = &regs }, .{ .store = &store }, .{ .path = "probe.elf" });
    try std.testing.expectEqualStrings("", stream.buffered());
}

const Block = ra8.components.sd_card.image.Block;

const OneBlockCard = struct {
    sd: struct { img: Img } = .{ .img = .{} },
    const Img = struct {
        pub fn read(_: *const Img, index: u32, out: *Block) bool {
            if (index != 2) return false;
            @memset(out, 0);
            @memcpy(out[16..20], "FAT3");
            return true;
        }
    };
};

test "--dump-sd prints the block's non-zero rows and counts the rest" {
    var card: OneBlockCard = .{};
    var out: [512]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&out);
    try report_dumps.dumpBlock(&stream, &card, .{ .path = "probe.elf", .dump_sd = 2 });
    const text = stream.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "  dump-sd       : block 2 (0x2)\n  0010  46 41 54 33 "));
    try std.testing.expect(std.mem.endsWith(u8, text, "  dump-sd       : 31 zero row(s) not shown\n"));
}

test "--dump-sd on a block the card does not hold says so" {
    var card: OneBlockCard = .{};
    var out: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&out);
    try report_dumps.dumpBlock(&stream, &card, .{ .path = "probe.elf", .dump_sd = 9 });
    try std.testing.expectEqualStrings("  dump-sd       : block 9 is not on this card\n", stream.buffered());
}
