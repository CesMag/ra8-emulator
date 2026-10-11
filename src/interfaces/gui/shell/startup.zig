//! What ra8_gui asks the session for once the image is loaded
//! (RA8EMU-1095): one plug per `--attach`, and the Click module's IMU and
//! gauge for `--click`.
//! Each goes out as the plug the plug picker sends on Enter, one at a time.
//! A refusal says so on stderr and the rest still go.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const session_link = @import("../session_link.zig");
const request = @import("ra8_components").request;
const parts = @import("ra8_components").parts;

/// The `--attach` asks plus the two `--click` parts.
pub const max_plugs: usize = request.max + 2;

/// Where `--click` puts the module's parts (src/board/i2c.zig).
pub const click_plugs = [_][]const u8{
    parts.imu_name ++ "@i2c:touch@0x6B",
    parts.gauge_name ++ "@i2c:touch@0x36",
};

pub const Error = error{TooManyPlugs} || request.Error;

pub const Startup = struct {
    plugs: [max_plugs][]const u8 = undefined,
    count: usize = 0,
    /// The next queued plug to send.
    next: usize = 0,
    /// The plug ask in flight.
    asking: ?u32 = null,
    refused: usize = 0,

    /// Queue one `MODEL@ENDPOINT` ask. A model or endpoint the catalog
    /// refuses fails here, before the window opens.
    pub fn add(self: *Startup, text: []const u8) Error!void {
        _ = try request.parse(text);
        if (self.count == max_plugs) return error.TooManyPlugs;
        self.plugs[self.count] = text;
        self.count += 1;
    }

    /// Queue the Click module's two parts.
    pub fn addClick(self: *Startup) Error!void {
        for (click_plugs) |text| try self.add(text);
    }

    /// Whether a plug is still queued or waiting on its answer.
    pub fn pending(self: Startup) bool {
        return self.next < self.count or self.asking != null;
    }

    /// Send the next queued plug while connected and none is in flight.
    pub fn attach(self: *Startup, link: *session_link.Link) void {
        if (link.state != .connected or self.asking != null or self.next == self.count) return;
        const text = self.plugs[self.next];
        self.asking = link.send(proto.PartSpec, .plug, .{ .core = .cpu0, .text = text }) catch return;
        self.next += 1;
    }

    /// Take the answer to our plug. Returns true when it was ours, so the
    /// device list can be asked for again.
    pub fn observe(self: *Startup, arrival: session_link.Arrival) bool {
        const response = switch (arrival) {
            .response => |response| response,
            .event => return false,
        };
        if (self.asking == null or self.asking != response.id) return false;
        self.asking = null;
        if (response.result == .err) {
            self.refused += 1;
            std.debug.print("the session would not plug {s}\n", .{self.plugs[self.next - 1]});
        }
        return true;
    }
};
