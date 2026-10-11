//! The shell's call stack leaf (RA8EMU-1125): one core's call chain asked
//! over the session link (backtrace 0x0120) into the stack pane's
//! (RA8EMU-744) Snapshot, so the pane draws in the shell unchanged. The
//! session walks the chain with the image's .debug_frame and names each
//! frame; the leaf only copies the answer. One ask goes out once the image
//! has loaded and after every stop of the leaf's core; a load starts over.
const std = @import("std");
const rpc = @import("ra8_rpc");
const proto = rpc.session_rpc;
const backtrace_wire = rpc.backtrace_wire;
const session_link = @import("session_link.zig");
const stack_pane = @import("ui/stack_pane.zig");
const pane_layout = @import("ui/pane_layout.zig");

const Env = proto.Client.Env;
pub const Snapshot = stack_pane.Snapshot;

comptime {
    std.debug.assert(stack_pane.max_frames == proto.backtrace_frames);
    std.debug.assert(stack_pane.name_cap == proto.frame_name_cap);
    std.debug.assert(stack_pane.file_cap == proto.frame_file_cap);
}

pub const Stack = struct {
    core: proto.Core,
    /// An ask is due on the next attach.
    want: bool = false,
    /// The id of the ask in flight.
    asked: ?u32 = null,
    now: ?Snapshot = null,
    refused: bool = false,
    /// A load landed while an ask was in flight: its answer describes the
    /// old image, so it publishes nothing and a fresh ask follows it.
    stale: bool = false,

    /// Send the due ask unless one is in flight or the session has not
    /// greeted.
    pub fn attach(self: *Stack, link: *session_link.Link) void {
        if (link.state != .connected or !self.want or self.asked != null) return;
        const args: proto.CoreOnly = .{ .core = self.core };
        self.asked = link.send(proto.CoreOnly, .backtrace, args) catch |err| switch (err) {
            error.TableFull => return,
            else => null,
        };
        self.want = false;
        if (self.asked == null) self.refused = true;
    }

    /// A stop of this core makes an ask due; the answer to the one in
    /// flight becomes the shown chain. Everything else is ignored.
    pub fn observe(self: *Stack, arrival: session_link.Arrival) void {
        switch (arrival) {
            .event => |event| self.stopped(event),
            .response => |response| self.answered(response.id, response.result),
        }
    }

    /// A new image: ask again and show nothing of the old one.
    pub fn reload(self: *Stack) void {
        self.want = true;
        self.stale = self.asked != null;
        self.now = null;
    }

    /// The leaf's note while it has no chain to draw, or null.
    pub fn note(self: *const Stack) ?[]const u8 {
        if (self.refused) return "the session would not walk the stack";
        if (self.now == null) return "waiting for the call stack";
        return null;
    }

    fn stopped(self: *Stack, event: Env.Event) void {
        if (event.topic != @backingInt(proto.Topic.stop)) return;
        const stop = proto.decode(proto.Stopped, event.payload) catch return;
        if (stop.core == self.core) self.want = true;
    }

    fn answered(self: *Stack, id: u32, result: Env.Result) void {
        if (self.asked != id) return;
        self.asked = null;
        if (self.stale) {
            self.stale = false;
            return;
        }
        const body = switch (result) {
            .ok => |bytes| bytes,
            .err => return self.refuse(),
        };
        const chain = proto.decode(proto.Backtrace, body) catch return self.refuse();
        self.now = unpack(chain) catch return self.refuse();
        self.refused = false;
    }

    /// A refused ask keeps the last chain with the note.
    fn refuse(self: *Stack) void {
        self.refused = true;
    }
};

/// The pane's snapshot of `chain`: names and files copied, so the snapshot
/// holds no slice into the link's buffer.
pub fn unpack(chain: proto.Backtrace) !Snapshot {
    var snapshot: Snapshot = .{};
    var reader: backtrace_wire.Reader = .{ .rest = chain.frames };
    while (try reader.next()) |found| {
        if (snapshot.count == stack_pane.max_frames) return error.Oversize;
        const frame = &snapshot.frames[snapshot.count];
        frame.* = .{ .pc = found.pc, .interrupted = found.interrupted != 0, .offset = found.offset, .line = found.line };
        frame.name_len = found.name.len;
        @memcpy(frame.name_buf[0..found.name.len], found.name);
        frame.file_len = found.file.len;
        @memcpy(frame.file_buf[0..found.file.len], found.file);
        snapshot.count += 1;
    }
    if (snapshot.count != chain.count) return error.Truncated;
    return snapshot;
}

/// One model per core, so each leaf shows the core it is bound to.
pub const Pair = struct {
    cores: [2]Stack = .{ .{ .core = .cpu0 }, .{ .core = .cpu1 } },

    pub fn of(self: *const Pair, core: pane_layout.Core) *const Stack {
        return &self.cores[@backingInt(core)];
    }

    pub fn attach(self: *Pair, link: *session_link.Link) void {
        for (&self.cores) |*model| model.attach(link);
    }

    pub fn observe(self: *Pair, arrival: session_link.Arrival) void {
        for (&self.cores) |*model| model.observe(arrival);
    }

    pub fn reload(self: *Pair) void {
        for (&self.cores) |*model| model.reload();
    }

    /// The cores halted with no stop event of their own, as a paused run
    /// does (shell_run.zig): walk them again.
    pub fn refresh(self: *Pair) void {
        for (&self.cores) |*model| model.want = true;
    }
};
