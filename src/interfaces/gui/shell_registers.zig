//! The shell's registers leaf (RA8EMU-821): one core's registers read over
//! the session link (read_register 0x0105) into the registers pane's
//! (RA8EMU-741) Snapshot, so the pane draws in the shell unchanged. A batch
//! of reads goes out once the image has loaded and after every stop of the
//! leaf's core. When its last answer lands, the batch becomes the shown
//! snapshot and the one it replaces the "before" the pane marks changes
//! against. A load starts over, so a fresh image marks nothing.
const std = @import("std");
const proto = @import("ra8_rpc").session_rpc;
const session_link = @import("session_link.zig");
const registers_pane = @import("ui/registers_pane.zig");
const registers_capture = @import("registers_capture.zig");
const pane_layout = @import("ui/pane_layout.zig");
const shell_frame = @import("ui/shell_frame.zig");
const draw_list = @import("ra8_render").draw_list;

const Env = proto.Client.Env;
const shown = registers_capture.shown;
pub const Register = @TypeOf(shown[0]);
pub const Snapshot = registers_pane.Snapshot;

/// The wire's name for each register the pane shows, in the pane's order.
pub const wire: [shown.len]proto.Register = blk: {
    var out: [shown.len]proto.Register = undefined;
    for (shown, 0..) |which, index| out[index] = @field(proto.Register, @tagName(which));
    break :blk out;
};

pub const Registers = struct {
    core: proto.Core,
    /// A batch is due on the next attach.
    want: bool = false,
    /// The ids of the batch in flight, one per shown register.
    asked: [shown.len]?u32 = @splat(null),
    /// Answers still missing from the batch in flight.
    left: usize = 0,
    /// Which groups this leaf shows folded to their header.
    fold: registers_pane.Fold = registers_pane.open,
    /// The next register of the open batch to send; shown.len when all are.
    next: usize = shown.len,
    gathered: Snapshot = .{},
    batch_refused: bool = false,
    now: ?Snapshot = null,
    before: ?Snapshot = null,
    refused: bool = false,
    /// A load landed while a batch was in flight: its answers describe the
    /// old image, so it publishes nothing and a fresh batch follows it.
    stale: bool = false,
    /// Counts published batches, so the memory leaf can follow each one.
    serial: u32 = 0,

    /// Send the due batch, one read per shown register (VPR only on an MVE
    /// core), unless one is
    /// already in flight or the session has not greeted.
    pub fn attach(self: *Registers, link: *session_link.Link) void {
        if (link.state != .connected) return;
        if (self.want and self.left == 0 and self.next == shown.len) {
            self.want = false;
            self.batch_refused = false;
            self.next = 0;
        }
        if (self.next == shown.len) return;
        while (self.next < shown.len) : (self.next += 1) {
            if (wire[self.next] == .vpr and !registers_pane.hasMve(self.core)) continue;
            const args: proto.ReadRegister = .{ .core = self.core, .register = wire[self.next] };
            const asked = link.send(proto.ReadRegister, .read_register, args) catch |err| switch (err) {
                error.TableFull => return,
                else => null,
            };
            self.asked[self.next] = asked;
            if (asked == null) self.batch_refused = true else self.left += 1;
        }
        if (self.left == 0) self.finish();
    }

    /// A stop of this core makes a batch due; an answer to the batch in
    /// flight fills its register. Everything else is ignored.
    pub fn observe(self: *Registers, arrival: session_link.Arrival) void {
        switch (arrival) {
            .event => |event| self.stopped(event),
            .response => |response| self.answered(response.id, response.result),
        }
    }

    /// Fold or unfold the group whose header holds (`x`, `y`) in a leaf
    /// drawn in `body`. Returns whether a header was hit.
    pub fn toggle(self: *Registers, body: draw_list.Rect, x: i32, y: i32) bool {
        if (self.now == null) return false;
        const which = registers_pane.headerAt(body, self.fold, self.now.?.mve, x, y) orelse return false;
        self.fold[which] = !self.fold[which];
        return true;
    }

    /// A new image: read again and mark nothing against the old one.
    pub fn reload(self: *Registers) void {
        self.want = true;
        self.next = shown.len;
        self.stale = self.left != 0;
        self.now = null;
        self.before = null;
    }

    /// `which` from the shown batch, or null before one has published or
    /// when the pane does not show it.
    pub fn value(self: *const Registers, which: Register) ?u32 {
        const now = self.now orelse return null;
        const index = std.mem.indexOfScalar(Register, &shown, which) orelse return null;
        return now.values[index];
    }

    /// The leaf's note while it has no values to draw, or null.
    pub fn note(self: *const Registers) ?[]const u8 {
        if (self.refused) return "the session would not read the registers";
        if (self.now == null) return "waiting for the registers";
        return null;
    }

    fn stopped(self: *Registers, event: Env.Event) void {
        if (event.topic != @backingInt(proto.Topic.stop)) return;
        const stop = proto.decode(proto.Stopped, event.payload) catch return;
        if (stop.core == self.core) self.want = true;
    }

    fn answered(self: *Registers, id: u32, result: Env.Result) void {
        const index = self.slot(id) orelse return;
        self.asked[index] = null;
        self.left -= 1;
        switch (result) {
            .ok => |body| if (proto.decode(proto.U32, body)) |read| {
                self.gathered.values[index] = read.value;
            } else |_| {
                self.batch_refused = true;
            },
            .err => self.batch_refused = true,
        }
        if (self.left == 0 and self.next == shown.len) self.finish();
    }

    fn slot(self: *const Registers, id: u32) ?usize {
        if (self.left == 0) return null;
        for (self.asked, 0..) |asked, index| if (asked == id) return index;
        return null;
    }

    /// A whole batch publishes; a refused one keeps the last snapshot, and one
    /// sent before a load is dropped.
    fn finish(self: *Registers) void {
        if (self.stale) {
            self.stale = false;
            return;
        }
        self.refused = self.batch_refused;
        if (self.refused) return;
        self.gathered.mve = registers_pane.hasMve(self.core);
        self.before = self.now;
        self.now = self.gathered;
        self.serial +%= 1;
    }
};

/// One model per core, so each leaf shows the core it is bound to.
pub const Pair = struct {
    cores: [2]Registers = .{ .{ .core = .cpu0 }, .{ .core = .cpu1 } },

    pub fn of(self: *const Pair, core: pane_layout.Core) *const Registers {
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

    /// Route a left press at (`x`, `y`) to a registers leaf's group
    /// header. Returns whether a group folded or unfolded.
    pub fn clickIn(self: *Pair, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        for (solved.panes.items) |placed| {
            const pane = layout.pane(placed.index) orelse continue;
            if (pane.kind != .registers) continue;
            if (self.cores[@backingInt(pane.core)].toggle(shell_frame.bodyOf(placed.area), x, y)) return true;
        }
        return false;
    }
};
