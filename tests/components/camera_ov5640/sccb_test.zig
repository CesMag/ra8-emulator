//! The OV5640's SCCB side: the 16-bit pointer, the chip id, and the registers
//! a firmware verifier reads back.
const std = @import("std");
const ra8 = @import("ra8");
const ov5640 = ra8.components.ov5640;

fn point(sensor: *ov5640.Sensor, register: u16) void {
    sensor.write(@truncate(register >> 8));
    sensor.write(@truncate(register & 0xFF));
}

test "the chip id reads 0x5640 across the two registers" {
    var sensor = ov5640.Sensor{};
    point(&sensor, ov5640.reg.id_high);
    var buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), sensor.read(buffer[0..]));
    try std.testing.expectEqual(@as(u8, 0x56), buffer[0]);
    sensor.stop();
    point(&sensor, ov5640.reg.id_low);
    _ = sensor.read(buffer[0..]);
    try std.testing.expectEqual(@as(u8, 0x40), buffer[0]);
    try std.testing.expectEqual(@as(u32, 2), sensor.id_reads);
}

test "the pointer is two big-endian bytes" {
    var sensor = ov5640.Sensor{};
    point(&sensor, ov5640.reg.format);
    try std.testing.expectEqual(ov5640.reg.format, sensor.pointer);
}

test "a configuration register reads back what was written" {
    var sensor = ov5640.Sensor{};
    point(&sensor, ov5640.reg.format);
    sensor.write(0x61);
    var buffer: [1]u8 = undefined;
    _ = sensor.read(buffer[0..]);
    try std.testing.expectEqual(@as(u8, 0x61), buffer[0]);
    try std.testing.expectEqual(@as(u32, 1), sensor.writes);
}

test "all three verified registers are latched apart" {
    var sensor = ov5640.Sensor{};
    point(&sensor, ov5640.reg.format);
    sensor.write(0x61);
    sensor.stop();
    point(&sensor, ov5640.reg.isp_mux);
    sensor.write(0x01);
    sensor.stop();
    point(&sensor, ov5640.reg.test_pattern);
    sensor.write(0x80);
    try std.testing.expectEqual(@as(u8, 0x61), sensor.format);
    try std.testing.expectEqual(@as(u8, 0x01), sensor.isp_mux);
    try std.testing.expectEqual(@as(u8, 0x80), sensor.test_pattern);
    try std.testing.expectEqual(@as(u32, 3), sensor.writes);
}

test "a write to a register this model does not carry is counted apart" {
    var sensor = ov5640.Sensor{};
    point(&sensor, 0x3008);
    sensor.write(0x42);
    try std.testing.expectEqual(@as(u32, 0), sensor.writes);
    try std.testing.expectEqual(@as(u32, 1), sensor.unmodelled);
    var buffer: [1]u8 = undefined;
    _ = sensor.read(buffer[0..]);
    try std.testing.expectEqual(@as(u8, 0), buffer[0]);
}

test "SCCB has no auto-increment: a second read serves the same register" {
    var sensor = ov5640.Sensor{};
    point(&sensor, ov5640.reg.id_high);
    var buffer: [1]u8 = undefined;
    _ = sensor.read(buffer[0..]);
    try std.testing.expectEqual(@as(u8, 0x56), buffer[0]);
    _ = sensor.read(buffer[0..]);
    try std.testing.expectEqual(@as(u8, 0x56), buffer[0]);
}

test "a stop means the next transfer names a fresh register" {
    var sensor = ov5640.Sensor{};
    point(&sensor, ov5640.reg.format);
    sensor.write(0x61);
    sensor.stop();
    try std.testing.expectEqual(@as(u8, 0), sensor.pointer_bytes);
    point(&sensor, ov5640.reg.test_pattern);
    sensor.write(0x80);
    try std.testing.expectEqual(@as(u8, 0x61), sensor.format);
    try std.testing.expectEqual(@as(u8, 0x80), sensor.test_pattern);
}

test "an empty buffer is served nothing" {
    var sensor = ov5640.Sensor{};
    var buffer: [0]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), sensor.read(buffer[0..]));
}
