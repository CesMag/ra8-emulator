const std = @import("std");
const ra8 = @import("ra8");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const image = if (args.len > 1) args[1] else "../fixtures/plug/gauge_poll.elf";
    const input: ?[]const u8 = if (args.len > 2) args[2] else null;
    var opened = try ra8.session.harness.open(allocator, io, .{ .elf_path = image, .input_script = input });
    defer opened.deinit();
    if (input == null) {
        if (opened.session().currentCore() != .cpu0) return error.WrongCore;
        try std.Io.File.stdout().writeStreamingAll(io, "harness: opened CPU0\n");
        return;
    }
    try smokeFrames(allocator, io, &opened, if (args.len > 3) args[3] else null);
}

fn smokeFrames(allocator: std.mem.Allocator, io: std.Io, opened: *ra8.session.harness.Harness, output: ?[]const u8) !void {
    try opened.session().waitSettled(2_000_000_000);
    var before = try opened.session().frame(allocator);
    defer before.deinit(allocator);
    try opened.session().waitSettled(2_000_000_000);
    var after = try opened.session().frame(allocator);
    defer after.deinit(allocator);
    if (before.width != after.width or before.height != after.height) return error.FrameShapeChanged;
    if (std.mem.eql(u8, before.pixels, after.pixels)) return error.FrameDidNotChange;
    if (output) |directory| {
        try save(allocator, io, directory, "frame_00000.ppm", &before);
        try save(allocator, io, directory, "frame_00001.ppm", &after);
    }
    var line: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&line, "harness: {d}x{d}, frames at {d} and {d} ns\n", .{ before.width, before.height, before.virtual_ns, after.virtual_ns });
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

fn save(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, name: []const u8, frame: anytype) !void {
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const path = try std.fs.path.join(allocator, &.{ directory, name });
    defer allocator.free(path);
    const ppm = try frame.ppm(allocator);
    defer allocator.free(ppm);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = ppm });
}
