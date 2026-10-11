//! The shell's status bar model (RA8EMU-752): the session link, the loaded
//! image and the run state, read as one line of text. Actions go through the
//! session; the model changes only on what the session sends back.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const session_link = @import("../session_link.zig");
const Link = session_link.Link;
const Arrival = session_link.Arrival;
const Env = proto.Client.Env;

/// An image the user picked: its file name and the start of its SHA-256.
pub const Image = struct {
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    hash: [8]u8 = undefined,

    pub fn of(path: []const u8, bytes: []const u8) Image {
        var image: Image = .{};
        const base = std.fs.path.basename(path);
        image.name_len = @min(base.len, image.name_buf.len);
        @memcpy(image.name_buf[0..image.name_len], base[0..image.name_len]);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        image.hash = digest[0..8].*;
        return image;
    }

    pub fn name(self: *const Image) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const Run = union(enum) {
    unknown,
    running,
    /// Stopped at `address`; `reason` is null when the stop came from a load
    /// or from pausing a run the shell kept going in slices.
    halted: struct { address: u32, reason: ?proto.StopReason },
};

/// What the session refused, for the status bar's last field.
pub const Refusal = enum {
    load,
    run,

    pub fn message(self: Refusal) []const u8 {
        return switch (self) {
            .load => "the session refused the image",
            .run => "the session refused to run",
        };
    }
};

pub const Status = struct {
    core: proto.Core = .cpu0,
    image: ?Image = null,
    run: Run = .unknown,
    refused: ?Refusal = null,
    staged: Image = .{},
    load_id: ?u32 = null,
    pc_id: ?u32 = null,
    run_id: ?u32 = null,
    /// The window's render segment, set once the backend opened (RA8EMU-226).
    render: ?[]const u8 = null,

    /// Load `bytes` (read from `path`) on this core, then read where it halted.
    pub fn load(self: *Status, link: *Link, path: []const u8, bytes: []const u8) !void {
        _ = try link.send(proto.Subscription, .subscribe, .{ .core = self.core, .topic = .stop });
        self.load_id = try link.send(proto.Load, .load, .{ .core = self.core, .image = bytes });
        self.staged = Image.of(path, bytes);
    }

    /// Run, continue or step; the stop event brings the halt back.
    pub fn go(self: *Status, link: *Link, mode: proto.RunMode, budget: u64) !void {
        self.run_id = try link.send(proto.Run, .run, .{ .core = self.core, .mode = mode, .budget = budget });
        self.run = .running;
    }

    /// Run is lit: the shell keeps the core going in slices (shell_run.zig),
    /// so no one request stands for the run.
    pub fn running(self: *Status) void {
        self.run = .running;
        self.refused = null;
    }

    /// Where a run kept going in slices was left when it was paused. A stop
    /// with a reason of its own arrives as a stop event instead.
    pub fn haltedAt(self: *Status, address: u32) void {
        self.run = .{ .halted = .{ .address = address, .reason = null } };
    }

    /// Fold one arrival from the link into the model.
    pub fn observe(self: *Status, link: *Link, arrival: Arrival) void {
        switch (arrival) {
            .event => |event| self.stopped(event),
            .response => |response| self.answered(link, response.id, response.result),
        }
    }

    fn stopped(self: *Status, event: Env.Event) void {
        if (event.topic != @backingInt(proto.Topic.stop)) return;
        const stop = proto.decode(proto.Stopped, event.payload) catch return;
        if (stop.core != self.core) return;
        self.run = .{ .halted = .{ .address = stop.address, .reason = stop.reason } };
    }

    fn answered(self: *Status, link: *Link, id: u32, result: Env.Result) void {
        if (id == self.load_id) {
            self.load_id = null;
            if (result == .err) return self.refuse(.load);
            self.image = self.staged;
            self.refused = null;
            self.pc_id = link.send(proto.ReadRegister, .read_register, .{ .core = self.core, .register = .pc }) catch null;
        } else if (id == self.pc_id) {
            self.pc_id = null;
            if (result == .err) return;
            const pc = proto.decode(proto.U32, result.ok) catch return;
            self.run = .{ .halted = .{ .address = pc.value, .reason = null } };
        } else if (id == self.run_id) {
            self.run_id = null;
            if (result == .err) {
                self.run = .unknown;
                self.refuse(.run);
            }
        }
    }

    fn refuse(self: *Status, what: Refusal) void {
        self.refused = what;
    }

    /// The status line: connection | image | run state [| refusal].
    pub fn text(self: *const Status, state: session_link.State, buf: []u8) ![]const u8 {
        var stream: std.Io.Writer = .fixed(buf);
        const out = &stream;
        switch (state) {
            .connecting => try out.writeAll("connecting"),
            .connected => |up| try out.print("connected (protocol v{d})", .{up.version}),
            .failed => |failure| try out.print("failed: {s}", .{failure.message()}),
            .closed => try out.writeAll("closed"),
        }
        if (self.image) |*image| {
            try out.print(" | {s} {x}", .{ image.name(), image.hash[0..] });
        } else try out.writeAll(" | no image");
        switch (self.run) {
            .unknown => {},
            .running => try out.writeAll(" | running"),
            .halted => |halt| {
                try out.print(" | halted at 0x{X:0>8}", .{halt.address});
                if (halt.reason) |why| try out.print(" ({s})", .{@tagName(why)});
            },
        }
        if (self.refused) |what| try out.print(" | {s}", .{what.message()});
        if (self.render) |what| try out.print(" | {s}", .{what});
        return stream.buffered();
    }
};
