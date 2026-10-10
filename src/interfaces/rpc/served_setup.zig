//! The session server's state for one opened image (RA8EMU-1093): the
//! harness, the reply scratch, the frame buffers and the served Context with
//! list_parts, map, stack and rtc filled in. `ra8_emulator serve` answers on
//! it over a pipe or a socket; an application can answer on it in-process.
//! set_camera_source is answered here too (RA8EMU-1114): the source is
//! opened from the host, which this adapter may reach, and handed to the
//! session to install, so neither application carries a copy of that.
const std = @import("std");
const harness = @import("ra8_session").harness;
const board_camera = @import("ra8_session").board_camera;
const board_rtc = @import("ra8_session").board_rtc;
const session_plug = @import("ra8_session").board_plug;
const session_api = @import("ra8_session").api;
const region_map = @import("ra8_session").region_map;
const region_map_json = @import("ra8_session").region_map_json;
const region_map_text = @import("ra8_session").region_map_text;
const source_spec = @import("ra8_host").camera.source_spec;
const source_open = @import("ra8_host").camera.source_open;
const proto = @import("session_rpc.zig");
const served = @import("session_server.zig");

pub const Served = struct {
    owner: harness.Harness,
    context: served.Context,
    /// Incoming frames (two frames long) and one outgoing frame.
    rx: []u8,
    tx: []u8,
    gpa: std.mem.Allocator,
    /// What camera sources are opened with.
    io: std.Io,

    /// Open `elf_path` and fill the context. The context points into
    /// `self`, so `self` stays put until `deinit`.
    pub fn open(self: *Served, allocator: std.mem.Allocator, io: std.Io, elf_path: []const u8) !void {
        var owner = try harness.open(allocator, io, .{ .elf_path = elf_path });
        errdefer owner.deinit();
        const Env = served.Server.Env;
        const rx = try allocator.alloc(u8, 2 * Env.max_frame);
        errdefer allocator.free(rx);
        const tx = try allocator.alloc(u8, Env.max_frame);
        errdefer allocator.free(tx);
        const scratch = try allocator.alloc(u8, proto.max_payload);
        self.* = .{ .owner = owner, .context = undefined, .rx = rx, .tx = tx, .gpa = allocator, .io = io };
        self.context = .{ .session = self.owner.session(), .scratch = scratch, .state = self.owner.stateFiles(), .gpa = allocator };
        self.context.listing = .{ .context = self.owner.plugs(), .listFn = listParts };
        self.context.mapping = .{ .context = &self.owner, .mapFn = mapImage, .stackFn = stackOf };
        self.context.clock = board_rtc.clock(self.owner.board());
        self.context.camera = .{ .context = self, .setFn = setCamera };
    }

    pub fn deinit(self: *Served) void {
        self.gpa.free(self.context.scratch);
        self.gpa.free(self.tx);
        self.gpa.free(self.rx);
        self.owner.deinit();
    }
};

/// set_camera_source: open the source `spec` names on the host and make it
/// the board's camera source. A source that will not open changes nothing.
fn setCamera(context: *anyopaque, spec: source_spec.Spec) anyerror!void {
    const self: *Served = @ptrCast(@alignCast(context));
    const input = try source_open.open(self.gpa, self.io, spec);
    try board_camera.install(self.owner.board(), self.gpa, input);
}

fn listParts(context: *anyopaque, out: []u8) anyerror![]const u8 {
    const plugs: *session_plug.Plugs = @ptrCast(@alignCast(context));
    return plugs.list(out);
}

/// The map of a core's last loaded image, as `--map` text or JSON.
fn mapImage(context: *anyopaque, core: usize, json: bool, out: []u8) anyerror![]const u8 {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    const which: session_api.Core = if (core == 0) .cpu0 else .cpu1;
    const image = owner.loadedImage(which) orelse return error.NoImage;
    var w: std.Io.Writer = .fixed(out);
    if (json) {
        try region_map_json.write(&w, image, &region_map.ek_ra8d2);
    } else {
        try region_map_text.render(&w, image, &region_map.ek_ra8d2);
    }
    return w.buffered();
}

/// The main stack reservation of a core's last loaded image, if it names one.
fn stackOf(context: *anyopaque, core: usize) ?region_map.Stack {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    const which: session_api.Core = if (core == 0) .cpu0 else .cpu1;
    const image = owner.loadedImage(which) orelse return null;
    return region_map.stackOf(image, &region_map.ek_ra8d2);
}
