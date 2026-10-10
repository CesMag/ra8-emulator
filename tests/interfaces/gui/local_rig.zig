//! An in-process session of a fixture image with a greeted link, for the
//! tests of the shell's run (shell_run_test.zig, shell_time_test.zig).
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const proto = ra8.rpc.session_rpc;
const Env = proto.Client.Env;
const Status = gui_app.status_bar.Status;

pub const Rig = struct {
    session: gui_app.local_session.LocalSession,
    rx: []u8,
    tx: []u8,
    link: gui_app.session_link.Link,

    /// Opens in place: the link points into `self`, so it must not move.
    pub fn open(self: *Rig, image: []const u8) !void {
        const gpa = std.testing.allocator;
        try self.session.open(gpa, std.testing.io, image);
        errdefer self.session.deinit();
        self.rx = try gpa.alloc(u8, 2 * Env.max_frame);
        errdefer gpa.free(self.rx);
        self.tx = try gpa.alloc(u8, Env.max_frame);
        errdefer gpa.free(self.tx);
        self.link.open(self.session.transport(), self.rx, self.tx);
        try self.session.answer();
        _ = self.link.pump();
        try std.testing.expect(self.link.state == .connected);
    }

    pub fn deinit(self: *Rig) void {
        std.testing.allocator.free(self.tx);
        std.testing.allocator.free(self.rx);
        self.session.deinit();
    }

    /// Load `image` through `status` and wait for the halt at reset.
    pub fn load(self: *Rig, status: *Status, image: []const u8) !void {
        const gpa = std.testing.allocator;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, image, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try status.load(&self.link, image, bytes);
        try self.settle(status);
    }

    /// Answer and take arrivals into `status` until it shows a halt.
    pub fn settle(self: *Rig, status: *Status) !void {
        var rounds: usize = 0;
        while (rounds == 0 or status.run != .halted) : (rounds += 1) {
            if (rounds == 16) return error.NeverHalted;
            try self.session.answer();
            while (self.link.pump()) |arrival| status.observe(&self.link, arrival);
        }
    }

    /// The core's PC, read through the session.
    pub fn pc(self: *Rig, core: proto.Core) !u32 {
        const id = try self.link.send(proto.ReadRegister, .read_register, .{ .core = core, .register = .pc });
        try self.session.answer();
        while (self.link.pump()) |arrival| switch (arrival) {
            .response => |response| if (response.id == id) return (try proto.decode(proto.U32, response.result.ok)).value,
            .event => {},
        };
        return error.NoAnswer;
    }
};
