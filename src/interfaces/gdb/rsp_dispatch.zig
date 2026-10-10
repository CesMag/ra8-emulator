//! What a remote-protocol packet asks of the machine, answered as the
//! payload the stub sends back (framing is rsp_packet.zig's job).
//!
//! The halt reason, what the stub supports, the target description, and
//! reads and writes of registers and memory: `g`/`G` all registers, `p`/`P`
//! one, `m`/`M` memory as hex and `X` memory as binary. With a stop
//! machine attached, `Z`/`z` set and clear breaks and watches
//! (rsp_points.zig); without one they are not supported. With a Zig
//! session attached, `c`, `s`, `vCont` and the thread requests resume and
//! select cores through it (rsp_zig.zig).
//! A request it does not know gets the empty reply, which is how the
//! protocol says "not supported" and lets gdb fall back.
const std = @import("std");
const Cortex = @import("ra8_chip").core.cpu.cortex.Cortex;
const features = @import("rsp_features.zig");
const stop_machine = @import("ra8_session").stop_machine;

pub const Error = error{NoSpace};

/// The Z and z requests, reached through here so tests see them.
pub const points = @import("rsp_points.zig");
/// Debugger stores handed on to the debug unit models.
pub const units = @import("rsp_units.zig");
/// Run control on the Zig core (RA8EMU-118).
pub const zig_run = @import("rsp_zig.zig");
/// One connection served end to end.
pub const server = @import("rsp_server.zig");
pub const poll = @import("rsp_poll.zig");
/// ITM text sent to gdb as `O` packets.
pub const console = @import("rsp_console.zig");
const core_view = @import("ra8_session").core_view;

/// The `g` order, which is target.xml's order: r0 to r12, sp, lr, pc, xpsr.
pub const registers = [_]Cortex{
    .r0, .r1,  .r2,  .r3,  .r4, .r5, .r6, .r7,   .r8,
    .r9, .r10, .r11, .r12, .sp, .lr, .pc, .xpsr,
};

/// The largest packet the stub reads, in bytes, as qSupported tells gdb.
pub const packet_size: usize = 0x1000;

/// gdb's SIGTRAP: the machine stopped where the debugger asked it to.
pub const halted = "S05";

const supported = std.fmt.comptimePrint("PacketSize={x};qXfer:features:read+", .{packet_size});
const xfer = "qXfer:features:read:";
const memory_error = "E01";
const request_error = "E00";

pub const Dispatch = struct {
    machine: ?*stop_machine.Machine = null,
    /// With a Zig session attached, run control and threads go to it, and
    /// everything else is answered for the core it has selected.
    zig: ?*zig_run.Target = null,
    /// Where registers and memory are read. Without one, the requests that
    /// need a core get the empty reply.
    view: ?core_view.View = null,

    /// The reply payload for `request`, written into `out`.
    pub fn answer(self: Dispatch, request: []const u8, out: []u8) Error![]const u8 {
        if (self.zig) |live| {
            if (zig_run.handles(request)) return zig_run.answer(live, request, out);
            const core = live.session.currentCore();
            const machine = live.session.machine(core) catch return copy(out, request_error);
            const view = live.session.view(core) catch return copy(out, request_error);
            const selected = Dispatch{ .machine = machine, .view = view };
            return selected.answer(request, out);
        }
        if (request.len == 0) return out[0..0];
        if (std.mem.startsWith(u8, request, "qSupported")) return copy(out, supported);
        if (std.mem.startsWith(u8, request, xfer)) return features.read(request[xfer.len..], out);
        if (std.mem.eql(u8, request, "qAttached")) return copy(out, "1");
        if (needsCore(request[0]) and self.view == null) return out[0..0];
        return switch (request[0]) {
            '?' => copy(out, halted),
            'g' => self.allRegisters(out),
            'p' => self.oneRegister(request[1..], out),
            'm' => self.memory(request[1..], out),
            'G' => self.setAll(request[1..], out),
            'P' => self.setOne(request[1..], out),
            'M' => self.store(request[1..], .hex, out),
            'X' => self.store(request[1..], .binary, out),
            'Z', 'z' => if (self.machine) |machine| points.answer(machine, request, out) else out[0..0],
            'H' => copy(out, "OK"),
            else => out[0..0],
        };
    }

    /// The core registers and memory are read from and written to.
    fn target(self: Dispatch) core_view.View {
        return self.view.?;
    }

    fn needsCore(kind: u8) bool {
        return switch (kind) {
            'g', 'p', 'm', 'G', 'P', 'M', 'X' => true,
            else => false,
        };
    }

    fn allRegisters(self: Dispatch, out: []u8) Error![]const u8 {
        var at: usize = 0;
        for (registers) |which| {
            const value = self.target().register(which) catch return copy(out, request_error);
            try word(out, &at, value);
        }
        return out[0..at];
    }

    fn oneRegister(self: Dispatch, args: []const u8, out: []u8) Error![]const u8 {
        const index = std.fmt.parseInt(usize, args, 16) catch return copy(out, request_error);
        if (index >= registers.len) return copy(out, request_error);
        const value = self.target().register(registers[index]) catch return copy(out, request_error);
        var at: usize = 0;
        try word(out, &at, value);
        return out[0..at];
    }

    fn memory(self: Dispatch, args: []const u8, out: []u8) Error![]const u8 {
        const comma = std.mem.indexOfScalar(u8, args, ',') orelse return copy(out, request_error);
        const address = std.fmt.parseInt(u32, args[0..comma], 16) catch return copy(out, request_error);
        const length = std.fmt.parseInt(usize, args[comma + 1 ..], 16) catch return copy(out, request_error);
        if (length * 2 > out.len) return error.NoSpace;
        var at: usize = 0;
        var chunk: [64]u8 = undefined;
        var done: usize = 0;
        while (done < length) {
            const take = @min(chunk.len, length - done);
            const where = address +% @as(u32, @intCast(done));
            self.target().read(where, chunk[0..take]) catch return copy(out, memory_error);
            for (chunk[0..take]) |byte| try hexByte(out, &at, byte);
            done += take;
        }
        return out[0..at];
    }

    fn setAll(self: Dispatch, args: []const u8, out: []u8) Error![]const u8 {
        if (args.len != registers.len * 8) return copy(out, request_error);
        for (registers, 0..) |which, index| {
            const value = parseWord(args[index * 8 ..][0..8]) orelse return copy(out, request_error);
            self.target().setRegister(which, value) catch return copy(out, request_error);
        }
        return copy(out, "OK");
    }

    fn setOne(self: Dispatch, args: []const u8, out: []u8) Error![]const u8 {
        const equals = std.mem.indexOfScalar(u8, args, '=') orelse return copy(out, request_error);
        const index = std.fmt.parseInt(usize, args[0..equals], 16) catch return copy(out, request_error);
        const text = args[equals + 1 ..];
        if (index >= registers.len or text.len != 8) return copy(out, request_error);
        const value = parseWord(text[0..8]) orelse return copy(out, request_error);
        self.target().setRegister(registers[index], value) catch return copy(out, request_error);
        return copy(out, "OK");
    }

    /// `M addr,length:hex` and `X addr,length:bytes`. An `X` of length zero
    /// is gdb probing whether binary writes work, and is answered OK.
    fn store(self: Dispatch, args: []const u8, form: Form, out: []u8) Error![]const u8 {
        const colon = std.mem.indexOfScalar(u8, args, ':') orelse return copy(out, request_error);
        const head = args[0..colon];
        const data = args[colon + 1 ..];
        const comma = std.mem.indexOfScalar(u8, head, ',') orelse return copy(out, request_error);
        const address = std.fmt.parseInt(u32, head[0..comma], 16) catch return copy(out, request_error);
        const length = std.fmt.parseInt(usize, head[comma + 1 ..], 16) catch return copy(out, request_error);
        const sent = if (form == .hex) data.len / 2 else data.len;
        if (sent != length or (form == .hex and data.len % 2 != 0)) return copy(out, request_error);
        var chunk: [64]u8 = undefined;
        var done: usize = 0;
        while (done < length) {
            const take = @min(chunk.len, length - done);
            const bytes = switch (form) {
                .binary => data[done..][0..take],
                .hex => std.fmt.hexToBytes(chunk[0..take], data[done * 2 ..][0 .. take * 2]) catch return copy(out, request_error),
            };
            const where = address +% @as(u32, @intCast(done));
            self.target().write(where, bytes) catch return copy(out, memory_error);
            done += take;
        }
        if (self.machine) |machine| units.forward(self.target(), machine, address, length);
        return copy(out, "OK");
    }
};

const Form = enum { hex, binary };

/// Eight hex digits in target (little-endian) byte order, as `G` and `P`
/// carry a register.
fn parseWord(text: *const [8]u8) ?u32 {
    var bytes: [4]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text) catch return null;
    return std.mem.readInt(u32, &bytes, .little);
}

/// A register as gdb wants it: the four bytes in target (little-endian)
/// order, two hex digits each.
fn word(out: []u8, at: *usize, value: u32) Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    for (bytes) |byte| try hexByte(out, at, byte);
}

fn hexByte(out: []u8, at: *usize, byte: u8) Error!void {
    if (at.* + 2 > out.len) return error.NoSpace;
    const digits = std.fmt.hex(byte);
    out[at.*] = digits[0];
    out[at.* + 1] = digits[1];
    at.* += 2;
}

fn copy(out: []u8, text: []const u8) Error![]const u8 {
    if (out.len < text.len) return error.NoSpace;
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}
