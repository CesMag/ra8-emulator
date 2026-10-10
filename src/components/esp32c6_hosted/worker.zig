//! The background worker the C6 DNS bridge resolves names on (RA8EMU-1020).
//! The application fills it from its host thread layer with `Worker.of`, so
//! the C6 model never starts a host thread itself. With none, the bridge
//! resolves inline.
/// One running job, opaque to the C6.
pub const Handle = enum(usize) { _ };

pub const Worker = struct {
    /// Runs `work(arg)` in the background.
    spawn: *const fn (work: *const fn (*anyopaque) void, arg: *anyopaque) anyerror!Handle,
    /// Waits for the job to finish and frees the handle.
    join: *const fn (job: Handle) void,
    /// Lets the job finish on its own and frees the handle.
    detach: *const fn (job: Handle) void,

    /// The Worker over a host thread namespace: a `Thread` type and
    /// `spawn`, `join` and `detach` functions over a pointer to it.
    pub fn of(comptime Host: type) Worker {
        return .{ .spawn = Over(Host).spawn, .join = Over(Host).join, .detach = Over(Host).detach };
    }
};

fn Over(comptime Host: type) type {
    return struct {
        fn spawn(work: *const fn (*anyopaque) void, arg: *anyopaque) anyerror!Handle {
            return @fromBackingInt(@intFromPtr(try Host.spawn(work, arg)));
        }
        fn join(job: Handle) void {
            Host.join(threadOf(job));
        }
        fn detach(job: Handle) void {
            Host.detach(threadOf(job));
        }
        fn threadOf(job: Handle) *Host.Thread {
            return @ptrFromInt(@backingInt(job));
        }
    };
}
