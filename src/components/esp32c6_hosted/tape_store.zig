//! Where the C6's recorded host traffic lives (RA8EMU-1020). The
//! application fills it from its host file layer with `Store.of`, so the
//! C6 model never opens a host file itself.
const std = @import("std");

/// A tape folder or one open tape, opaque to the C6.
pub const Handle = enum(usize) { _ };

pub const Store = struct {
    root: Handle,
    /// Starts tape `name`, replacing any older one of that name.
    create: *const fn (root: Handle, name: []const u8) anyerror!Handle,
    append: *const fn (file: Handle, bytes: []const u8) anyerror!void,
    close: *const fn (file: Handle) void,
    /// All of tape `name`, at most `max` bytes, owned by the caller.
    readAlloc: *const fn (root: Handle, name: []const u8, allocator: std.mem.Allocator, max: usize) anyerror![]u8,
    /// Tape `name` read into `out`.
    readInto: *const fn (root: Handle, name: []const u8, out: []u8) anyerror![]u8,
    release: *const fn (root: Handle) void,

    /// The Store over a host tape folder namespace: `Root` and `File`
    /// types and `create`, `append`, `close`, `readAlloc`, `readInto` and
    /// `release` functions over pointers to them.
    pub fn of(comptime Host: type, root: *Host.Root) Store {
        return .{
            .root = handleOf(root),
            .create = Over(Host).create,
            .append = Over(Host).append,
            .close = Over(Host).close,
            .readAlloc = Over(Host).readAlloc,
            .readInto = Over(Host).readInto,
            .release = Over(Host).release,
        };
    }
};

fn Over(comptime Host: type) type {
    return struct {
        fn create(root: Handle, name: []const u8) anyerror!Handle {
            return handleOf(try Host.create(ptrOf(Host.Root, root), name));
        }
        fn append(file: Handle, bytes: []const u8) anyerror!void {
            return Host.append(ptrOf(Host.File, file), bytes);
        }
        fn close(file: Handle) void {
            Host.close(ptrOf(Host.File, file));
        }
        fn readAlloc(root: Handle, name: []const u8, allocator: std.mem.Allocator, max: usize) anyerror![]u8 {
            return Host.readAlloc(ptrOf(Host.Root, root), name, allocator, max);
        }
        fn readInto(root: Handle, name: []const u8, out: []u8) anyerror![]u8 {
            return Host.readInto(ptrOf(Host.Root, root), name, out);
        }
        fn release(root: Handle) void {
            Host.release(ptrOf(Host.Root, root));
        }
    };
}

fn handleOf(pointer: anytype) Handle {
    return @fromBackingInt(@intFromPtr(pointer));
}

fn ptrOf(comptime T: type, handle: Handle) *T {
    return @ptrFromInt(@backingInt(handle));
}
