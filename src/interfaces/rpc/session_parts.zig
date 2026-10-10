//! The plug, unplug and fault handlers (RA8EMU-749): the Session's plug
//! hook (RA8EMU-212) and fault hook (RA8EMU-520) over the wire.
//!
//! Each request carries the part spec as text in the CLI's own syntax and
//! the server parses it with the same parsers `--attach` and `--fault`
//! use, so the two syntaxes cannot drift. A spec that does not parse is
//! `bad_args`; one the board cannot honour is `refused`. list_parts
//! (RA8EMU-791) answers in the same syntax plug takes.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("session_rpc.zig");
const handlers = @import("session_handlers.zig");
const endpoint = @import("ra8_components").endpoint;
const request = @import("ra8_components").request;
const fault_spec = @import("ra8_components").fault_spec;

const Context = handlers.Context;
const Ack = rpc.Outcome(proto.Ack);
const ack: Ack = .{ .ok = .{ .accepted = 1 } };

fn core(of: proto.Core) @import("ra8_session").api.Core {
    return @fromBackingInt(@intCast(@backingInt(of)));
}

fn refused(err: anyerror) Ack {
    std.debug.print("serve: {s}\n", .{@errorName(err)});
    if (err == error.CoreNotAttached) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.no_core)) };
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}

/// `MODEL@ENDPOINT`: a fresh part of that model on that endpoint.
pub fn plug(context: *Context, args: proto.PartSpec) Ack {
    const wanted = request.parse(args.text) catch return .{ .err = .bad_args };
    context.session.plug(core(args.core), wanted.at, wanted.name) catch |err| return refused(err);
    return ack;
}

/// `ENDPOINT`: take whatever sits there off it.
pub fn unplug(context: *Context, args: proto.PartSpec) Ack {
    const at = endpoint.parse(args.text) catch return .{ .err = .bad_args };
    context.session.unplug(core(args.core), at) catch |err| return refused(err);
    return ack;
}

/// `MODEL@ENDPOINT=MODE` or `@ENDPOINT=MODE`: the part there misbehaves
/// that way from now on, mid-run included.
pub fn setFault(context: *Context, args: proto.PartSpec) Ack {
    const wanted = fault_spec.parse(args.text) catch return .{ .err = .bad_args };
    context.session.setFault(core(args.core), wanted.target.at, wanted.mode) catch |err| return refused(err);
    return ack;
}

/// `ENDPOINT`: the part there behaves like the part again.
pub fn clearFault(context: *Context, args: proto.PartSpec) Ack {
    const at = endpoint.parse(args.text) catch return .{ .err = .bad_args };
    context.session.clearFault(core(args.core), at) catch |err| return refused(err);
    return ack;
}

/// The fitted parts, one `MODEL@ENDPOINT` line each.
pub fn listParts(context: *Context, _: proto.CoreOnly) rpc.Outcome(proto.PartList) {
    const listing = context.listing orelse return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
    const room = @min(context.scratch.len, proto.PartList.max_len.text);
    const text = listing.listFn(listing.context, context.scratch[0..room]) catch |err| {
        if (err == error.NoSpaceLeft) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.too_long)) };
        std.debug.print("serve: {s}\n", .{@errorName(err)});
        return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
    };
    return .{ .ok = .{ .text = text } };
}
