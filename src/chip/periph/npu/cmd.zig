//! The command stream the NPU model can read, and nothing about registers.
//!
//! ra8_emulator is not a Vela interpreter, so the stream this model executes
//! is the small documented stand-in from inc/ra8_npu_fake_cmd.h on dev: five
//! words, a marker in the top half of the first one, an opcode in its bottom
//! half, then a source region, a destination region, a byte count and a
//! constant. A real Vela program carries none of that, which is exactly how
//! this model tells the two apart.
//!
//! The decode lives here rather than in npu.zig so the register window stays
//! a register window, the same split dmac/dmac.zig and dmac/xfer.zig, and
//! sdhi/sdhi.zig and sdhi/xfer.zig, have.
const std = @import("std");

/// The header the stand-in program starts with.
pub const header = struct {
    /// "SE55" in bits [31:16], the marker that says this stream is ours.
    pub const magic: u32 = 0x5E55_0000;
    pub const magic_mask: u32 = 0xFFFF_0000;
    pub const op_mask: u32 = 0x0000_FFFF;
    /// Five words, all of them populated.
    pub const words: usize = 5;
    pub const bytes: u32 = 20;
};

pub const limits = struct {
    /// BASEP0..7, so a region index above 7 names nothing.
    pub const regions: u32 = 8;
    /// What one job may move, and what bounds the transfer loop.
    pub const max_bytes: u32 = 4096;
    /// Bytes carried through the model per pass of that loop.
    pub const chunk_bytes: usize = 256;
};

/// The two operations this model implements. There is no `unknown` member on
/// purpose: an opcode outside this set is refused at the decode, never run as
/// something near it.
pub const Op = enum(u16) {
    copy = 1,
    add_constant = 2,

    pub fn label(self: Op) []const u8 {
        return switch (self) {
            .copy => "copy",
            .add_constant => "add-const",
        };
    }
};

/// Why a stream is not a job. Each one is counted separately by the window,
/// because they say different things about the image that submitted it.
pub const Reject = error{
    /// QSIZE is shorter than the header, so there is no program to read.
    ShortStream,
    /// No marker: a real Vela program, or something else entirely.
    NotOurs,
    /// Our marker, an opcode this model does not implement.
    UnknownOpcode,
    /// A region index with no BASEPn behind it.
    BadRegion,
    /// Nothing to move, or more than one job may move.
    BadCount,
};

pub const Command = struct {
    op: Op,
    source: u32,
    destination: u32,
    count: u32,
    addend: u32,

    /// A job whose source and destination name the same region. Silicon runs
    /// it, so this model runs it too; it is counted only because a test
    /// image that "proves the NPU ran" this way moved nothing observable.
    pub fn inPlace(self: Command) bool {
        return self.source == self.destination;
    }

    /// One byte of the result, from one byte of the source.
    pub fn transform(self: Command, byte: u8) u8 {
        return switch (self.op) {
            .copy => byte,
            .add_constant => byte +% @as(u8, @truncate(self.addend)),
        };
    }
};

/// The submitted stream, decoded. `size` is QSIZE as the driver programmed
/// it; `stream` is the five words read from QBASE.
pub fn decode(size: u32, stream: [header.words]u32) Reject!Command {
    if (size < header.bytes) return Reject.ShortStream;
    if (stream[0] & header.magic_mask != header.magic) return Reject.NotOurs;
    const command = Command{
        .op = opcode(stream[0]) orelse return Reject.UnknownOpcode,
        .source = stream[1],
        .destination = stream[2],
        .count = stream[3],
        .addend = stream[4],
    };
    if (command.source >= limits.regions) return Reject.BadRegion;
    if (command.destination >= limits.regions) return Reject.BadRegion;
    if (command.count == 0 or command.count > limits.max_bytes) return Reject.BadCount;
    return command;
}

/// The opcode a first word names, or null for one this model does not run.
fn opcode(word: u32) ?Op {
    return switch (word & header.op_mask) {
        @backingInt(Op.copy) => .copy,
        @backingInt(Op.add_constant) => .add_constant,
        else => null,
    };
}

/// The FNV-1a fold over the bytes a job produced. The driver has no way to
/// read the output arena back through the emulator, so this checkword is what
/// the end-of-run report shows for "the job really did move these bytes".
pub const Check = struct {
    pub const offset_basis: u32 = 0x811C_9DC5;
    pub const prime: u32 = 0x0100_0193;

    value: u32 = offset_basis,

    pub fn fold(self: *Check, bytes: []const u8) void {
        for (bytes) |byte| self.value = (self.value ^ byte) *% prime;
    }
};

/// The five header words, packed little-endian, for a test or a firmware
/// image that wants to lay one down.
pub fn encode(command: Command) [header.words]u32 {
    return .{
        header.magic | @backingInt(command.op),
        command.source,
        command.destination,
        command.count,
        command.addend,
    };
}
