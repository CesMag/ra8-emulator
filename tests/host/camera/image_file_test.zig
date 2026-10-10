//! Covers src/host/camera/image_file.zig: a picture on disk picked up by
//! its magic bytes and shown at every capture, written through the camera's
//! hosted source into the firmware's buffer pixel for pixel.
const std = @import("std");
const ra8 = @import("ra8");

const image_file = ra8.host.camera.image_file;
const ceu = ra8.chip.periph.ceu;
const hosted = ra8.components.camera.hosted;
const FrameSource = ceu.camera.frame_source.FrameSource;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const allocator = std.testing.allocator;

/// A 2x2 P6 picture: red, green / blue, white.
const ppm_bytes = "P6\n2 2\n255\n" ++ [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };

/// The same picture as a bottom-up 24-bit BMP (rows padded to 8 bytes).
fn bmpBytes() [70]u8 {
    var b = @as([70]u8, @splat(0));
    b[0] = 'B';
    b[1] = 'M';
    std.mem.writeInt(u32, b[2..6], 70, .little);
    std.mem.writeInt(u32, b[10..14], 54, .little);
    std.mem.writeInt(u32, b[14..18], 40, .little);
    std.mem.writeInt(i32, b[18..22], 2, .little);
    std.mem.writeInt(i32, b[22..26], 2, .little);
    std.mem.writeInt(u16, b[26..28], 1, .little);
    std.mem.writeInt(u16, b[28..30], 24, .little);
    // Bottom row first, pixels in B, G, R order.
    @memcpy(b[54..60], &[_]u8{ 255, 0, 0, 255, 255, 255 });
    @memcpy(b[62..68], &[_]u8{ 0, 0, 255, 0, 255, 0 });
    return b;
}

/// RGB565 little-endian bytes of red, green / blue, white.
const rgb565_rows = [2][4]u8{ .{ 0x00, 0xF8, 0xE0, 0x07 }, .{ 0x1F, 0x00, 0xFF, 0xFF } };

fn writeFile(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
}

fn load(dir: std.testing.TmpDir, name: []const u8) !*image_file.Still {
    const path = try dir.dir.realPathFileAlloc(std.testing.io, name, allocator);
    defer allocator.free(path);
    return image_file.Still.load(allocator, std.testing.io, path);
}

fn loadFrom(dir: std.testing.TmpDir, name: []const u8, format_control: *const u8) !FrameSource {
    const still = try load(dir, name);
    errdefer still.close();
    return hosted.Hosted(image_file.Still).open(allocator, still, format_control, "still image", name);
}

test "every capture shows the same decoded picture" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ppm", ppm_bytes);
    const still = try load(tmp, "a.ppm");
    defer still.close();
    const rgb = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };
    try std.testing.expectEqualSlices(u8, &rgb, still.picture(0).pixels);
    try std.testing.expectEqualSlices(u8, &rgb, still.picture(5_000_000_000).pixels);
    try std.testing.expectEqual(@as(u32, 2), still.picture(0).width);
}

test "a PPM and a BMP of the same picture fill the same RGB565 bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ppm", ppm_bytes);
    const bmp = bmpBytes();
    try writeFile(tmp.dir, "b.dat", &bmp); // no extension: the magic bytes decide
    var format_control: u8 = 0x6F;
    for ([_][]const u8{ "a.ppm", "b.dat" }) |name| {
        const source = try loadFrom(tmp, name, &format_control);
        defer source.close();
        source.frame(0, .{ .width = 4, .lines = 2 });
        for (rgb565_rows, 0..) |expected, row| {
            var line: [4]u8 = undefined;
            source.fill(@intCast(row), 0, &line);
            try std.testing.expectEqualSlices(u8, &expected, &line);
        }
    }
}

test "a file no decoder claims and a missing file are refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "x.txt", "hello");
    var format_control: u8 = 0x30;
    try std.testing.expectError(error.Unsupported, loadFrom(tmp, "x.txt", &format_control));
    try std.testing.expectError(error.FileNotFound, image_file.Still.load(allocator, std.testing.io, "/nonexistent/ra8.png"));
}

test "an armed CEU capture writes the picture's pixels into the buffer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ppm", ppm_bytes);
    var format_control: u8 = 0x6F;
    const source = try loadFrom(tmp, "a.ppm", &format_control);
    const store = try allocator.create(Store);
    defer allocator.destroy(store);
    store.* = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = store };
    // SDRAM, which the Zig core's store already backs.
    const base: u32 = 0x6800_0000;
    var unit = ceu.Ceu.init();
    unit.memory = core;
    unit.source = source;
    defer unit.source.close();
    unit.write(ceu.win_base + ceu.off.capwr, 4, 4 | 2 << ceu.field.vertical_shift);
    unit.write(ceu.win_base + ceu.off.cdwdr, 4, 4);
    unit.write(ceu.win_base + ceu.off.cdayr, 4, base);
    unit.write(ceu.win_base + ceu.off.capsr, 4, ceu.field.capture_enable);
    try std.testing.expectEqual(@as(u32, 1), unit.frames);
    var buffer: [8]u8 = undefined;
    try core.read(base, &buffer);
    try std.testing.expectEqualSlices(u8, &(rgb565_rows[0] ++ rgb565_rows[1]), &buffer);
}
