//! Per-core memory masking and attribution over real dual-core save streams.
const std = @import("std");
const ra8 = @import("ra8");
const digest = ra8.session.history_state_digest;
const gpa = std.testing.allocator;
const first = @embedFile("../../fixtures/trustzone/cpu1_pingpong_ipc.elf");
const second = @embedFile("../../fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");

fn save(h: *ra8.session.harness.Harness) !std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try h.state.files.writeTo(&out.writer);
    return out;
}

test "CPU1 registers and private memory under CPU0 code remain visible with CPU1 PCs" {
    var h = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = "absent-cpu0.elf", .elf_bytes = first });
    defer h.deinit();
    var cpu1: ra8.session.cpu1.bringup.Cpu1 = .{};
    try cpu1.openBytes(gpa, &h, second);
    defer cpu1.close(gpa);
    const image = try ra8.board.image.elf.Image.init(first);
    const mask: ra8.session.history_state_memory.Mask = .{ .a = image, .b = image };
    var before = try save(&h);
    defer before.deinit();
    const pc = cpu1.cpu().regs.pc;
    cpu1.cpu().regs.low[3] ^= 0x42;
    var registers = try save(&h);
    defer registers.deinit();
    var d = (try digest.first(before.written(), registers.written(), mask)).?;
    try std.testing.expectEqual(@as(u8, 1), d.core);
    try std.testing.expectEqualStrings("r3", d.place.register.name);
    try std.testing.expectEqual(pc, d.pc_expected);
    try std.testing.expectEqual(pc, d.pc_actual);
    try std.testing.expect(!std.mem.eql(u8, &(try digest.digest(before.written(), mask)), &(try digest.digest(registers.written(), mask))));
    cpu1.cpu().regs.low[3] ^= 0x42;
    const address = image.vectorBase().?;
    try std.testing.expect(mask.skips(address));
    try std.testing.expect(!mask.forCore(1).skips(address));
    var byte: [1]u8 = undefined;
    try cpu1.guest().read(address, &byte);
    const old = byte[0];
    byte[0] ^= 1;
    try cpu1.guest().write(address, &byte);
    var memory = try save(&h);
    defer memory.deinit();
    d = (try digest.first(before.written(), memory.written(), mask)).?;
    try std.testing.expectEqual(@as(u8, 1), d.core);
    try std.testing.expectEqual(address, d.place.memory.address);
    try std.testing.expectEqual(old, d.place.memory.expected);
    try std.testing.expectEqual(old ^ 1, d.place.memory.actual);
    try std.testing.expectEqual(pc, d.pc_actual);
    try std.testing.expect(!std.mem.eql(u8, &(try digest.digest(before.written(), mask)), &(try digest.digest(memory.written(), mask))));
    byte[0] = old;
    try cpu1.guest().write(address, &byte);
    h.session().live.other.?.started = true;
    var debug = try save(&h);
    defer debug.deinit();
    d = (try digest.first(before.written(), debug.written(), mask)).?;
    try std.testing.expectEqual(@as(u8, 1), d.core);
    try std.testing.expectEqual(ra8.snapshot.file.Kind.debug_units, d.place.section);
    try std.testing.expectEqual(pc, d.pc_actual);
}
