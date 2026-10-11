//! CEU: the parallel-camera capture engine, and the frame it actually wrote.
//!
//! The RA8D2 Capture Engine Unit sits at 0x4034_8000 (HUM Ch 60, the parallel
//! camera path ra8_ceu.c drives). The firmware's `camera_capture` example
//! programs the geometry, points CDAYR at a frame buffer, arms a single shot
//! by setting CAPSR.CE, then polls CETCR.CPE for one-frame-end. On silicon
//! that end comes from the sensor's VD edge; there is no sensor here, so the
//! capture happens inside the CE write and a deterministic diagonal gradient,
//! (x + y) & 0xFF, stands in for the pixels. That is enough for the app to
//! run its capture -> stats -> verdict path with a non-degenerate min, max
//! and mean. It is not a claim the silicon captured anything: the board's
//! J1/TFT VIO_HD conflict (issue #119) is outside what any model can see.
//!
//! Ported from board_periph_ceu.c on dev, with four things that model does
//! not do.
//!
//! CETCR IS WHAT THE ENGINE RAISED, NOT A REGISTER FIRMWARE FILLS IN. dev
//! drops any store straight into the register, so an image writes CETCR = 1
//! and reads back a completed frame having never armed a capture, which is
//! the whole claim the camera demo exists to make. Here a store may only
//! clear a flag that is set, which is how the real event register behaves;
//! a store that would raise one is refused and counted, the way SRAMESR and
//! POEG's PIDF are.
//!
//! THE DESTINATION STRIDE IS NOT THE CAPTURE WIDTH. dev takes CDWDR as the
//! number of bytes to write per line and fills all of them, so a frame
//! buffer whose lines are padded (stride wider than the image) comes back
//! with the gradient painted over the padding. Here CAPWR.HWDTH is how many
//! bytes a line carries and CDWDR is only how far the next line starts, so
//! the padding is left exactly as the firmware left it.
//!
//! A GEOMETRY TOO BIG TO MODEL IS REFUSED, NOT QUIETLY SHRUNK. dev clamps a
//! line to 8192 bytes and a frame to 4096 lines and captures anyway, so an
//! image that programmed the geometry wrongly still gets CPE and reads its
//! stats out of a frame smaller than the one it asked for. Here the arm is
//! declined and no event is raised.
//!
//! A WRITE THE MEMORY REFUSES IS A FAILED CAPTURE. dev ignores the result of
//! every guest write, so a CDAYR pointing at nothing mapped still latches
//! CPE and still counts a frame. Here the capture is abandoned at the first
//! refused line and CPE stays clear.
//!
//! A CAPTURE CUT SHORT STILL WROTE WHAT IT WROTE. The frame is painted line
//! by line, so a destination that walks off mapped memory partway through
//! leaves every line before the refused address sitting in the firmware's
//! buffer. Those lines are booked under short_frames/short_lines/short_bytes
//! and named in the end-of-run report. What the firmware sees does NOT
//! change: CETCR.CPE stays clear, CAPSR.CE stays set, frames is not counted
//! and CDSSR still answers with the last frame that ran to its last line,
//! because the frame the firmware armed did not arrive.
//!
//! NOT MODELLED, AND NOT GUESSED: everything CETCR carries besides CPE (the
//! field, overflow and CHDW events), the capture-format and clipping
//! registers, and the Plane-B address path. No header for this part is in
//! this tree to say what their bits mean, so they are shadowed, so that a
//! read-modify-write of them survives, and never interpreted. CSTSR reads
//! idle because the capture is instantaneous, and CAPSR.CPKIL self-clears
//! for the same reason.
const std = @import("std");

const Guest = @import("../core/cpu/memory/guest/guest.zig").Guest;
const TimeBase = @import("time/timebase.zig").TimeBase;
const periph = @import("registry.zig");
/// The pixel sources the CEU captures from (RA8EMU-505).
pub const camera = struct {
    pub const frame_source = @import("camera/frame_source.zig");
    pub const gradient = @import("camera/gradient_source.zig");
};

pub const win_base: u32 = 0x4034_8000;
pub const win_span: u32 = 0x100;

/// The Plane-A registers this model interprets (ra8_ceu_regs.h).
pub const off = struct {
    /// CAPSR: CE arms one capture, CPKIL is the software reset.
    pub const capsr: u32 = 0x00;
    /// CMCYR: interface cycles, the geometry fallback.
    pub const cmcyr: u32 = 0x0C;
    /// CAPWR: the captured window, in destination bytes and lines.
    pub const capwr: u32 = 0x14;
    /// CDWDR: how far apart two destination lines start.
    pub const cdwdr: u32 = 0x38;
    /// CDAYR: the destination Y address.
    pub const cdayr: u32 = 0x3C;
    /// CETCR: the capture event flags.
    pub const cetcr: u32 = 0x74;
    /// CSTSR: capture status, CPTON.
    pub const cstsr: u32 = 0x7C;
    /// CDSSR: bytes the last capture wrote.
    pub const cdssr: u32 = 0x84;
};

pub const field = struct {
    pub const capture_enable: u32 = 1 << 0;
    pub const capture_kill: u32 = 1 << 16;
    /// CETCR.CPE: one-frame capture end.
    pub const frame_end: u32 = 1 << 0;
    /// CMCYR.HCYL[13:0] and VCYL[13:0].
    pub const cycle: u32 = 0x3FFF;
    /// CAPWR.HWDTH[12:0], and the CDWDR stride beside it.
    pub const width: u32 = 0x1FFF;
    /// CAPWR.VWDTH[11:0].
    pub const height: u32 = 0x0FFF;
    pub const vertical_shift: u5 = 16;
};

/// What this model is willing to synthesise. Beyond it the arm is declined,
/// because a frame cut down to fit is a frame the firmware did not ask for.
pub const bound = struct {
    pub const line_bytes: u32 = 8192;
    pub const lines: u32 = 4096;
};

/// The default source's gradient; one chunk is also the line write size.
pub const pattern = camera.gradient.pattern;

/// Why an armed capture wrote nothing. Every one of them fails safe: no
/// frame, no CETCR.CPE, so a firmware relying on it waits rather than
/// reading stats out of pixels this model invented.
pub const Decline = enum {
    /// No geometry programmed: neither CAPWR nor CMCYR names a shape.
    unprogrammed,
    /// A shape past what this model synthesises, which dev clamps instead.
    oversized,
    /// CDAYR is still zero, so the frame has nowhere to go.
    unaddressed,
    /// No memory behind the board, which only a test build hits.
    unbacked,
    /// The memory refused a line, e.g. CDAYR points at nothing mapped.
    faulted,
};

/// The destination shape: how many bytes a line carries, how many lines the
/// frame has, and how far apart two lines start.
pub const Geometry = struct {
    width: u32,
    lines: u32,
    stride: u32,
};

/// What a capture actually put in the destination buffer before it ended.
/// `lines` counts only lines painted whole; `bytes` counts every byte that
/// landed, including the part of a line the memory refused halfway.
pub const Landed = struct {
    lines: u32 = 0,
    bytes: u32 = 0,
};

pub const Ceu = struct {
    /// Where the frame goes. A board built by a test that never captures
    /// leaves it null and the arm is declined as unbacked.
    memory: ?Guest = null,
    /// Where the pixels come from; the gradient unless a source is chosen.
    source: camera.frame_source.FrameSource = camera.gradient.source(),
    /// The board's virtual time, read at each arm and handed to the source
    /// (RA8EMU-540). A bare test CEU has none and its source sees 0.
    clock: ?*const TimeBase = null,
    shadow: [win_span / 4]u32 = @splat(0),

    arms: u32 = 0,
    frames: u32 = 0,
    last_width: u32 = 0,
    last_lines: u32 = 0,
    last_bytes: u32 = 0,
    declined: u32 = 0,
    last_decline: ?Decline = null,
    /// Stores that tried to raise a CETCR flag rather than clear one.
    faked: u32 = 0,
    /// Guest writes the memory refused.
    faults: u32 = 0,
    resets: u32 = 0,
    /// Captures the memory ended partway with something already in the
    /// buffer, and the lines and bytes those captures left behind.
    short_frames: u32 = 0,
    short_lines: u32 = 0,
    short_bytes: u32 = 0,

    pub fn init() Ceu {
        return .{};
    }

    pub fn quiet(self: *const Ceu) bool {
        return self.arms == 0 and self.faked == 0 and self.resets == 0;
    }

    /// CSTSR reads idle: this model captures inside the CE write, so the
    /// engine is never busy by the time firmware can look. CDSSR answers
    /// with what the last capture actually wrote, never with a stored value.
    pub fn read(self: *Ceu, address: u32, width: u3) u32 {
        const offset = (address -% win_base) & (win_span - 1);
        const aligned = offset & ~@as(u32, 3);
        const whole = switch (aligned) {
            off.cstsr => 0,
            off.cdssr => self.last_bytes,
            off.capsr => self.word(off.capsr) & ~field.capture_kill,
            else => self.word(aligned),
        };
        return extract(whole, offset, width);
    }

    pub fn write(self: *Ceu, address: u32, width: u3, value: u32) void {
        const offset = (address -% win_base) & (win_span - 1);
        const aligned = offset & ~@as(u32, 3);
        const merged = merge(self.word(aligned), offset, width, value);
        switch (aligned) {
            // Status and the byte count belong to the engine, not to a store.
            off.cstsr, off.cdssr => {},
            off.cetcr => self.clearEvents(merged),
            off.capsr => self.command(merged),
            else => self.latch(aligned, merged),
        }
    }

    fn word(self: *const Ceu, offset: u32) u32 {
        return self.shadow[offset >> 2];
    }

    fn latch(self: *Ceu, offset: u32, value: u32) void {
        self.shadow[offset >> 2] = value;
    }

    /// A store to CETCR may clear a flag the engine raised and nothing else.
    fn clearEvents(self: *Ceu, merged: u32) void {
        const held = self.word(off.cetcr);
        if (merged & ~held != 0) self.faked +%= 1;
        self.latch(off.cetcr, held & merged);
    }

    /// CPKIL drops the pending events and the arm, then self-clears. A plain
    /// CE write arms one capture.
    fn command(self: *Ceu, merged: u32) void {
        if (merged & field.capture_kill != 0) {
            self.latch(off.cetcr, 0);
            self.latch(off.capsr, merged & ~(field.capture_kill | field.capture_enable));
            self.resets +%= 1;
            return;
        }
        self.latch(off.capsr, merged);
        if (merged & field.capture_enable != 0) self.capture();
    }

    /// CAPWR is what the capture window says; CMCYR is what the interface
    /// cycles say, and stands in when CAPWR is still zero. The stride falls
    /// back to the width, which is a frame buffer with no padding.
    pub fn geometry(self: *const Ceu) Geometry {
        const capwr = self.word(off.capwr);
        const cmcyr = self.word(off.cmcyr);
        const width = pick(capwr & field.width, cmcyr & field.cycle);
        return .{
            .width = width,
            .lines = pick(
                capwr >> field.vertical_shift & field.height,
                cmcyr >> field.vertical_shift & field.cycle,
            ),
            .stride = pick(self.word(off.cdwdr) & field.width, width),
        };
    }

    pub fn declineReason(self: *const Ceu) ?Decline {
        const shape = self.geometry();
        if (shape.width == 0 or shape.lines == 0) return .unprogrammed;
        if (shape.width > bound.line_bytes or shape.lines > bound.lines) return .oversized;
        if (self.word(off.cdayr) == 0) return .unaddressed;
        if (self.memory == null) return .unbacked;
        return null;
    }

    /// One armed shot: paint the gradient line by line, then raise the end.
    pub fn capture(self: *Ceu) void {
        self.arms +%= 1;
        if (self.declineReason()) |reason| return self.decline(reason);
        const shape = self.geometry();
        const destination = self.word(off.cdayr);
        const when = if (self.clock) |time| time.now() else 0;
        self.source.frame(when, .{ .width = shape.width, .lines = shape.lines });
        var landed = Landed{};
        var row: u32 = 0;
        while (row < shape.lines) : (row += 1) {
            const line = @as(u64, destination) + @as(u64, row) * shape.stride;
            const wrote = self.fill(line, shape.width, row);
            landed.bytes += wrote;
            if (wrote < shape.width) return self.cutShort(landed);
            landed.lines += 1;
        }
        self.complete(shape);
    }

    /// How many bytes of one line reached memory. Short of `width` means the
    /// memory refused the chunk starting there; the bytes before it stay.
    fn fill(self: *Ceu, line: u64, width: u32, row: u32) u32 {
        const memory = self.memory.?;
        var scratch: [pattern.chunk]u8 = undefined;
        var column: u32 = 0;
        while (column < width) {
            const span = @min(pattern.chunk, width - column);
            const slice = scratch[0..span];
            self.source.fill(row, column, slice);
            const at = line + column;
            if (at > std.math.maxInt(u32)) {
                self.faults +%= 1;
                return column;
            }
            memory.write(@intCast(at), slice) catch {
                self.faults +%= 1;
                return column;
            };
            column += span;
        }
        return column;
    }

    /// A capture the memory ended partway. The lines before the refused
    /// address are in the buffer, so they are booked; the arm is still a
    /// failed one, because the frame the firmware asked for did not arrive.
    fn cutShort(self: *Ceu, landed: Landed) void {
        if (landed.bytes != 0) {
            self.short_frames +%= 1;
            self.short_lines +%= landed.lines;
            self.short_bytes +%= landed.bytes;
        }
        self.decline(.faulted);
    }

    fn complete(self: *Ceu, shape: Geometry) void {
        self.latch(off.cetcr, self.word(off.cetcr) | field.frame_end);
        self.latch(off.capsr, self.word(off.capsr) & ~field.capture_enable);
        self.frames +%= 1;
        self.last_width = shape.width;
        self.last_lines = shape.lines;
        self.last_bytes = shape.width * shape.lines;
    }

    /// CE is left set, as dev leaves it: on silicon the capture is still
    /// armed, waiting for a VD edge, and the firmware's poll times out.
    fn decline(self: *Ceu, reason: Decline) void {
        self.declined +%= 1;
        self.last_decline = reason;
    }

    pub fn block(self: *Ceu) periph.Block {
        return .{
            .name = "CEU",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn pick(primary: u32, fallback: u32) u32 {
    return if (primary != 0) primary else fallback;
}

fn laneShift(offset: u32) u5 {
    return @intCast((offset & 3) * 8);
}

fn laneMask(width: u3) u32 {
    return switch (width) {
        1 => 0xFF,
        2 => 0xFFFF,
        else => 0xFFFF_FFFF,
    };
}

fn extract(whole: u32, offset: u32, width: u3) u32 {
    return (whole >> laneShift(offset)) & laneMask(width);
}

/// A narrow store touches the bytes it names and leaves the rest of the
/// register standing.
fn merge(held: u32, offset: u32, width: u3, value: u32) u32 {
    const shift = laneShift(offset);
    const mask = laneMask(width) << shift;
    return (held & ~mask) | ((value << shift) & mask);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Ceu = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Ceu = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
