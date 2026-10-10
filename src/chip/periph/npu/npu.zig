//! The Ethos-U55 micro-NPU: the command register, the stream it points at,
//! and what actually reaches the arenas.
//!
//! The RA8P1 carries an Arm Ethos-U55 behind a 4 KiB window at 0x4014_0000;
//! the RA8D2 does not, so this block is attached only on the RA8P1 profile
//! and on the RA8D2 the window falls through to the sparse bus, exactly as
//! the device tag on dev arranges.
//!
//! What runs is not Vela. The driver's submit, run, poll, read-output
//! protocol is real, and the program behind QBASE is the documented stand-in
//! in cmd.zig, so an image can prove the whole path end to end without
//! this model pretending to do inference. Ported from board_periph_npu.c on
//! dev, with five things that model does not do.
//!
//! AN UNKNOWN OPCODE IS NOT A COPY. dev checks the marker, masks the opcode
//! out of the first word, and then runs anything that is not add-constant
//! down the copy path. So a stream carrying opcode 7 moves its bytes, sets
//! cmd_end, raises the interrupt and lands in the report as a completed job
//! named "unknown". That is the one thing the C file's own header promises
//! it will not do. Here an opcode outside the two implemented ones is a
//! parse fault: nothing moves, and it is counted.
//!
//! A FAULT RAISES THE INTERRUPT. dev sets STATUS.irq_raised on a fault and
//! then returns without raising the event, so the status register says an
//! interrupt was raised and no interrupt ever arrives. A driver that submits
//! a bad stream and waits on the NPU line waits for the rest of the run.
//! Here a fault raises the same event a completion does, because on silicon
//! the interrupt is that status bit.
//!
//! THE COMMAND BIT IS SPENT. dev stores the CMD write into its shadow before
//! acting on it, so NPU_CMD reads back with the run bit still set. The
//! driver's own acknowledge, read CMD, set clear_irq, write it back, then
//! kicks the job a second time from the bit it just read. Here CMD is a
//! command register: it is acted on and never kept, and reads back zero.
//!
//! ID AND STATUS ARE THE CONTROLLER'S. dev takes stores anywhere in the
//! window, NPU_ID and NPU_STATUS included, into the shadow its read path
//! then ignores, so the store is swallowed without a word. Refused and
//! counted here, the way this tree already treats CETCR, SRAMESR and INTS.
//!
//! NARROW ACCESSES KEEP THEIR SHAPE. dev's reg[off / 4] = value makes a
//! halfword store to QBASE's low half wipe the high half of the address, and
//! its read hands back the whole word whatever the access width was.
//!
//! A REFUSED ARENA DOES NOT UNDO THE BYTES THAT LANDED. The copy runs in
//! bounded chunks, so an arena that walks off mapped memory partway through
//! leaves everything before that address transformed and written, and the
//! kick still faults with no cmd_end, which is right. What was wrong was the
//! book-keeping: the chunks that landed were forgotten with the rest, so a
//! run whose destination ended mid-job said nothing moved while a kilobyte
//! of it sat in the arena. A short job now books what got through and is
//! counted as its own kind, separately from the jobs that finished.
//!
//! MODEL RULES, stated rather than implied: execution is instantaneous, so
//! STATUS.state never reads running and STATUS.reset never reads asserted;
//! and a guest address is 32 bits here, so a BASEPn with anything in its
//! high word is refused rather than truncated into a plausible pointer.
const std = @import("std");
const Bounded = @import("../../core/bounded.zig").Bounded;
const Guest = @import("../../core/cpu/memory/guest.zig").Guest;
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");
pub const cmd = @import("cmd.zig");
pub const vela_hook = @import("vela_hook.zig");
pub const vela = @import("vela.zig");
pub const vela_regs = @import("vela_regs.zig");
pub const snapshot = @import("snapshot.zig");

/// The window, from ra8_npu_regs.h on dev.
pub const win_base: u32 = 0x4014_0000;
pub const win_span: u32 = 0x1000;

/// The registers this model interprets. Everything else in the window is
/// shadowed.
pub const off = struct {
    pub const id: u32 = 0x0000;
    pub const status: u32 = 0x0004;
    pub const command: u32 = 0x0008;
    pub const reset: u32 = 0x000C;
    pub const qbase: u32 = 0x0010;
    pub const qsize: u32 = 0x0020;
    pub const basep0: u32 = 0x0080;
};

/// The 64-bit registers: a low word, then a high word four bytes above it.
pub const geometry = struct {
    pub const hi_offset: u32 = 4;
    pub const basep_stride: u32 = 8;
};

pub const field = struct {
    /// CMD.transition_to_running_state.
    pub const cmd_run: u32 = 1 << 0;
    /// CMD.clear_irq, write one to acknowledge.
    pub const cmd_clear_irq: u32 = 1 << 1;
    /// STATUS.state, never set here: a job finishes inside its own kick.
    pub const status_state: u32 = 1 << 0;
    pub const status_irq: u32 = 1 << 1;
    pub const status_bus_error: u32 = 1 << 2;
    pub const status_reset: u32 = 1 << 3;
    pub const status_parse: u32 = 1 << 4;
    pub const status_cmd_end: u32 = 1 << 5;
};

/// NPU_ID: arch 1.0.6, product major 0 for the U55. The driver only needs a
/// stable non-zero identity, and nothing in the model reads it back.
pub const identity: u32 = 0x1006_0000;

/// The NPU_IRQ event, from the RA8P1 ELC table.
pub const event = struct {
    pub const irq: u16 = 0x067;
};

pub const Due = Bounded(u16, 1);

const words: usize = win_span / 4;

/// What a copy actually moved. `short` means an arena refused an access and
/// the job ended there; the bytes counted are in the destination already.
pub const Moved = struct {
    bytes: u32 = 0,
    check: u32 = 0,
    short: bool = false,
};

pub const Npu = struct {
    reg: [words]u32 = @splat(0),
    /// STATUS as this model computes it, held rather than shadowed.
    state: u32 = 0,
    /// The arenas a job moves bytes between. A board built by a test without
    /// an engine leaves it null and a kick is refused rather than faked.
    memory: ?Guest = null,

    jobs: u32 = 0,
    /// Bytes the completed jobs moved.
    moved: u32 = 0,
    last_op: ?cmd.Op = null,
    last_bytes: u32 = 0,
    last_check: u32 = 0,
    /// Streams carrying our marker and an opcode this model does not run.
    unknown_ops: u32 = 0,
    /// Streams that are not ours at all, or whose fields do not describe a
    /// job: too short, no marker, a region with no BASEPn, a bad count.
    malformed: u32 = 0,
    /// Kicks where the stream or an arena could not be reached.
    unreachable_memory: u32 = 0,
    /// Kicks naming a region whose BASEPn was never programmed, or one above
    /// the 32-bit guest space.
    unmapped_region: u32 = 0,
    /// Kicks an arena refused partway, after some bytes had already landed.
    short_jobs: u32 = 0,
    /// Bytes those kicks left in the destination arena before the refusal.
    short_bytes: u32 = 0,
    /// Completed jobs whose source and destination were the same region.
    in_place: u32 = 0,
    /// Stores to NPU_ID or NPU_STATUS: firmware cannot write its own result.
    faked: u32 = 0,
    /// Kicks whose stream had no stand-in marker, run as Vela programs.
    vela: vela_hook.Counters = .{},
    reads: u32 = 0,
    writes: u32 = 0,
    due_irq: bool = false,

    pub fn init() Npu {
        return .{};
    }

    pub fn quiet(self: *const Npu) bool {
        return self.jobs == 0 and self.faults() == 0 and self.faked == 0 and
            self.reads == 0 and self.writes == 0;
    }

    /// Every kick that ended in a fault rather than a job.
    pub fn faults(self: *const Npu) u32 {
        return self.unknown_ops + self.malformed + self.unreachable_memory +
            self.unmapped_region;
    }

    /// The interrupt this boundary earned, offered once. A fault raises it
    /// too: the status bit and the line are the same thing on silicon.
    pub fn dueEvents(self: *Npu) Due {
        var due = Due{};
        if (self.due_irq) {
            self.due_irq = false;
            due.appendAssumeCapacity(event.irq);
        }
        return due;
    }

    pub fn read(self: *Npu, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        self.reads +%= 1;
        const aligned = offset & ~@as(u32, 3);
        const value = switch (aligned) {
            off.id => identity,
            off.status => self.state,
            else => self.reg[offset / 4],
        };
        return lanes.part(value, offset % 4, width);
    }

    pub fn write(self: *Npu, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        self.writes +%= 1;
        const aligned = offset & ~@as(u32, 3);
        if (aligned == off.id or aligned == off.status) {
            self.faked +%= 1;
            return;
        }
        const merged = lanes.merge(self.reg[offset / 4], offset % 4, width, value);
        if (aligned == off.command) {
            // Spent, not kept: the run bit is a command, not a setting.
            self.onCommand(merged);
            return;
        }
        self.reg[offset / 4] = merged;
        if (aligned == off.reset) self.onReset();
    }

    /// A CMD write. The acknowledge lands before the kick, so a write that
    /// carries both leaves the interrupt the new job raises standing.
    fn onCommand(self: *Npu, value: u32) void {
        if (value & field.cmd_clear_irq != 0) self.state &= ~field.status_irq;
        if (value & field.cmd_run != 0) self.execute();
    }

    /// NPU_RESET discards the job state. STATUS.reset never reads asserted:
    /// the reset is done by the time the store returns.
    fn onReset(self: *Npu) void {
        self.state = 0;
        self.due_irq = false;
    }

    /// One kick: read the stream, decode it, move the bytes, latch the
    /// result. Every exit that is not a completed job is a fault, and every
    /// fault raises the interrupt.
    fn execute(self: *Npu) void {
        const memory = self.memory orelse return self.fault(
            field.status_bus_error,
            &self.unreachable_memory,
        );
        const stream = self.readStream(memory) orelse return self.fault(
            field.status_bus_error,
            &self.unreachable_memory,
        );
        if (stream[0] & cmd.header.magic_mask != cmd.header.magic) return vela_hook.kick(self, memory);
        const program = cmd.decode(self.reg[off.qsize / 4], stream) catch |why| {
            const counter = switch (why) {
                cmd.Reject.UnknownOpcode => &self.unknown_ops,
                else => &self.malformed,
            };
            return self.fault(field.status_parse, counter);
        };
        const source = self.regionBase(program.source) orelse return self.fault(
            field.status_parse,
            &self.unmapped_region,
        );
        const destination = self.regionBase(program.destination) orelse return self.fault(
            field.status_parse,
            &self.unmapped_region,
        );
        const moved = transfer(memory, program, source, destination);
        if (moved.short) return self.cutShort(moved);
        self.complete(program, moved.check);
    }

    /// The five header words at QBASE, or null if guest memory refused one.
    fn readStream(self: *const Npu, memory: Guest) ?[cmd.header.words]u32 {
        const base = self.reg64(off.qbase);
        if (base > std.math.maxInt(u32)) return null;
        var stream: [cmd.header.words]u32 = undefined;
        for (&stream, 0..) |*word, index| {
            const at = base + index * 4;
            if (at > std.math.maxInt(u32)) return null;
            word.* = memory.readWord(@intCast(at)) catch return null;
        }
        return stream;
    }

    /// Move the bytes one bounded chunk at a time, folding the result into
    /// the checkword as it goes. A refused access ends the copy where it
    /// stands: the chunk it refused moved nothing, the chunks before it are
    /// in the destination arena, and that is what comes back.
    fn transfer(
        memory: Guest,
        program: cmd.Command,
        source: u32,
        destination: u32,
    ) Moved {
        var buffer: [cmd.limits.chunk_bytes]u8 = undefined;
        var check = cmd.Check{};
        var done: u32 = 0;
        while (done < program.count) {
            const left = program.count - done;
            const take = @min(left, @as(u32, cmd.limits.chunk_bytes));
            const slice = buffer[0..take];
            memory.read(source + done, slice) catch return cut(done, check);
            for (slice) |*byte| byte.* = program.transform(byte.*);
            memory.write(destination + done, slice) catch return cut(done, check);
            check.fold(slice);
            done += take;
        }
        return .{ .bytes = done, .check = check.value };
    }

    /// The AXI base programmed into BASEPn. Null when it was never
    /// programmed, or when it names an address this 32-bit guest cannot hold.
    fn regionBase(self: *const Npu, index: u32) ?u32 {
        const base = self.reg64(off.basep0 + index * geometry.basep_stride);
        if (base == 0 or base > std.math.maxInt(u32)) return null;
        return @intCast(base);
    }

    /// A 64-bit register, low word then high word.
    fn reg64(self: *const Npu, low: u32) u64 {
        const lo = self.reg[low / 4];
        const hi = self.reg[(low + geometry.hi_offset) / 4];
        return @as(u64, lo) | (@as(u64, hi) << 32);
    }

    fn complete(self: *Npu, program: cmd.Command, check: u32) void {
        self.state = field.status_cmd_end | field.status_irq;
        self.jobs +%= 1;
        self.moved +%= program.count;
        self.last_op = program.op;
        self.last_bytes = program.count;
        self.last_check = check;
        if (program.inPlace()) self.in_place +%= 1;
        self.due_irq = true;
    }

    /// A kick an arena refused partway. The bytes before the refused address
    /// are in the destination arena, so they are booked; the job still
    /// faults, so cmd_end stays clear and a driver polling for completion
    /// never sees one. last_op and the checkword are left alone deliberately:
    /// they describe the last job that finished, and this one did not.
    fn cutShort(self: *Npu, moved: Moved) void {
        self.short_jobs +%= 1;
        self.short_bytes +%= moved.bytes;
        self.fault(field.status_bus_error, &self.unreachable_memory);
    }

    /// A kick that produced no job: the fault bit, the interrupt, and the
    /// counter that says which kind it was. cmd_end is deliberately absent,
    /// so a driver polling for completion never sees one.
    fn fault(self: *Npu, bit: u32, counter: *u32) void {
        self.state = bit | field.status_irq;
        counter.* +%= 1;
        self.due_irq = true;
    }

    pub fn block(self: *Npu) periph.Block {
        return .{
            .name = "NPU",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// A copy that stopped at a refused access, carrying what got through.
fn cut(done: u32, check: cmd.Check) Moved {
    return .{ .bytes = done, .check = check.value, .short = true };
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Npu = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Npu = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one region's base-pointer pair, so a test or a later slice
/// does not do the arithmetic itself.
pub fn regionAddress(index: usize) u32 {
    return win_base + off.basep0 + @as(u32, @intCast(index)) * geometry.basep_stride;
}
