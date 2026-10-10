//! The session's plug hook for this board (RA8EMU-212): put a catalog part
//! on an endpoint mid-run, or take whatever is there off it.
//!
//! Unplugging leaves each line the way a missing part would. An I2C part
//! leaves its line's registry, so its address phase goes unacknowledged. An
//! SPI channel gets a stand-in that reads CIPO floating high (the
//! controller's own empty-channel read is left alone, which keeps recorded
//! runs identical). A UART channel goes silent. A GPIO pin goes back to its
//! pull state.
//!
//! It also keeps what sits where (RA8EMU-791): the run's `--attach` asks,
//! then each plug the session made and each unplug, so a client can list
//! the parts without reaching into a bus.
const std = @import("std");
const endpoint = @import("ra8_components").endpoint;
const catalog = @import("ra8_components").catalog;
const parts = @import("ra8_components").parts;
const fault_lines = @import("ra8_components").fault_lines;
const riic_bus = @import("ra8_chip").periph.riic.bus;
const spi = @import("ra8_chip").periph.spi;
const session_api = @import("api.zig");
const plug = @import("ra8_board").plug;
const Board = @import("ra8_board").board.Board;
const eink = @import("ra8_components").eink;

pub const Error = error{NothingFitted};

/// What an unplugged SPI select reads: nothing drives CIPO, so it floats.
pub const floating = struct {
    var unused: u8 = 0;

    fn exchange(_: *anyopaque, _: u8) u8 {
        return fault_lines.floating;
    }

    pub const device: spi.Device = .{ .context = &unused, .exchangeFn = exchange };

    pub fn holds(part: spi.Device) bool {
        return part.context == device.context;
    }
};

const max_instances = 256;
const max_fitted = max_instances + @typeInfo(@FieldType(plug.Asks, "asked")).array.len;

/// One endpoint and the catalog part on it, by name.
pub const Fitted = struct { at: endpoint.Endpoint, name: []const u8 };

pub const Plugs = struct {
    board: *Board,
    arena: std.mem.Allocator,
    panels: [spi.channel_count]?*eink.Panel = @splat(null),

    instances: [max_instances]catalog.Instance = undefined,
    instance_count: usize = 0,
    fitted: [max_fitted]Fitted = undefined,
    fitted_count: usize = 0,

    pub fn init(board: *Board, arena: std.mem.Allocator) Plugs {
        var self: Plugs = .{ .board = board, .arena = arena };
        for (board.asks.asked[0..board.asks.count]) |asked| {
            if (asked.name.len != 0) self.note(asked.at, asked.name);
        }
        if (board.asks.attached_eink) |panel| {
            for (board.asks.asked[0..board.asks.count]) |asked| {
                if (!std.mem.eql(u8, asked.name, parts.panel_name) or asked.at != .spi) continue;
                self.panels[asked.at.spi.channel] = panel;
            }
        }
        return self;
    }

    pub fn deinit(self: *Plugs) void {
        while (self.instance_count > 0) {
            self.instance_count -= 1;
            catalog.Catalog.destroy(self.arena, self.instances[self.instance_count]);
        }
    }

    pub fn hook(self: *Plugs) session_api.PlugHook {
        return .{ .context = self, .plugFn = setErased };
    }

    /// Put a fresh `name` on `at`, or take what is there off it when null.
    pub fn set(self: *Plugs, at: endpoint.Endpoint, name: ?[]const u8) !void {
        const wanted = name orelse {
            try self.unplug(at);
            return self.forget(at);
        };
        if (self.instance_count == self.instances.len) return error.TooManyInstances;
        const made = try parts.all.make(self.arena, wanted, at);
        self.instances[self.instance_count] = made;
        self.instance_count += 1;
        errdefer {
            self.instance_count -= 1;
            catalog.Catalog.destroy(self.arena, made);
        }
        if (at == .spi) {
            const unit = &self.board.spi.channels[at.spi.channel];
            if (unit.device) |part| if (floating.holds(part)) {
                unit.device = null;
            };
        }
        try plug.one(self.board, made.device, at);
        self.note(at, made.model.name);
        if (std.mem.eql(u8, wanted, parts.panel_name)) {
            const panel: *eink.Panel = @ptrCast(@alignCast(made.state));
            panel.event_hook = self.board.panel.event_hook;
            self.panels[at.spi.channel] = panel;
            self.board.asks.attached_eink = panel;
        }
    }

    /// Each fitted part as `MODEL@ENDPOINT`, one per line, in the order
    /// they went on; `error.NoSpaceLeft` when `out` cannot hold them all.
    pub fn list(self: *const Plugs, out: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(out);
        self.listTo(&w) catch return error.NoSpaceLeft;
        return w.buffered();
    }

    fn listTo(self: *const Plugs, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.fitted[0..self.fitted_count]) |part| {
            try w.print("{s}@", .{part.name});
            try part.at.write(w);
            try w.writeByte('\n');
        }
    }

    /// `name` is on `at` now, in place of whatever was.
    fn note(self: *Plugs, at: endpoint.Endpoint, name: []const u8) void {
        for (self.fitted[0..self.fitted_count]) |*part| {
            if (std.meta.eql(part.at, at)) {
                part.name = name;
                return;
            }
        }
        if (self.fitted_count == self.fitted.len) return;
        self.fitted[self.fitted_count] = .{ .at = at, .name = name };
        self.fitted_count += 1;
    }

    fn forget(self: *Plugs, at: endpoint.Endpoint) void {
        for (self.fitted[0..self.fitted_count], 0..) |part, index| {
            if (!std.meta.eql(part.at, at)) continue;
            std.mem.copyForwards(Fitted, self.fitted[index .. self.fitted_count - 1], self.fitted[index + 1 .. self.fitted_count]);
            self.fitted_count -= 1;
            return;
        }
    }

    fn setErased(context: *anyopaque, at: endpoint.Endpoint, name: ?[]const u8) anyerror!void {
        const self: *Plugs = @ptrCast(@alignCast(context));
        try self.set(at, name);
    }

    fn unplug(self: *Plugs, at: endpoint.Endpoint) Error!void {
        switch (at) {
            .i2c => |where| {
                _ = self.line(where.line).detach(where.address) orelse return Error.NothingFitted;
            },
            .spi => |where| {
                const unit = &self.board.spi.channels[where.channel];
                const part = unit.device orelse return Error.NothingFitted;
                if (floating.holds(part)) return Error.NothingFitted;
                unit.device = floating.device;
                if (self.panels[where.channel]) |removed| {
                    self.panels[where.channel] = null;
                    if (self.board.asks.attached_eink == removed) {
                        self.board.asks.attached_eink = null;
                        for (self.panels) |panel| if (panel) |remaining| {
                            self.board.asks.attached_eink = remaining;
                            break;
                        };
                    }
                }
            },
            .uart => |where| {
                const unit = &self.board.serial.channels[where.channel];
                if (unit.device == null) return Error.NothingFitted;
                unit.device = null;
            },
            .gpio => |where| {
                if (!self.board.pins.wired.detach(where.port, where.pin)) return Error.NothingFitted;
                self.board.pins.release(where.port, where.pin);
            },
        }
    }

    fn line(self: *Plugs, which: endpoint.Line) *riic_bus.Registry {
        return switch (which) {
            .riic => &self.board.wire.controller.devices,
            .touch => &self.board.wire.touchline.devices,
        };
    }
};
