//! One `--attach NAME@ENDPOINT` ask: which catalog model, and where.
//!
//! The split is at the first '@', because an I2C endpoint carries an '@' of
//! its own: `max17048@i2c:touch@0x37` is the model `max17048` at
//! `i2c:touch@0x37`. A name the catalog does not know is refused here, so a
//! typo fails before the run starts rather than after the board is built.
const std = @import("std");
const endpoint = @import("endpoint.zig");
const parts = @import("parts.zig");
const fault_spec = @import("fault/spec.zig");
const eink_wire = @import("eink_it8951/wire.zig");

/// How many extra models one run may attach: the RIIC registry's own
/// depth per line (riic_bus.max_devices).
pub const max: usize = 4;

pub const Request = struct {
    name: []const u8,
    at: endpoint.Endpoint,
    /// What `--fault` asked this part to do wrong; null runs it clean.
    fault: ?fault_spec.Mode = null,
    /// `eink:WxH@...`: the panel geometry; null keeps the 1072x1448 default.
    geometry: ?eink_wire.Geometry = null,
};

pub const Error = error{ NoModelName, UnknownModel, NoSizeOption, BadGeometry } || endpoint.Error;

pub fn parse(text: []const u8) Error!Request {
    const split = std.mem.indexOfScalar(u8, text, '@') orelse return Error.Malformed;
    if (split == 0) return Error.NoModelName;
    const colon = std.mem.indexOfScalar(u8, text[0..split], ':') orelse split;
    const name = text[0..colon];
    if (name.len == 0) return Error.NoModelName;
    if (parts.all.find(name) == null) return Error.UnknownModel;
    const geometry = if (colon == split) null else try sized(name, text[colon + 1 .. split]);
    return .{ .name = name, .at = try endpoint.parse(text[split + 1 ..]), .geometry = geometry };
}

/// Only the e-paper panel takes a size: `eink:1872x1404@spi:spi0@ssl0`.
fn sized(name: []const u8, text: []const u8) Error!eink_wire.Geometry {
    if (!std.mem.eql(u8, name, parts.panel_name)) return Error.NoSizeOption;
    return eink_wire.Geometry.parse(text);
}
