//! Covers src/host/camera/pipe_windows.zig: Win32 error and name handling,
//! plus a Windows-host stream through a real named pipe.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");

const camera = ra8.chip.periph.ceu.camera;
const pipe = ra8.host.camera.pipe_input;
const win = ra8.host.pipe.windows;
const Win32Error = std.os.windows.Win32Error;

const Live = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const kernel32 = windows.kernel32;
    const generic_write: windows.DWORD = 0x4000_0000;
    const open_existing: windows.DWORD = 3;

    extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) windows.DWORD;

    const Client = struct {
        handle: windows.HANDLE,
        open: bool = true,

        fn connect(name: []const u8) !Client {
            var full_buf: [256]u8 = undefined;
            const full = try win.fullName(&full_buf, name);
            var wide: [256:0]u16 = undefined;
            const len = try std.unicode.utf8ToUtf16Le(&wide, full);
            wide[len] = 0;
            const handle = kernel32.CreateFileW(wide[0..len :0], generic_write, 0, null, open_existing, 0, null);
            if (handle == windows.INVALID_HANDLE_VALUE) {
                std.debug.print("CreateFileW for camera pipe failed: {d}\n", .{@backingInt(kernel32.GetLastError())});
                return error.OpenFailed;
            }
            return .{ .handle = handle };
        }

        fn write(self: Client, bytes: []const u8) !void {
            var written: windows.DWORD = 0;
            if (kernel32.WriteFile(self.handle, bytes.ptr, @intCast(bytes.len), &written, null) == 0) {
                std.debug.print("WriteFile to camera pipe failed: {d}\n", .{@backingInt(kernel32.GetLastError())});
                return error.WriteFailed;
            }
            if (written != bytes.len) {
                std.debug.print("short camera pipe write: {d} of {d}\n", .{ written, bytes.len });
                return error.ShortWrite;
            }
        }

        fn close(self: *Client) void {
            if (!self.open) return;
            _ = CloseHandle(self.handle);
            self.open = false;
        }
    };

    fn processId() windows.DWORD {
        return GetCurrentProcessId();
    }
} else struct {};

fn expectLine(source: camera.frame_source.FrameSource, expected: [4]u8) !void {
    source.frame(0, .{ .width = 4, .lines = 1 });
    var line: [4]u8 = undefined;
    source.fill(0, 0, &line);
    try std.testing.expectEqualSlices(u8, &expected, &line);
}

test "real Windows named pipe streams frames without administrator rights" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var name_buf: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "ra8emu-585-{d}-{d}", .{ Live.processId(), std.Io.Timestamp.now(std.testing.io, .real).toNanoseconds() });
    var arg_buf: [128]u8 = undefined;
    const arg = try std.fmt.bufPrint(&arg_buf, "{s},2x1,rgb24", .{name});
    var format_control: u8 = 0x6F;
    const loaded = try pipe.Pipe.load(std.testing.allocator, std.testing.io, arg);
    const capture = try ra8.components.camera.hosted.Hosted(pipe.Pipe).open(std.testing.allocator, loaded, &format_control, "pipe", arg);
    defer capture.close();

    try expectLine(capture, .{ 0x00, 0x00, 0x00, 0x00 });

    var client = try Live.Client.connect(name);
    defer client.close();
    try client.write(&.{ 255, 0, 0, 255, 0, 0 });
    try expectLine(capture, .{ 0x00, 0xF8, 0x00, 0xF8 });
    try client.write(&.{ 0, 0, 255, 0, 0, 255 });
    try expectLine(capture, .{ 0x1F, 0x00, 0x1F, 0x00 });
    try std.testing.expectEqual(@as(u64, 2), loaded.frames);

    client.close();
    try expectLine(capture, .{ 0x1F, 0x00, 0x1F, 0x00 });
    try std.testing.expect(loaded.closed);
}

test "an empty nowait pipe would block, a listening one waits for its writer" {
    try std.testing.expectEqual(win.Outcome.would_block, win.outcome(Win32Error.NO_DATA));
    try std.testing.expectEqual(win.Outcome.listening, win.outcome(Win32Error.PIPE_LISTENING));
}

test "a writer that hung up closes the source and other errors fail" {
    try std.testing.expectEqual(win.Outcome.closed, win.outcome(Win32Error.BROKEN_PIPE));
    try std.testing.expectEqual(win.Outcome.closed, win.outcome(Win32Error.PIPE_NOT_CONNECTED));
    try std.testing.expectEqual(win.Outcome.failed, win.outcome(Win32Error.ACCESS_DENIED));
}

test "a bare name gains the pipe prefix" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\\\\.\\pipe\\ra8cam", try win.fullName(&buf, "ra8cam"));
}

test "a full pipe path is kept as given, in any case" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\\\\.\\PIPE\\cam", try win.fullName(&buf, "\\\\.\\PIPE\\cam"));
}

test "a file path, an empty name or a bare prefix is not a pipe" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.NotAPipe, win.fullName(&buf, "C:\\cam.raw"));
    try std.testing.expectError(error.NotAPipe, win.fullName(&buf, "dir/cam"));
    try std.testing.expectError(error.NotAPipe, win.fullName(&buf, ""));
    try std.testing.expectError(error.NotAPipe, win.fullName(&buf, "\\\\.\\pipe\\"));
}

test "a name longer than the buffer is refused" {
    var buf: [12]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, win.fullName(&buf, "a_long_pipe_name"));
}
