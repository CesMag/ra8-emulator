//! On-demand RTOS metrics use each core's loaded symbols and stable listeners.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = "tests/fixtures/threadx/threadx_stkof.elf";

fn threadTicks(snapshot: ra8.session.device_metrics.Snapshot, id: u32) u64 {
    for (snapshot.owners[0..snapshot.owner_count]) |owner| {
        if (owner.owner.kind == .thread and owner.owner.id == id) return owner.ticks;
    }
    return 0;
}

test "device metrics auto-arm independent CPU0 and CPU1 RTOS owners" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = fixture });
    defer opened.deinit();
    var secondary: ra8.session.cpu1.bringup.Cpu1 = .{};
    try secondary.open(std.testing.allocator, std.testing.io, std.Io.Dir.cwd(), &opened, fixture);
    defer secondary.close(std.testing.allocator);
    const other = secondary.cpu();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture, std.testing.allocator, .limited(8 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try opened.session().load(.cpu1, bytes);
    try std.testing.expect(opened.session().deviceMetrics(.cpu0).rtos);
    try std.testing.expect(opened.session().deviceMetrics(.cpu1).rtos);
    const pointer0 = opened.state.metrics_tracking[0].tracer.address;
    const pointer1 = opened.state.metrics_tracking[1].tracer.address;
    opened.primaryCpu().retired = 10;
    try opened.primaryCpu().bus.writeWord(pointer0, 0x1111);
    other.retired = 20;
    try other.bus.writeWord(pointer1, 0x2222);
    opened.primaryCpu().retired = 40;
    other.retired = 70;
    const first = opened.session().deviceMetrics(.cpu0);
    const second = opened.session().deviceMetrics(.cpu1);
    try std.testing.expectEqual(@as(u64, 30), threadTicks(first, 0x1111));
    try std.testing.expectEqual(@as(u64, 50), threadTicks(second, 0x2222));
    try std.testing.expectEqual(@as(u64, 0), threadTicks(first, 0x2222));
    try std.testing.expectEqual(@as(u64, 0), threadTicks(second, 0x1111));
}

test "device metrics replaces RTOS symbol after reload without nesting listeners" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = fixture });
    defer opened.deinit();
    try std.testing.expect(opened.session().deviceMetrics(.cpu0).rtos);
    const original_inner = opened.state.metrics_tracking[0].listener.inner_bus.ctx;
    const plain = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/gpio/blink.elf", std.testing.allocator, .limited(8 * 1024 * 1024));
    defer std.testing.allocator.free(plain);
    try opened.session().load(.cpu0, plain);
    try std.testing.expect(!opened.session().deviceMetrics(.cpu0).rtos);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture, std.testing.allocator, .limited(8 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try opened.session().load(.cpu0, bytes);
    try std.testing.expect(opened.session().deviceMetrics(.cpu0).rtos);
    try std.testing.expectEqual(original_inner, opened.state.metrics_tracking[0].listener.inner_bus.ctx);
    const cpu = opened.primaryCpu();
    cpu.retired = 5;
    try cpu.bus.writeWord(opened.state.metrics_tracking[0].tracer.address, 0x3333);
    cpu.retired = 15;
    try std.testing.expectEqual(@as(u64, 10), threadTicks(opened.session().deviceMetrics(.cpu0), 0x3333));
}

test "device metrics seed already running thread and discard future RTOS attribution after restore" {
    try restoredOwnership(false);
}

test "explicitly armed RTOS metrics discard future attribution after restore" {
    try restoredOwnership(true);
}

fn restoredOwnership(explicit: bool) !void {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = fixture });
    defer opened.deinit();
    const address = ra8.session.symbols.addressOf(opened.image(), ra8.session.rtos.hook.symbol).?;
    const cpu = opened.primaryCpu();
    if (explicit) try std.testing.expect(opened.traceIfRtos());
    cpu.retired = 100;
    try cpu.bus.writeWord(address, 0x4444);
    _ = opened.session().deviceMetrics(.cpu0);
    var saved = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saved.deinit();
    try opened.state.files.writeTo(&saved.writer);
    cpu.retired = 150;
    try std.testing.expectEqual(@as(u64, 50), threadTicks(opened.session().deviceMetrics(.cpu0), 0x4444));
    try cpu.bus.writeWord(address, 0x5555);
    cpu.retired = 200;
    try std.testing.expectEqual(@as(u64, 50), threadTicks(opened.session().deviceMetrics(.cpu0), 0x5555));
    try opened.state.files.readFrom(saved.written());
    const reset = opened.session().deviceMetrics(.cpu0);
    try std.testing.expect(!reset.sram.known);
    try std.testing.expectEqual(@as(u64, 0), threadTicks(reset, 0x5555));
    cpu.retired = 120;
    try std.testing.expectEqual(@as(u64, 20), threadTicks(opened.session().deviceMetrics(.cpu0), 0x4444));
    try opened.state.files.readFrom(saved.written());
    cpu.retired = 300;
    try std.testing.expectEqual(@as(u64, 0), threadTicks(opened.session().deviceMetrics(.cpu0), 0x4444));
    cpu.retired = 310;
    try std.testing.expectEqual(@as(u64, 10), threadTicks(opened.session().deviceMetrics(.cpu0), 0x4444));
}

test "late metrics sampling seeds an already active ISR" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = fixture });
    defer opened.deinit();
    const cpu = opened.primaryCpu();
    cpu.retired = 100;
    try std.testing.expect(cpu.active.push(.{ .number = 15, .priority = 0 }));
    _ = opened.session().deviceMetrics(.cpu0);
    cpu.retired = 130;
    const sample = opened.session().deviceMetrics(.cpu0);
    var isr: u64 = 0;
    for (sample.owners[0..sample.owner_count]) |row| {
        if (row.owner.kind == .exception and row.owner.id == 15) isr += row.ticks;
    }
    try std.testing.expectEqual(@as(u64, 30), isr);
}
