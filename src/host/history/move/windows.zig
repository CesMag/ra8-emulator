//! Windows primitives for the shared native move peer driver (peer.zig):
//! pinned NT opens, a no-replace rename through the same pins, the process
//! identity the two replies of one exchange are matched by, and the immediate
//! watchdog exit.
const std = @import("std");
const w = std.os.windows;
const wire = @import("wire.zig");
const metadata = @import("../metadata.zig");
const layout = @import("../layout.zig");

extern "kernel32" fn GetProcessTimes(w.HANDLE, *w.FILETIME, *w.FILETIME, *w.FILETIME, *w.FILETIME) callconv(.winapi) w.BOOL;
extern "kernel32" fn MoveFileExW([*:0]const u16, [*:0]const u16, u32) callconv(.winapi) w.BOOL;
pub const flags = struct {
    pub const write_through: u32 = 0x8;
};

/// Same-directory no-replace publication with MOVEFILE_WRITE_THROUGH.
/// Microsoft documents completion on disk before return. No copy fallback or
/// replacement is permitted. The caller holds the lifecycle namespace gate.
pub fn publish(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, from: []const u8, to: []const u8) !void {
    _ = try @import("../name.zig").component(from);
    _ = try @import("../name.zig").component(to);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = buffer[0..try dir.realPath(io, &buffer)];
    const source = try fullPath(allocator, base, from);
    defer allocator.free(source);
    const target = try fullPath(allocator, base, to);
    defer allocator.free(target);
    if (MoveFileExW(source, target, flags.write_through).toBool()) return;
    return switch (w.GetLastError()) {
        .FILE_EXISTS, .ALREADY_EXISTS => error.PathAlreadyExists,
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
        .DISK_FULL, .HANDLE_DISK_FULL => error.NoSpaceLeft,
        .NOT_SAME_DEVICE => error.CrossDevice,
        .ACCESS_DENIED => error.AccessDenied,
        .SHARING_VIOLATION => error.FileBusy,
        .WRITE_PROTECT => error.ReadOnlyFileSystem,
        else => error.Unexpected,
    };
}

fn fullPath(allocator: std.mem.Allocator, base: []const u8, leaf: []const u8) ![:0]u16 {
    const extended = std.mem.startsWith(u8, base, "\\\\?\\");
    const unc = !extended and std.mem.startsWith(u8, base, "\\\\");
    const prefix = if (extended) "" else if (unc) "\\\\?\\UNC\\" else "\\\\?\\";
    const path = try std.fmt.allocPrint(allocator, "{s}{s}\\{s}", .{ prefix, if (unc) base[2..] else base, leaf });
    defer allocator.free(path);
    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
}

pub fn leafPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return wire.windowsPath(allocator, path);
}

pub fn selfPid() u32 {
    return w.GetCurrentProcessId();
}

/// End the whole process from the watchdog without running anything that
/// could wait on a stalled thread.
pub fn terminate(code: u8) noreturn {
    _ = w.ntdll.NtTerminateProcess(w.GetCurrentProcess(), @fromBackingInt(@intCast(code)));
    std.process.exit(code);
}

/// The creation time of this process, reported beside its PID so the two
/// replies of one exchange can be matched. Never a signalling authority.
pub fn birth(io: std.Io) !u64 {
    _ = io;
    var created: w.FILETIME = undefined;
    var exited: w.FILETIME = undefined;
    var kernel: w.FILETIME = undefined;
    var user: w.FILETIME = undefined;
    if (!GetProcessTimes(w.GetCurrentProcess(), &created, &exited, &kernel, &user).toBool()) return error.ProcessIdentityUnavailable;
    const value = (@as(u64, created.dwHighDateTime) << 32) | created.dwLowDateTime;
    if (value == 0) return error.ProcessIdentityUnavailable;
    return value;
}

pub fn pinRoot(allocator: std.mem.Allocator, io: std.Io, root: wire.Root) !std.Io.Dir {
    if (root.path.len < 3 or !std.ascii.isAlphabetic(root.path[0]) or root.path[1] != ':' or root.path[2] != '\\') return error.UnsupportedRoot;
    if (!std.mem.eql(u8, root.marker, layout.root.marker_text) and !std.mem.eql(u8, root.marker, layout.root.kept_marker_text)) return error.Unmarked;
    const path = try std.fmt.allocPrint(allocator, "\\??\\{s}", .{root.path});
    defer allocator.free(path);
    var result = try pin(allocator, io, null, path, false);
    errdefer result.close(io);
    try metadata.expect(io, result, layout.root.marker, root.marker);
    return result;
}

pub fn pin(allocator: std.mem.Allocator, io: std.Io, root: ?std.Io.Dir, path: []const u8, deleting: bool) !std.Io.Dir {
    const utf16 = try std.unicode.wtf8ToWtf16LeAlloc(allocator, path);
    defer allocator.free(utf16);
    var unicode = w.UNICODE_STRING.init(utf16);
    const attributes: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = if (root) |dir| dir.handle else null, .ObjectName = &unicode, .Attributes = .{ .DONT_REPARSE = true } };
    var handle: w.HANDLE = undefined;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtCreateFile(&handle, .{ .SPECIFIC = .{ .FILE_DIRECTORY = .{ .LIST = true, .READ_ATTRIBUTES = true, .TRAVERSE = true } }, .STANDARD = .{ .RIGHTS = .{ .DELETE = deleting }, .SYNCHRONIZE = true } }, &attributes, &iosb, null, .{ .NORMAL = true }, .{ .READ = true, .WRITE = true }, .OPEN, .{ .DIRECTORY_FILE = true, .OPEN_REPARSE_POINT = true, .IO = .SYNCHRONOUS_NONALERT }, null, 0);
    if (status != .SUCCESS) return error.NativePinFailed;
    var result: std.Io.Dir = .{ .handle = handle };
    errdefer result.close(io);
    if ((try result.stat(io)).kind != .directory) return error.OutsideRoot;
    return result;
}

/// The rename the request commits: the pinned source entry into the target
/// root under `leaf`, refused rather than replacing whatever is already
/// there.
pub fn rename(allocator: std.mem.Allocator, child: std.Io.Dir, parent: std.Io.Dir, from: []const u8, target: std.Io.Dir, leaf: []const u8) !wire.Status {
    // NT renames the object through its own handle: the pinned child is the
    // authority, and a reopen by name inside the window would race it.
    _ = parent;
    _ = from;
    const utf16 = try std.unicode.wtf8ToWtf16LeAlloc(allocator, leaf);
    defer allocator.free(utf16);
    var information: w.FILE.RENAME_INFORMATION = .init(.{ .Flags = .{}, .RootDirectory = target.handle, .FileName = utf16 });
    const bytes = information.toBuffer();
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtSetInformationFile(child.handle, &iosb, bytes.ptr, @intCast(bytes.len), .RenameEx);
    return switch (status) {
        .SUCCESS => .success,
        .OBJECT_NAME_COLLISION, .DIRECTORY_NOT_EMPTY => .collision,
        .NOT_SAME_DEVICE => .cross_device,
        else => .refused,
    };
}
