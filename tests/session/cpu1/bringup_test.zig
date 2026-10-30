//! Offline CPU1 startup owns its input and publishes only a complete core.
const std = @import("std");
const ra8 = @import("ra8");
const gpa = std.testing.allocator;
const first = @embedFile("../../fixtures/trustzone/cpu1_pingpong_ipc.elf");
const second = @embedFile("../../fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
const tree_address: u32 = 0x20000200;

/// Keep the executable segments, replacing only the debug symbol tables.
fn widgetImage() ![]u8 {
    const start = (second.len + 3) & ~@as(usize, 3);
    const name = "\x00ra8_widget_debug_tree\x00";
    const bytes = try gpa.alloc(u8, start + 152 + name.len);
    @memset(bytes, 0);
    @memcpy(bytes[0..second.len], second);
    std.mem.writeInt(u32, bytes[32..36], @intCast(start), .little);
    std.mem.writeInt(u16, bytes[46..48], 40, .little);
    std.mem.writeInt(u16, bytes[48..50], 3, .little);
    std.mem.writeInt(u16, bytes[50..52], 0, .little);
    const headers = bytes[start..][0..120];
    const symtab = headers[40..80];
    std.mem.writeInt(u32, symtab[4..8], 2, .little);
    std.mem.writeInt(u32, symtab[16..20], @intCast(start + 120), .little);
    std.mem.writeInt(u32, symtab[20..24], 32, .little);
    std.mem.writeInt(u32, symtab[24..28], 2, .little);
    std.mem.writeInt(u32, symtab[36..40], 16, .little);
    const strings = headers[80..120];
    std.mem.writeInt(u32, strings[4..8], 3, .little);
    std.mem.writeInt(u32, strings[16..20], @intCast(start + 152), .little);
    std.mem.writeInt(u32, strings[20..24], name.len, .little);
    const symbol = bytes[start + 136 ..][0..16];
    std.mem.writeInt(u32, symbol[0..4], 1, .little);
    std.mem.writeInt(u32, symbol[4..8], tree_address, .little);
    @memcpy(bytes[start + 152 ..], name);
    return bytes;
}

test "path and offline CPU1 startup register the published widget tree and permit taps" {
    const bytes = try widgetImage();
    defer gpa.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "widgets.elf", .data = bytes });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "widgets.elf", gpa);
    defer gpa.free(path);
    for ([_]bool{ false, true }) |offline| {
        var h = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = "absent.elf", .elf_bytes = first });
        defer h.deinit();
        var cpu1: ra8.session.cpu1.bringup.Cpu1 = .{};
        if (offline) try cpu1.openBytes(gpa, &h, bytes) else try cpu1.open(gpa, std.testing.io, std.Io.Dir.cwd(), &h, path);
        defer cpu1.close(gpa);
        try std.testing.expectEqual(@as(?u32, tree_address), ra8.session.symbols.addressOf(cpu1.image.?, ra8.session.widget_tree.symbol));
        var channel: [104]u8 = @splat(0);
        std.mem.writeInt(u32, channel[0..4], ra8.session.widget_tree.magic, .little);
        std.mem.writeInt(u16, channel[4..6], 1, .little);
        std.mem.writeInt(u16, channel[6..8], 1, .little);
        @memcpy(channel[16..27], "cpu1_button");
        @memcpy(channel[48..54], "button");
        @memcpy(channel[64..69], "ready");
        std.mem.writeInt(i32, channel[88..92], 20, .little);
        std.mem.writeInt(i32, channel[92..96], 30, .little);
        std.mem.writeInt(i32, channel[96..100], 40, .little);
        std.mem.writeInt(i32, channel[100..104], 20, .little);
        try cpu1.guest().write(tree_address, &channel);
        const widgets = try h.session().widgets(gpa, .cpu1);
        defer gpa.free(widgets);
        try std.testing.expectEqual(@as(usize, 1), widgets.len);
        try std.testing.expectEqualStrings("cpu1_button", widgets[0].nameSlice());
        try std.testing.expectEqual(ra8.session.widget_tree.Rect{ .x = 20, .y = 30, .w = 40, .h = 20 }, widgets[0].rect);
        try h.session().tapWidget(gpa, .cpu1, 0, "cpu1_button");
        try h.session().tapWidgetPart(gpa, .cpu1, 1, "cpu1_button", .{ .at = .{ .x_pct = 25, .y_pct = 75 } });
    }
}

test "failed bytes startup leaves no attached core and permits a successful retry" {
    var h = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = "absent.elf", .elf_bytes = first });
    defer h.deinit();
    var cpu1: ra8.session.cpu1.bringup.Cpu1 = .{};
    try std.testing.expectError(error.Truncated, cpu1.openBytes(gpa, &h, "invalid"));
    try std.testing.expectEqual(@as(usize, 0), cpu1.bytes.len);
    try std.testing.expect(cpu1.image == null);
    try std.testing.expect(h.session().live.other == null);
    try std.testing.expect(h.state.files.pair == null);
    const bytes = try gpa.dupe(u8, second);
    defer gpa.free(bytes);
    try cpu1.openBytes(gpa, &h, bytes);
    defer cpu1.close(gpa);
    @memset(bytes, 0);
    try std.testing.expectEqualSlices(u8, second, cpu1.bytes);
    try std.testing.expectEqualSlices(u8, second, h.loadedImage(.cpu1).?.bytes);
    try std.testing.expect(h.state.files.pair == &cpu1.pair);
}
