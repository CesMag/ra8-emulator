//! The Windows camera privacy setting (RA8EMU-501). Settings > Privacy &
//! security > Camera keeps a consent value for the machine and for each
//! user under CapabilityAccessManager\ConsentStore\webcam. "Deny" in
//! either blocks every desktop app, so the webcam opener checks it right
//! after the user's own consent and says how to fix it, instead of failing
//! later on an opaque access error. Other hosts have no such setting and
//! the check passes.
const std = @import("std");
const builtin = @import("builtin");

/// What a consent value says. Windows writes "Allow" or "Deny"; a missing
/// key or any other value is unset, which Windows treats as allowed.
pub const Verdict = enum { allowed, denied, unset };

/// The consent key, under both HKEY_LOCAL_MACHINE and HKEY_CURRENT_USER.
pub const key = "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam";

pub const blocked_message = "webcam blocked by Windows privacy settings: turn on Settings > Privacy & security > Camera > Camera access and Let desktop apps access your camera";

pub const Error = error{PrivacyBlocked};

/// RRF_RT_REG_SZ: accept only a string value.
const rrf_rt_reg_sz: u32 = 0x0000_0002;

// Zig 0.17's std has no advapi32 bindings, so the one call is declared here.
extern "advapi32" fn RegGetValueW(
    root: std.os.windows.HKEY,
    sub_key: ?[*:0]const u16,
    value: ?[*:0]const u16,
    flags: u32,
    kind: ?*u32,
    data: ?*anyopaque,
    size: ?*u32,
) callconv(.winapi) i32;

pub fn parse(value: []const u8) Verdict {
    if (std.mem.eql(u8, value, "Allow")) return .allowed;
    if (std.mem.eql(u8, value, "Deny")) return .denied;
    return .unset;
}

/// A REG_SZ value as Windows hands it back: UTF-16, maybe ending in NUL.
/// Anything outside ASCII cannot be "Allow" or "Deny", so it is unset.
pub fn parseWide(units: []const u16) Verdict {
    var ascii: [8]u8 = undefined;
    var len: usize = 0;
    for (units) |unit| {
        if (unit == 0) break;
        if (unit > 0x7f or len == ascii.len) return .unset;
        ascii[len] = @intCast(unit);
        len += 1;
    }
    return parse(ascii[0..len]);
}

/// The machine and user values together: either one denying blocks it.
pub fn combine(machine: Verdict, user: Verdict) Verdict {
    if (machine == .denied or user == .denied) return .denied;
    if (machine == .allowed or user == .allowed) return .allowed;
    return .unset;
}

/// Refuses, with the fix on `writer`, when `verdict` blocks the camera.
pub fn gate(verdict: Verdict, writer: anytype) Error!void {
    if (verdict != .denied) return;
    writer.print("{s}\n", .{blocked_message}) catch {};
    return error.PrivacyBlocked;
}

/// This host's setting; always unset off Windows.
pub fn host() Verdict {
    if (builtin.os.tag != .windows) return .unset;
    const windows = std.os.windows;
    return combine(read(windows.HKEY_LOCAL_MACHINE), read(windows.HKEY_CURRENT_USER));
}

fn read(root: std.os.windows.HKEY) Verdict {
    const windows = std.os.windows;
    const sub = std.unicode.utf8ToUtf16LeStringLiteral(key);
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Value");
    var units: [16]u16 = undefined;
    var size: windows.DWORD = @sizeOf(@TypeOf(units));
    const status = RegGetValueW(root, sub, name, rrf_rt_reg_sz, null, &units, &size);
    if (status != 0) return .unset;
    return parseWide(units[0 .. size / 2]);
}
