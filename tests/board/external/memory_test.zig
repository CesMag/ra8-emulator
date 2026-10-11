const std = @import("std");
const ra8 = @import("ra8");
const memory = ra8.board.external_memory;

test "layout accepts capacities and aliases only inside configured regions" {
    var config: memory.Config = .{};
    config.ospi.size = 16 * 1024 * 1024;
    config.sdram.size = 32 * 1024 * 1024;
    const layout = try memory.Layout.init(config);
    try std.testing.expectEqual(memory.Kind.ospi, layout.locate(0x8000_0010, 4).?.kind);
    try std.testing.expectEqual(memory.Kind.sdram, layout.locate(0x7800_0010, 4).?.kind);
    try std.testing.expect(layout.locate(0x6A00_0000, 1) == null);
    try std.testing.expect(layout.locate(0x81FF_FFFE, 4) == null);
}

test "single and incrementing bursts use the configured transfer equation" {
    const one: memory.RegionConfig = .{ .size = 1024 * 1024, .width = 32, .clock_hz = 100_000_000, .latency_cycles = 1, .burst = .single };
    try std.testing.expectEqual(@as(u64, 20), memory.serviceCycles(one, 1));
    const sixteen: memory.RegionConfig = .{ .size = 1024 * 1024, .width = 8, .clock_hz = 100_000_000, .latency_cycles = 2, .burst = .incrementing16 };
    try std.testing.expectEqual(@as(u64, 180), memory.serviceCycles(sixteen, 16));
}

test "CPU and Ethos accesses serialize and report region usage" {
    var config: memory.Config = .{};
    config.sdram = .{ .size = 1024 * 1024, .width = 32, .clock_hz = 100_000_000, .latency_cycles = 1, .burst = .incrementing16 };
    config.window_cycles = 100;
    var fabric = memory.Fabric.init(try memory.Layout.init(config));
    const first = fabric.layout.locate(0x6800_0010, 16).?;
    fabric.note(.ethos_u55, first, .write, 16);
    fabric.note(.cpu0, fabric.layout.locate(0x7800_0020, 4).?, .read, 4);
    const counters = fabric.counters(.sdram, 0);
    try std.testing.expectEqual(@as(u64, 16), counters.bytes_written);
    try std.testing.expectEqual(@as(u64, 4), counters.bytes_read);
    try std.testing.expectEqual(@as(u64, 0x24), counters.read_high_water_bytes);
    try std.testing.expectEqual(@as(u64, 0x20), counters.write_high_water_bytes);
    try std.testing.expect(counters.ethos_u55_stall_cycles != 0);
    try std.testing.expect(counters.cpu_stall_cycles > memory.serviceCycles(config.sdram, 4));
    try std.testing.expect(counters.peak_read_bytes_per_second != 0);
    try std.testing.expect(counters.average_write_bytes_per_second != 0);
}

test "untimed accesses bypass counters and pending stalls" {
    var fabric = memory.Fabric.init(memory.Layout.defaults());
    fabric.note(.none, fabric.layout.locate(0x6800_0000, 4).?, .read, 4);
    try std.testing.expectEqual(memory.Counters{}, fabric.counters(.sdram, 100));
    try std.testing.expectEqual(@as(u64, 0), fabric.takePending(.none));
}

test "a report after a window boundary finalizes its peak denominator" {
    var config: memory.Config = .{};
    config.window_cycles = 100;
    var fabric = memory.Fabric.init(try memory.Layout.init(config));
    fabric.note(.cpu0, fabric.layout.locate(0x6800_0000, 4).?, .read, 4);
    const counters = fabric.counters(.sdram, 100);
    try std.testing.expectEqual(@as(u64, 40_000_000), counters.peak_read_bytes_per_second);
}
