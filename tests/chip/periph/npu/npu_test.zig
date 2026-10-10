//! Covers src/chip/periph/npu/npu.zig: the register window, and the five places this
//! model refuses to hand an image a result the silicon would not have given
//! it.
const std = @import("std");
const ra8 = @import("ra8");
const npu = ra8.chip.periph.npu;
const cmd = ra8.chip.periph.npu.cmd;
const store_memory = @import("../store_memory.zig");
const Guest = store_memory.Guest;

/// The arenas and command stream sit in the top 16 KiB of DTCM, so a walk
/// off the arena's end reaches memory nothing backs.
const arena_base: u32 = ra8.chip.core.memmap.dtcm_end - arena_size;
const arena_size: u32 = 0x4000;
const stream_at: u32 = arena_base;
const source_at: u32 = arena_base + 0x100;
const destination_at: u32 = arena_base + 0x200;

fn at(offset: u32) u32 {
    return npu.win_base + offset;
}

fn poke(unit: *npu.Npu, offset: u32, value: u32) void {
    unit.write(at(offset), 4, value);
}

fn peek(unit: *npu.Npu, offset: u32) u32 {
    return unit.read(at(offset), 4);
}

/// The NPU with guest memory behind it, the way attach() wires it on an
/// RA8P1 run.
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

    /// Point the queue at a stream and give it the two regions it names.
    fn submit(self: *Bench, program: cmd.Command) !void {
        const words = cmd.encode(program);
        for (words, 0..) |word, index| {
            try self.core.writeWord(stream_at + @as(u32, @intCast(index)) * 4, word);
        }
        poke(&self.unit, npu.off.qbase, stream_at);
        poke(&self.unit, npu.off.qsize, cmd.header.bytes);
        self.unit.write(npu.regionAddress(program.source), 4, source_at);
        self.unit.write(npu.regionAddress(program.destination), 4, destination_at);
    }

    fn kick(self: *Bench) void {
        poke(&self.unit, npu.off.command, npu.field.cmd_run);
    }
};

test "a fresh block is quiet and answers with its identity" {
    var unit = npu.Npu.init();
    try std.testing.expect(unit.quiet());
    try std.testing.expectEqual(npu.identity, peek(&unit, npu.off.id));
    try std.testing.expectEqual(@as(u32, 0), peek(&unit, npu.off.status));
    try std.testing.expect(!unit.quiet());
}

test "firmware cannot write its own identity or its own status" {
    var unit = npu.Npu.init();
    poke(&unit, npu.off.id, 0xDEAD_BEEF);
    poke(&unit, npu.off.status, npu.field.status_cmd_end);
    try std.testing.expectEqual(@as(u32, 2), unit.faked);
    try std.testing.expectEqual(npu.identity, peek(&unit, npu.off.id));
    try std.testing.expectEqual(@as(u32, 0), peek(&unit, npu.off.status));
}

test "CMD is a command, not a setting: it reads back zero" {
    var unit = npu.Npu.init();
    poke(&unit, npu.off.command, npu.field.cmd_run);
    try std.testing.expectEqual(@as(u32, 0), peek(&unit, npu.off.command));
}

test "a kick with no memory behind the block faults instead of completing" {
    var unit = npu.Npu.init();
    poke(&unit, npu.off.command, npu.field.cmd_run);
    try std.testing.expectEqual(@as(u32, 1), unit.unreachable_memory);
    try std.testing.expectEqual(@as(u32, 0), unit.jobs);
    try std.testing.expect(peek(&unit, npu.off.status) & npu.field.status_bus_error != 0);
    // No completion for a poll to collect.
    try std.testing.expect(peek(&unit, npu.off.status) & npu.field.status_cmd_end == 0);
}

test "a fault raises the interrupt, the way the status bit does on silicon" {
    var unit = npu.Npu.init();
    poke(&unit, npu.off.command, npu.field.cmd_run);
    try std.testing.expect(peek(&unit, npu.off.status) & npu.field.status_irq != 0);
    const due = unit.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(npu.event.irq, due.constSlice()[0]);
    // Offered once: the next boundary has nothing to raise.
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "a copy job moves the bytes and latches a completion" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    try bench.core.write(source_at, "ra8-emulator!");
    try bench.submit(.{ .op = .copy, .source = 0, .destination = 1, .count = 13, .addend = 0 });
    bench.kick();

    try std.testing.expectEqual(@as(u32, 1), bench.unit.jobs);
    try std.testing.expectEqual(@as(u32, 13), bench.unit.moved);
    try std.testing.expectEqual(cmd.Op.copy, bench.unit.last_op.?);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.faults());
    var read_back: [13]u8 = undefined;
    try bench.core.read(destination_at, &read_back);
    try std.testing.expectEqualStrings("ra8-emulator!", &read_back);
    const status = peek(&bench.unit, npu.off.status);
    try std.testing.expect(status & npu.field.status_cmd_end != 0);
    try std.testing.expect(status & npu.field.status_irq != 0);
    // Execution is instantaneous here, so the job is never caught running.
    try std.testing.expect(status & npu.field.status_state == 0);
}

test "add-constant writes the transformed bytes, not the source ones" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    try bench.core.write(source_at, &[_]u8{ 0x01, 0xFF, 0x7F });
    try bench.submit(.{ .op = .add_constant, .source = 0, .destination = 1, .count = 3, .addend = 2 });
    bench.kick();

    var read_back: [3]u8 = undefined;
    try bench.core.read(destination_at, &read_back);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x01, 0x81 }, &read_back);
    try std.testing.expectEqual(@as(u32, 1), bench.unit.jobs);
}

test "a job longer than one chunk still moves every byte" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    const count: u32 = cmd.limits.chunk_bytes * 2 + 7;
    var payload: [cmd.limits.chunk_bytes * 2 + 7]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index);
    try bench.core.write(source_at, &payload);
    try bench.submit(.{ .op = .copy, .source = 0, .destination = 1, .count = count, .addend = 0 });
    bench.kick();

    var read_back: [cmd.limits.chunk_bytes * 2 + 7]u8 = undefined;
    try bench.core.read(destination_at, &read_back);
    try std.testing.expectEqualSlices(u8, &payload, &read_back);
    try std.testing.expectEqual(count, bench.unit.moved);
}

test "an opcode this model does not run moves nothing, where dev copies" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    try bench.core.write(source_at, "abcd");
    try bench.submit(.{ .op = .copy, .source = 0, .destination = 1, .count = 4, .addend = 0 });
    // Overwrite the opcode with one outside the two implemented ones.
    try bench.core.writeWord(stream_at, cmd.header.magic | 7);
    bench.kick();

    try std.testing.expectEqual(@as(u32, 1), bench.unit.unknown_ops);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.jobs);
    var read_back: [4]u8 = undefined;
    try bench.core.read(destination_at, &read_back);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &read_back);
    const status = peek(&bench.unit, npu.off.status);
    try std.testing.expect(status & npu.field.status_parse != 0);
    try std.testing.expect(status & npu.field.status_cmd_end == 0);
}

test "a stream with no stand-in marker runs as Vela, counted apart" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    // NPU_OP_IRQ, then the stand-in's source word (region 0) reads as STOP.
    try bench.submit(.{ .op = .copy, .source = 0, .destination = 1, .count = 4, .addend = 0 });
    try bench.core.writeWord(stream_at, 0x0000_0001);
    bench.kick();

    try std.testing.expectEqual(@as(u32, 1), bench.unit.vela.jobs);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.malformed);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.unknown_ops);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.jobs);
    try std.testing.expect(peek(&bench.unit, npu.off.status) & npu.field.status_cmd_end != 0);
}

test "a region with no base programmed is not an address" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    try bench.submit(.{ .op = .copy, .source = 0, .destination = 1, .count = 4, .addend = 0 });
    // Region 1 loses its base: a zero BASEPn was never programmed.
    bench.unit.write(npu.regionAddress(1), 4, 0);
    bench.kick();

    try std.testing.expectEqual(@as(u32, 1), bench.unit.unmapped_region);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.jobs);
}

test "a region above the 32-bit guest space is refused, not truncated" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    try bench.submit(.{ .op = .copy, .source = 0, .destination = 1, .count = 4, .addend = 0 });
    bench.unit.write(npu.regionAddress(1) + npu.geometry.hi_offset, 4, 1);
    bench.kick();

    try std.testing.expectEqual(@as(u32, 1), bench.unit.unmapped_region);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.jobs);
}

test "an arena the guest cannot reach faults rather than half-moving" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    try bench.submit(.{ .op = .copy, .source = 0, .destination = 1, .count = 16, .addend = 0 });
    // Nothing is mapped here, so the destination write cannot land.
    bench.unit.write(npu.regionAddress(1), 4, 0x7000_0000);
    bench.kick();

    try std.testing.expectEqual(@as(u32, 1), bench.unit.unreachable_memory);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.jobs);
    // The first chunk was the refused one, so the job is short of nothing.
    try std.testing.expectEqual(@as(u32, 1), bench.unit.short_jobs);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.short_bytes);
}

test "a destination that walks off mapped memory ends the job where it stands" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    // One chunk fits below the top of the arena, the next one does not.
    const edge = arena_base + arena_size - cmd.limits.chunk_bytes;
    const count: u32 = cmd.limits.chunk_bytes * 2;
    try bench.submit(.{ .op = .copy, .source = 0, .destination = 1, .count = count, .addend = 0 });
    bench.unit.write(npu.regionAddress(1), 4, edge);
    bench.kick();

    try std.testing.expectEqual(@as(u32, 1), bench.unit.short_jobs);
    try std.testing.expectEqual(@as(u32, cmd.limits.chunk_bytes), bench.unit.short_bytes);
    try std.testing.expectEqual(@as(u32, 1), bench.unit.unreachable_memory);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.jobs);
    // The job did not finish, so a driver polling for completion sees none.
    const status = peek(&bench.unit, npu.off.status);
    try std.testing.expect(status & npu.field.status_bus_error != 0);
    try std.testing.expect(status & npu.field.status_cmd_end == 0);
}

test "the bytes a short job moved are in the destination arena" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    var payload: [cmd.limits.chunk_bytes]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index);
    try bench.core.write(source_at, &payload);

    const edge = arena_base + arena_size - cmd.limits.chunk_bytes;
    const count: u32 = cmd.limits.chunk_bytes * 2;
    try bench.submit(.{ .op = .add_constant, .source = 0, .destination = 1, .count = count, .addend = 1 });
    bench.unit.write(npu.regionAddress(1), 4, edge);
    bench.kick();

    var read_back: [cmd.limits.chunk_bytes]u8 = undefined;
    try bench.core.read(edge, &read_back);
    for (read_back, payload) |got, want| {
        try std.testing.expectEqual(want +% 1, got);
    }
    try std.testing.expectEqual(@as(u32, cmd.limits.chunk_bytes), bench.unit.short_bytes);
}

test "a source that walks off the arena is short at the same boundary" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    const edge = arena_base + arena_size - cmd.limits.chunk_bytes;
    const count: u32 = cmd.limits.chunk_bytes * 2;
    try bench.submit(.{ .op = .copy, .source = 0, .destination = 1, .count = count, .addend = 0 });
    bench.unit.write(npu.regionAddress(0), 4, edge);
    bench.kick();

    try std.testing.expectEqual(@as(u32, 1), bench.unit.short_jobs);
    try std.testing.expectEqual(@as(u32, cmd.limits.chunk_bytes), bench.unit.short_bytes);
}

test "a short job leaves the last completed job's result alone" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    try bench.core.write(source_at, "ra8");
    try bench.submit(.{ .op = .copy, .source = 0, .destination = 1, .count = 3, .addend = 0 });
    bench.kick();
    const check = bench.unit.last_check;
    try std.testing.expectEqual(@as(u32, 3), bench.unit.moved);

    const edge = arena_base + arena_size - cmd.limits.chunk_bytes;
    try bench.submit(.{
        .op = .copy,
        .source = 0,
        .destination = 1,
        .count = cmd.limits.chunk_bytes * 2,
        .addend = 0,
    });
    bench.unit.write(npu.regionAddress(1), 4, edge);
    bench.kick();

    try std.testing.expectEqual(@as(u32, 1), bench.unit.jobs);
    try std.testing.expectEqual(@as(u32, 3), bench.unit.moved);
    try std.testing.expectEqual(check, bench.unit.last_check);
    try std.testing.expectEqual(@as(u32, 3), bench.unit.last_bytes);
}

test "a job that runs a region onto itself is counted as the no-op it is" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    try bench.core.write(source_at, "same");
    try bench.submit(.{ .op = .copy, .source = 0, .destination = 0, .count = 4, .addend = 0 });
    bench.kick();

    try std.testing.expectEqual(@as(u32, 1), bench.unit.jobs);
    try std.testing.expectEqual(@as(u32, 1), bench.unit.in_place);
}

test "the acknowledge clears the interrupt, and the kick beside it keeps one" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    try bench.submit(.{ .op = .copy, .source = 0, .destination = 1, .count = 4, .addend = 0 });
    bench.kick();
    _ = bench.unit.dueEvents();
    poke(&bench.unit, npu.off.command, npu.field.cmd_clear_irq);
    try std.testing.expect(peek(&bench.unit, npu.off.status) & npu.field.status_irq == 0);

    // Acknowledge and run in one write: the new job's interrupt stands.
    poke(&bench.unit, npu.off.command, npu.field.cmd_clear_irq | npu.field.cmd_run);
    try std.testing.expectEqual(@as(u32, 2), bench.unit.jobs);
    try std.testing.expect(peek(&bench.unit, npu.off.status) & npu.field.status_irq != 0);
}

test "reset discards the job state and the interrupt it left standing" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    try bench.submit(.{ .op = .copy, .source = 0, .destination = 1, .count = 4, .addend = 0 });
    bench.kick();
    poke(&bench.unit, npu.off.reset, 1);
    try std.testing.expectEqual(@as(u32, 0), peek(&bench.unit, npu.off.status));
    try std.testing.expectEqual(@as(usize, 0), bench.unit.dueEvents().len);
}

test "a narrow store keeps the bytes it does not name" {
    var unit = npu.Npu.init();
    poke(&unit, npu.off.qbase, 0x1234_5678);
    unit.write(at(npu.off.qbase), 2, 0xBEEF);
    try std.testing.expectEqual(@as(u32, 0x1234_BEEF), peek(&unit, npu.off.qbase));
    try std.testing.expectEqual(@as(u32, 0xBEEF), unit.read(at(npu.off.qbase), 2));
    try std.testing.expectEqual(@as(u32, 0x1234), unit.read(at(npu.off.qbase) + 2, 2));
    try std.testing.expectEqual(@as(u32, 0xEF), unit.read(at(npu.off.qbase), 1));
}

test "the window answers only inside itself" {
    var unit = npu.Npu.init();
    unit.write(npu.win_base + npu.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(npu.win_base + npu.win_span, 4));
    try std.testing.expect(unit.quiet());
}

test "the block describes itself to the bus" {
    var unit = npu.Npu.init();
    const block = unit.block();
    try std.testing.expectEqualStrings("NPU", block.name);
    try std.testing.expectEqual(npu.win_base, block.base);
    try std.testing.expectEqual(npu.win_span, block.size);
}
