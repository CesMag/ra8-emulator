//! The ctl discovery reader's tests (RA8EMU-1156): what it reads back
//! from the discovery file the serve app announced. Split out of the
//! host listener test file so the file stays small.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

/// A fresh home under /tmp for one test.
const tempHome = @import("host_listener_helpers.zig").tempHome;
const envWithHome = @import("host_listener_helpers.zig").envWithHome;
test "ctl's discovery reader reads what the app announced" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    const ctl = cli_app.ctl;

    // No file, no app.
    try std.testing.expectEqual(@as(?ctl.discovery.Snapshot, null), try ctl.discovery.read(gpa, std.testing.io, &env));

    var file_path = std.ArrayList(u8).empty;
    defer file_path.deinit(gpa);
    try file_path.appendSlice(gpa, home);
    try file_path.appendSlice(gpa, "/.config/ra8_emulator");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, file_path.items);
    try file_path.appendSlice(gpa, "/discovery");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path.items, .data = "rpc unix:/tmp/rpc.sock\nsession 4113 /work/blink.elf\nsession 5222 /work/my fw.elf\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const snapshot = (try ctl.discovery.read(arena_state.allocator(), std.testing.io, &env)).?;
    try std.testing.expectEqualStrings("unix:/tmp/rpc.sock", snapshot.rpc);
    try std.testing.expectEqual(@as(usize, 2), snapshot.sessions.len);
    try std.testing.expectEqual(@as(u16, 4113), snapshot.sessions[0].port);
    try std.testing.expectEqualStrings("/work/blink.elf", snapshot.sessions[0].elf);
    // An ELF with a space survives the line split.
    try std.testing.expectEqualStrings("/work/my fw.elf", snapshot.sessions[1].elf);
}
