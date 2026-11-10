//! Authoritative backend disassembly handler: decodes instructions forward
//! using the Zig CPU core's instruction table (including Armv8.1-M, MVE
//! Helium, PACBTI, DSP, and TrustZone) and annotates symbol entry labels.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const disasm_wire = @import("disasm_wire.zig");
const api = @import("ra8_session").api;
const session_disasm = @import("ra8_session").disasm;
const session_view = @import("ra8_session").view;
const symbols = @import("ra8_session").symbols;
const txm_debug = @import("ra8_session").txm.debug;

const Outcome = rpc.Outcome(proto.DisasmReply);

pub fn disasm(context: *handlers.Context, args: proto.DisasmAsk) Outcome {
    const which: api.Core = @fromBackingInt(@intCast(@backingInt(args.core)));
    const pc = (context.session.register(which, .pc) catch |err| return refuse(err)) & ~@as(u32, 1);
    if (context.scratch.len < disasm_wire.disasm_bytes) return refuse(error.NoRoom);

    const requested: usize = if (args.count == 0) 24 else args.count;
    const count = @min(requested, disasm_wire.disasm_max_rows);
    var address: u32 = if (args.use_pc != 0) pc else (args.address & ~@as(u32, 1));
    const image = imageOf(context, which);

    var at: usize = 0;
    var emitted: u8 = 0;
    for (0..count) |_| {
        var text_buf: [disasm_wire.disasm_text_cap]u8 = undefined;
        const row = decodeOne(context.session, which, address, image, context.modules, &text_buf) catch |err| return refuse(err);
        disasm_wire.put(context.scratch[0..disasm_wire.disasm_bytes], &at, row) catch |err| return refuse(err);
        emitted += 1;
        address +%= if (row.size == 0) session_view.encoding.narrow else row.size;
    }

    return .{ .ok = .{
        .core = args.core,
        .pc = pc,
        .count = emitted,
        .rows = context.scratch[0..at],
    } };
}

fn decodeOne(
    session: *api.Session,
    core: api.Core,
    address: u32,
    image: ?symbols.Image,
    modules: ?*const txm_debug.Table,
    text_buf: *[disasm_wire.disasm_text_cap]u8,
) !disasm_wire.DisasmRow {
    var row: disasm_wire.DisasmRow = .{
        .address = address,
        .size = 0,
        .decoded = 0,
        .symbol = symbolAt(address, image, modules),
    };
    session.read(core, address, row.raw[0..2]) catch |err| {
        if (unreadable(err)) return row;
        return err;
    };
    const first = std.mem.readInt(u16, row.raw[0..2], .little);
    const wide = first >= session_view.encoding.wide_first;
    if (wide) {
        session.read(core, address +% 2, row.raw[2..4]) catch |err| {
            if (unreadable(err)) return row;
            return err;
        };
    }
    row.size = if (wide) 4 else 2;
    const formatted = session_disasm.one(address, row.raw[0..row.size]) catch return row;
    const slice = formatted.slice();
    const len = @min(slice.len, text_buf.len);
    @memcpy(text_buf[0..len], slice[0..len]);
    row.text = text_buf[0..len];
    row.decoded = 1;
    return row;
}

fn symbolAt(address: u32, image: ?symbols.Image, modules: ?*const txm_debug.Table) []const u8 {
    if (modules) |table| {
        if (table.inside(address)) |named| {
            if (named.offset == 0) return named.name[0..@min(named.name.len, disasm_wire.disasm_sym_cap)];
        }
    }
    const loaded = image orelse return "";
    if (symbols.inside(loaded, address)) |named| {
        if (named.offset == 0) return named.name[0..@min(named.name.len, disasm_wire.disasm_sym_cap)];
    }
    return "";
}

fn imageOf(context: *handlers.Context, core: api.Core) ?symbols.Image {
    const mapping = context.mapping orelse return null;
    const imageFn = mapping.imageFn orelse return null;
    return imageFn(mapping.context, @backingInt(core));
}

fn unreadable(err: anyerror) bool {
    return err == error.Unmapped or err == error.SecurityViolation;
}

fn refuse(err: anyerror) Outcome {
    if (err == error.CoreNotAttached) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.no_core)) };
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}
