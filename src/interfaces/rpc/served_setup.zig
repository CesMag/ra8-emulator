//! The session server's state for one opened image (RA8EMU-1093): the
//! harness, the reply scratch, the frame buffers and the served Context with
//! list_parts, map, stack and rtc filled in. `ra8_emulator serve` answers on
//! it over a pipe or a socket; an application can answer on it in-process.
//! set_camera_source is answered here too (RA8EMU-1114): the source is
//! opened from the host, which this adapter may reach, and handed to the
//! session to install, so neither application carries a copy of that.
const std = @import("std");
const harness = @import("ra8_session").harness;
const cpu1_bringup = @import("ra8_session").cpu1_bringup;
const board_camera = @import("ra8_session").board_camera;
const board_rtc = @import("ra8_session").board_rtc;
const session_plug = @import("ra8_session").board_plug;
const session_api = @import("ra8_session").api;
const region_map = @import("ra8_session").region_map;
const symbols = @import("ra8_session").symbols;
const region_map_json = @import("ra8_session").region_map_json;
const region_map_text = @import("ra8_session").region_map_text;
const periph_list = @import("ra8_session").periph_list;
const stack_samples = @import("ra8_session").stack_samples;
const stack_profile = @import("ra8_session").stack_profile;
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
    /// CPU0's sampled call stacks, once sampleStacks asked (RA8EMU-833).
    stacks: ?*harness.stacks.Stacks = null,
    /// CPU1, once openSecond brought it up (RA8EMU-1147).
    second: ?*cpu1_bringup.Cpu1 = null,

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
        self.context.mapping = .{ .context = &self.owner, .mapFn = mapImage, .stackFn = stackOf, .imageFn = imageOf };
        self.context.clock = board_rtc.clock(self.owner.board());
        self.context.peripherals = .{ .context = &self.owner, .listFn = listPeriph };
        self.context.camera = .{ .context = self, .setFn = setCamera };
    }

    /// Sample CPU0's call stacks every `every` instructions and answer
    /// `folded` from them (RA8EMU-833). Call once, after open.
    pub fn sampleStacks(self: *Served, every: u32) !void {
        const stacks = try self.gpa.create(harness.stacks.Stacks);
        stacks.* = .{ .every = @max(every, 1) };
        self.stacks = stacks;
        self.owner.sampleStacks(stacks);
        if (self.second) |cpu1| stacks.watch(1, cpu1.cpu(), &cpu1.image.?, &self.owner.board().time.base, null);
        self.context.folding = .{ .context = self, .foldFn = foldStacks };
    }

    /// Bring CPU1 up from the ELF at `path`, parked until a request runs
    /// it (RA8EMU-1147). Call once, after open and before sampleStacks.
    pub fn openSecond(self: *Served, path: []const u8) !void {
        const cpu1 = try self.gpa.create(cpu1_bringup.Cpu1);
        errdefer self.gpa.destroy(cpu1);
        cpu1.* = .{};
        try cpu1.open(self.gpa, self.io, &self.owner, path);
        self.second = cpu1;
    }

    pub fn deinit(self: *Served) void {
        if (self.stacks) |stacks| {
            self.owner.unsampleStacks(stacks);
            if (self.second) |cpu1| stacks.unwatch(1, cpu1.cpu());
            self.gpa.destroy(stacks);
        }
        if (self.second) |cpu1| {
            cpu1.close(self.gpa);
            self.gpa.destroy(cpu1);
        }
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

/// The blocks on the board's bus, or one block's registers (RA8EMU-818).
/// Both cores share the one peripheral bus.
fn listPeriph(context: *anyopaque, core: usize, block: []const u8, json: bool, out: []u8) anyerror![]const u8 {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    return periph_list.list(&owner.board().bus, core, block, json, out);
}

/// A core's sampled stacks over [from_ns, to_ns), named by the image they
/// were walked with; a window, thread or core that took none is refused.
fn foldStacks(context: *anyopaque, core: usize, thread: ?u32, from_ns: u64, to_ns: u64, out: []u8) anyerror![]const u8 {
    const self: *Served = @ptrCast(@alignCast(context));
    const stacks = self.stacks orelse return error.NothingSampled;
    const image = if (core == 0) self.owner.image() else (self.second orelse return error.NothingSampled).image.?;
    var w: std.Io.Writer = .fixed(out);
    var scratch: [stack_samples.limits.samples]usize = undefined;
    const filter: stack_samples.Filter = .{ .core = @intCast(core), .from_ns = from_ns, .to_ns = to_ns, .thread = thread };
    try stack_samples.fold(&stacks.store, filter, stack_profile.names(&image), &w, &scratch);
    if (w.end == 0) return error.NothingSampled;
    return w.buffered();
}

/// The main stack reservation of a core's last loaded image, if it names one.
fn stackOf(context: *anyopaque, core: usize) ?region_map.Stack {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    const which: session_api.Core = if (core == 0) .cpu0 else .cpu1;
    const image = owner.loadedImage(which) orelse return null;
    return region_map.stackOf(image, &region_map.ek_ra8d2);
}

/// A core's last loaded image, for the backtrace's names and lines.
fn imageOf(context: *anyopaque, core: usize) ?symbols.Image {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    return owner.loadedImage(if (core == 0) .cpu0 else .cpu1);
}
