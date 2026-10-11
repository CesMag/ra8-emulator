//! RA8EMU-954's done condition: on a ThreadX fixture with two threads,
//! `--profile-thread` folds each thread's sampled stacks apart, and the
//! per-thread files sum to the unfiltered file for the same run.
//!
//! The fixture is the real DFU bootloader (tests/fixtures/dfu/README.md).
//! `--trace-rtos` shows it switching in `dfu_device` (TCB 0x22025060) and
//! USBX's DFU class thread (TCB 0x2201C7A0); thread 0 holds what was
//! sampled while neither ran (startup and idle). Those three cover every
//! sample the run takes.
const std = @import("std");
const test_paths = @import("test_paths");

const gpa = std.testing.allocator;
const Term = std.process.Child.Term;
const image = "tests/fixtures/dfu/dfu_bootloader.elf";
const instructions = "3000000";
const dfu_device = "0x22025060";
const dfu_class = "0x2201C7A0";

/// One run's folded file, all threads (`thread` null) or one.
fn foldedRun(thread: ?[]const u8) ![]u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/run.folded", .{tmp.sub_path});
    defer gpa.free(path);
    const all = [_][]const u8{ test_paths.emulator, image, "--cpu", "zig", "--instructions", instructions, "--trace-rtos", "--profile-folded", path };
    var argv: [all.len + 2][]const u8 = undefined;
    @memcpy(argv[0..all.len], &all);
    var len: usize = all.len;
    if (thread) |tcb| {
        argv[len] = "--profile-thread";
        argv[len + 1] = tcb;
        len += 2;
    }
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = argv[0..len], .stdout_limit = .limited(1 << 20) });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
    return tmp.dir.readFileAlloc(std.testing.io, "run.folded", gpa, .limited(1 << 20));
}

/// Samples across every row.
fn total(folded: []const u8) !u64 {
    var sum: u64 = 0;
    var lines = std.mem.splitScalar(u8, folded, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const gap = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return error.BadRow;
        sum += try std.fmt.parseInt(u64, line[gap + 1 ..], 10);
    }
    return sum;
}

test "each ThreadX thread folds apart and the threads sum to the whole run" {
    const whole = try foldedRun(null);
    defer gpa.free(whole);
    const device = try foldedRun(dfu_device);
    defer gpa.free(device);
    const class = try foldedRun(dfu_class);
    defer gpa.free(class);
    const none = try foldedRun("0");
    defer gpa.free(none);
    try std.testing.expect(try total(device) != 0);
    try std.testing.expect(try total(class) != 0);
    try std.testing.expect(!std.mem.eql(u8, device, class));
    try std.testing.expectEqual(try total(whole), try total(device) + try total(class) + try total(none));
}

test "a thread that never ran folds nothing" {
    const folded = try foldedRun("0x20000000");
    defer gpa.free(folded);
    try std.testing.expectEqual(@as(u64, 0), try total(folded));
}
