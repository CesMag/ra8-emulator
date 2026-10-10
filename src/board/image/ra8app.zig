//! The emulator's reader for the `.ra8app` module container (RA8EMU-54).
//!
//! A ThreadX module reaches the board as a `.ra8app` file: a fixed header
//! (eight little-endian words, a 32-byte app id, a 32-byte display name, a
//! 64-byte Ed25519 signature) followed by the module's code and data. The
//! format is ra8-firmware's (libs/ra8_app/inc/ra8_appimg.h, revision 1), and
//! this file mirrors its admission rules word for word so the emulator refuses
//! exactly what the firmware's loader refuses. It reads the words
//! little-endian explicitly rather than overlaying a struct, so the answer
//! does not depend on the host. It does not check the signature: that is the
//! firmware's verifier, running inside the emulated board.
const std = @import("std");
const module_place = @import("ra8_chip").core.module_place;

pub const magic: u32 = 0x52413841; // "RA8A"
pub const version: u32 = 1;
pub const api_version_current: u32 = 1;
pub const segment_max: u32 = 0x0010_0000;
pub const stack_min: u32 = 0x0000_0400;

pub const app_id_width = 32;
pub const name_width = 32;
pub const signature_width = 64;
pub const words = 8;
pub const header_len = words * 4 + app_id_width + name_width + signature_width;
/// Where the signature starts, which is where the signed prefix ends.
pub const signature_offset = words * 4 + app_id_width + name_width;

pub const Capability = struct {
    pub const display: u32 = 0x1;
    pub const storage: u32 = 0x2;
    pub const network: u32 = 0x4;
    pub const known: u32 = 0x7;
};

pub const Error = error{
    /// Magic, revision, capability bits or a text field is malformed.
    Validation,
    /// The app needs a newer API generation than the firmware publishes.
    Unsupported,
    /// A declared size or the entry offset is outside its range.
    OutOfRange,
    /// Shorter than the header, or than the payload the header declares.
    ShortImage,
};

pub const Header = struct {
    entry_offset: u32,
    code_size: u32,
    data_size: u32,
    stack_size: u32,
    min_api_version: u32,
    capabilities: u32,
    app_id: [app_id_width]u8,
    display_name: [name_width]u8,

    /// The app id up to its NUL.
    pub fn id(self: *const Header) []const u8 {
        return text(&self.app_id);
    }

    /// The display name up to its NUL.
    pub fn name(self: *const Header) []const u8 {
        return text(&self.display_name);
    }

    /// Header plus the code and data it declares.
    pub fn imageLen(self: Header) usize {
        return header_len + @as(usize, self.code_size) + @as(usize, self.data_size);
    }
};

fn text(field: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    return field[0..end];
}

fn word(bytes: []const u8, index: usize) u32 {
    return std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
}

/// Read and prove a header from the head of a file image. On any refusal
/// there is no header to hold.
pub fn parse(bytes: []const u8) Error!Header {
    if (bytes.len < header_len) return Error.ShortImage;
    if (word(bytes, 0) != magic) return Error.Validation;
    if (word(bytes, 1) != version) return Error.Validation;
    var header: Header = .{
        .entry_offset = word(bytes, 2),
        .code_size = word(bytes, 3),
        .data_size = word(bytes, 4),
        .stack_size = word(bytes, 5),
        .min_api_version = word(bytes, 6),
        .capabilities = word(bytes, 7),
        .app_id = undefined,
        .display_name = undefined,
    };
    @memcpy(&header.app_id, bytes[words * 4 ..][0..app_id_width]);
    @memcpy(&header.display_name, bytes[words * 4 + app_id_width ..][0..name_width]);
    try checkIdentity(header);
    try checkSizes(header, bytes.len);
    return header;
}

fn checkIdentity(header: Header) Error!void {
    if ((header.capabilities & ~Capability.known) != 0) return Error.Validation;
    if (std.mem.indexOfScalar(u8, &header.app_id, 0) == null) return Error.Validation;
    if (std.mem.indexOfScalar(u8, &header.display_name, 0) == null) return Error.Validation;
    if (header.app_id[0] == 0) return Error.Validation;
    if (header.min_api_version > api_version_current) return Error.Unsupported;
}

fn checkSizes(header: Header, len: usize) Error!void {
    if (header.code_size == 0 or header.code_size > segment_max) return Error.OutOfRange;
    if (header.data_size > segment_max) return Error.OutOfRange;
    if (header.stack_size < stack_min or header.stack_size > segment_max) return Error.OutOfRange;
    if (header.entry_offset >= header.code_size) return Error.OutOfRange;
    if (len < header.imageLen()) return Error.ShortImage;
}

/// The module's code, right after the header.
pub fn code(header: Header, bytes: []const u8) []const u8 {
    return bytes[header_len..][0..header.code_size];
}

/// The module's initialised data, right after its code.
pub fn data(header: Header, bytes: []const u8) []const u8 {
    return bytes[header_len + header.code_size ..][0..header.data_size];
}

/// The module as the chip places it (src/chip/core/module_place.zig).
pub fn module(header: Header, bytes: []const u8) module_place.Module {
    return .{ .code = code(header, bytes), .data = data(header, bytes), .entry_offset = header.entry_offset };
}
