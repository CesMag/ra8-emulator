//! Tests for src/chip/periph/npu/vela_hook.zig: a Vela program submitted
//! through the NPU's own registers, the way the firmware driver does it.
const std = @import("std");
const ra8 = @import("ra8");
const npu = ra8.chip.periph.npu;
const store_memory = @import("../store_memory.zig");
const Guest = store_memory.Guest;

const arena_base: u32 = ra8.chip.core.memmap.dtcm_end - arena_size;
const arena_size: u32 = 0x4000;
const stream_at: u32 = arena_base;
const region0: u32 = arena_base + 0x1000;
const region1: u32 = arena_base + 0x2000;

fn poke(unit: *npu.Npu, offset: u32, value: u32) void {
    unit.write(npu.win_base + offset, 4, value);
}

fn peek(unit: *npu.Npu, offset: u32) u32 {
    return unit.read(npu.win_base + offset, 4);
}

const Bench = struct {
    core: Guest,
    unit: npu.Npu,

    fn open(self: *Bench) !void {
        self.core = try store_memory.open();
        self.unit = npu.Npu.init();
        self.unit.memory = self.core;
    }

    fn close(self: *Bench) void {
        store_memory.close(self.core);
    }

    fn submit(self: *Bench, words: []const u32) !void {
        for (words, 0..) |word, index| {
            try self.core.writeWord(stream_at + @as(u32, @intCast(index)) * 4, word);
        }
        poke(&self.unit, npu.off.qbase, stream_at);
        poke(&self.unit, npu.off.qsize, @intCast(words.len * 4));
        poke(&self.unit, npu.off.basep0, region0);
        poke(&self.unit, npu.off.basep0 + npu.geometry.basep_stride, region1);
        poke(&self.unit, npu.off.command, npu.field.cmd_run);
    }
};

/// Region 0 offset 0x10 to region 1 offset 0x20, 0x40 bytes, then STOP.
const dma_program = [_]u32{
    0x0000_0130, 0x0001_0131,
    0x0000_4030, 0x0000_0010,
    0x0000_4031, 0x0000_0020,
    0x0000_4032, 0x0000_0040,
    0x0000_0010, 0x0000_0011,
    0x0000_0000,
};

test "a Vela DMA program kicked through the registers moves its bytes" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();
    var bytes: [0x40]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i * 3 + 1);
    try bench.core.write(region0 + 0x10, &bytes);

    try bench.submit(&dma_program);

    var landed: [0x40]u8 = undefined;
    try bench.core.read(region1 + 0x20, &landed);
    try std.testing.expectEqualSlices(u8, &bytes, &landed);
    try std.testing.expectEqual(@as(u32, 1), bench.unit.vela.jobs);
    try std.testing.expectEqual(@as(u64, 0x40), bench.unit.vela.moved);
    const status = peek(&bench.unit, npu.off.status);
    try std.testing.expect(status & npu.field.status_cmd_end != 0);
    try std.testing.expect(status & npu.field.status_irq != 0);
}

test "a program that needs an operator faults as a parse error" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();
    try bench.submit(&[_]u32{ 0x0000_0002, 0x0000_0000 });
    try std.testing.expectEqual(@as(u32, 1), bench.unit.vela.unmodelled);
    const status = peek(&bench.unit, npu.off.status);
    try std.testing.expect(status & npu.field.status_parse != 0);
    try std.testing.expect(status & npu.field.status_cmd_end == 0);
}

test "a stream with no STOP is malformed" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();
    try bench.submit(&[_]u32{ 0x0000_0011, 0x0000_0012 });
    try std.testing.expectEqual(@as(u32, 1), bench.unit.vela.malformed);
}

test "a DMA into unmapped memory is a bus error" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();
    var program = dma_program;
    program[5] = 0x0010_0000; // DMA0_DST far past the mapped arena
    try bench.submit(&program);
    try std.testing.expectEqual(@as(u32, 1), bench.unit.vela.refused);
    try std.testing.expect(peek(&bench.unit, npu.off.status) & npu.field.status_bus_error != 0);
}

test "the regions come from BASEP0..7" {
    var unit = npu.Npu.init();
    poke(&unit, npu.off.basep0 + 3 * npu.geometry.basep_stride, 0x2200_0000);
    try std.testing.expectEqual(@as(u64, 0x2200_0000), ra8.chip.periph.npu.vela.hook.regions(&unit)[3]);
}

test "the report counts a Vela kick whether it reached STOP or faulted" {
    const Counters = @TypeOf(npu.Npu.init().vela);
    try std.testing.expectEqual(@as(u32, 0), (Counters{}).kicks());
    const ran: Counters = .{ .jobs = 1, .moved = 64 };
    try std.testing.expectEqual(@as(u32, 1), ran.kicks());
    try std.testing.expectEqual(@as(u32, 0), ran.faults());
    const refused: Counters = .{ .unmodelled = 1, .malformed = 2, .refused = 4 };
    try std.testing.expectEqual(@as(u32, 7), refused.faults());
    try std.testing.expectEqual(@as(u32, 7), refused.kicks());
}
