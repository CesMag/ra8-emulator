//! Covers src/session/stack_profile.zig (RA8EMU-971): a run wired as
//! the CLI wires `--profile-folded` samples CPU0's call stacks, and the
//! folded file writes them as cpu0-rooted rows; CPU1's go out as cpu1 rows
//! named from its own image (RA8EMU-972).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const memmap = ra8.chip.core.memmap;
const stack_profile = cli_app.zig_run.stack_profile;
const profile = ra8.session.functions.profile;
const profile_report = cli_app.report.profile;
const stack_samples = ra8.session.step_hook.stack_samples;
const cpu_boot = ra8.chip.core.cpu.boot;
const symbols = ra8.session.symbols;
const Builder = @import("symbol_image.zig").Builder;
const store_board = @import("../interfaces/cli/store_board.zig");
const Store = store_board.Store;
const Guest = store_board.Guest;
const attach = store_board.attach;

const base = memmap.sram_base;
const outer: u32 = 0x40;
const middle: u32 = 0x60;
const leaf: u32 = 0x80;

/// outer loops calling middle, which calls leaf; each caller keeps an r7
/// frame record (push {r7, lr}; mov r7, sp), as Zig and clang do on Thumb.
fn code() [0xA0]u8 {
    var bytes: [0xA0]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], memmap.sram_end, .little);
    std.mem.writeInt(u32, bytes[4..8], base + outer + 1, .little);
    half(&bytes, outer, 0xB580);
    half(&bytes, outer + 2, 0x466F);
    call(&bytes, outer + 4, middle);
    half(&bytes, outer + 8, 0xE7FC); // b outer + 4
    half(&bytes, middle, 0xB580);
    half(&bytes, middle + 2, 0x466F);
    call(&bytes, middle + 4, leaf);
    half(&bytes, middle + 8, 0xBD80); // pop {r7, pc}
    for (0..4) |i| half(&bytes, leaf + @as(u32, @intCast(i)) * 2, 0xBF00);
    half(&bytes, leaf + 8, 0x4770); // bx lr
    return bytes;
}

fn half(bytes: []u8, at: u32, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}

fn call(bytes: []u8, at: u32, target: u32) void {
    const offset: i32 = @as(i32, @intCast(target)) - @as(i32, @intCast(at + 4));
    const imm: u32 = @bitCast(offset >> 1);
    const s = (imm >> 23) & 1;
    const j1 = ~(((imm >> 22) & 1) ^ s) & 1;
    const j2 = ~(((imm >> 21) & 1) ^ s) & 1;
    half(bytes, at, @intCast(0xF000 | s << 10 | ((imm >> 11) & 0x3FF)));
    half(bytes, at + 2, @intCast(0xD000 | j1 << 13 | j2 << 11 | (imm & 0x7FF)));
}

const names0 = [_][]const u8{ "outer", "middle", "leaf" };

/// An image whose only content is the three function symbols.
fn image(buffer: []u8, names: [3][]const u8) !ra8.board.image.elf.Image {
    const encoded = Builder.build(buffer, &names, &.{ base + outer + 1, base + middle + 1, base + leaf + 1 });
    for (0..names.len) |index| {
        const at = Builder.sym_off + @sizeOf(symbols.Symbol) * index;
        const symbol: *align(1) symbols.Symbol = std.mem.bytesAsValue(symbols.Symbol, encoded[at..][0..@sizeOf(symbols.Symbol)]);
        symbol.st_info = symbols.symbol_type.func;
        symbol.st_size = 0x10;
    }
    return ra8.board.image.elf.Image.init(encoded);
}

test "a --profile-folded run folds CPU0's sampled stacks into cpu0-rooted rows" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    const bytes = code();
    var at: u32 = 0;
    while (at < bytes.len) : (at += 4) try core.writeWord(base + at, std.mem.readInt(u32, bytes[at..][0..4], .little));
    var image_bytes: [768]u8 = undefined;
    const elf = try image(&image_bytes, names0);
    var table: profile.Table = .{ .image = elf };
    table.prepare();
    const samples = try std.testing.allocator.create(stack_samples.Store);
    defer std.testing.allocator.destroy(samples);
    samples.* = .{};
    table.samples = samples;

    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    const budget: u64 = 4096;
    const clock: u64 = 0;
    var stacks = stack_profile.Run.of(&table, elf, budget, &clock, null);
    var ran: u64 = 0;
    var output: [512]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    const status = try cpu_boot.start(&stream, .zig, core, &board.bus, base, budget, &ran, .{ .retire_listener = stacks.listener(null), .core = stacks.lend(null) });
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(?*ra8.chip.core.cpu.cpu.Cpu, null), stacks.core);
    try std.testing.expectEqual(@as(usize, budget / 2), samples.count);

    // Rows merge on names and sort on them; each caller frame is named
    // once, and no stale lr puts middle under outer.
    try expectRows(elf, table, &.{ "cpu0;outer", "cpu0;outer;middle", "cpu0;outer;middle;leaf" }, samples.count);
}

fn expectRows(elf: ra8.board.image.elf.Image, table: profile.Table, want: []const []const u8, count: usize) !void {
    var folded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer folded.deinit();
    try profile_report.folded(&folded.writer, elf, table);
    var total: u64 = 0;
    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, folded.written(), '\n');
    while (lines.next()) |line| : (index += 1) {
        if (line.len == 0) break;
        const gap = std.mem.lastIndexOfScalar(u8, line, ' ').?;
        try std.testing.expect(index < want.len);
        try std.testing.expectEqualStrings(want[index], line[0..gap]);
        total += try std.fmt.parseInt(u64, line[gap + 1 ..], 10);
    }
    try std.testing.expectEqual(want.len, index);
    try std.testing.expectEqual(@as(u64, count), total);
}

/// RAM at SRAM's base for a bare core standing in for CPU1.
const Ram = struct {
    bytes: [0x400]u8 = @splat(0),

    fn view(self: *Ram) ra8.chip.core.cpu.bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn span(self: *Ram, address: u32, len: usize) ra8.chip.core.cpu.bus.Error![]u8 {
        if (address < base or address - base + len > self.bytes.len) return error.Unmapped;
        return self.bytes[address - base ..][0..len];
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) ra8.chip.core.cpu.bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.span(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) ra8.chip.core.cpu.bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(try self.span(address, from.len), from);
    }
};

test "CPU1's sampled stacks fold as cpu1 rows named from CPU1's image" {
    var ram: Ram = .{};
    const bytes = code();
    @memcpy(ram.bytes[0..bytes.len], &bytes);
    std.mem.writeInt(u32, ram.bytes[0..4], base + ram.bytes.len, .little);
    var cpu1: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = ram.view() };
    try cpu1.reset(base);
    var first: [768]u8 = undefined;
    var second: [768]u8 = undefined;
    const elf = try image(&first, names0);
    var table: profile.Table = .{ .image = elf, .second = try image(&second, .{ "main1", "work1", "step1" }) };
    table.prepare();
    const samples = try std.testing.allocator.create(stack_samples.Store);
    defer std.testing.allocator.destroy(samples);
    samples.* = .{};
    table.samples = samples;

    const clock: u64 = 0;
    var stacks = stack_profile.Run.of(&table, elf, 128, &clock, null);
    try std.testing.expect(stacks.lend(&cpu1) != null);
    for (0..60) |_| if (cpu1.step()) |why| {
        std.debug.print("core stopped: {any}\n", .{why});
        return error.CoreStopped;
    };
    try std.testing.expectEqual(@as(usize, 60), samples.count);
    try expectRows(elf, table, &.{ "cpu1;main1", "cpu1;main1;work1", "cpu1;main1;work1;step1" }, samples.count);
}

test "with no samples the folded file is the per-function rows it always was" {
    var stacks = stack_profile.Run.of(null, undefined, 4096, &@as(u64, 0), null);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.RetireListener, null), stacks.listener(null));
    try std.testing.expectEqual(@as(?*?*ra8.chip.core.cpu.cpu.Cpu, null), stacks.lend(null));
}

test "the period spreads a bounded run over the store's slots" {
    try std.testing.expectEqual(@as(u32, 1), stack_profile.period(0));
    try std.testing.expectEqual(@as(u32, 1), stack_profile.period(100));
    try std.testing.expectEqual(@as(u32, 2), stack_profile.period(4096));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), stack_profile.period(1 << 50));
}
