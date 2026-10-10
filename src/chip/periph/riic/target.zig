//! The RIIC target (peripheral) role: the emulator is the external controller.
//!
//! Once firmware programmes an own address (SARLy) and enables its slot
//! (ICSER.SARyE), the part answers as a target and something else on the bus
//! drives the clock. Headless there is nothing else, so this model IS that
//! controller: it writes a known payload at the firmware's own address, reads
//! it back, and checks the firmware echoed what it was sent.
//!
//! A CONTROLLER ENDS A READ BY NOT ACKNOWLEDGING THE LAST BYTE IT WANTED.
//! ra8_i2c_peripheral.c's own state diagram says so in the TX_ACTIVE box
//! ("push ICDRT while TDRE set and no NACK, until len") and its exit arrow
//! ("NACK (controller end) or sent == len"), and the two predicates behind
//! that box test the bit directly:
//!
//!     priv_ra8_i2c_internal_peripheral_tx_continue(icsr2, sent, len)
//!       = (icsr2 & nackf) == 0 && sent < len
//!     priv_ra8_i2c_internal_peripheral_tx_done(icsr2)
//!       = (icsr2 & nackf) != 0 || (icsr2 & tend) != 0
//!
//! This model never raised NACKF, so the controller's end of the frame was
//! invisible: tx_continue stayed true and the send loop ran to the CALLER'S
//! buffer length rather than stopping at the bytes the controller asked for,
//! and internal_i2c_target_finish_tx then passed its TEND|NACKF wait only on
//! the TEND this model leaves standing for the whole phase, which is a wait
//! passing for the wrong reason. The run then counted every extra byte and
//! called the echo MISMATCHED, blaming firmware for a NACK nothing sent.
//!
//! So the read phase now NACKs and stops once it has the bytes it wanted,
//! and a phase ends on the fall of the flag it was waiting on rather than on
//! any ICSR2 write at all. ICSR2 is write-0-to-clear and the driver clears
//! several bits in one store (finish_tx clears NACKF and STOP together), so
//! the rule is about WHICH bit fell, not that a store happened: clearing
//! RDRF between payload bytes, or clearing the error flags mid-frame the way
//! ra8_i2c_clear_errors does, no longer skips the script forward a phase.
const std = @import("std");
const flag = @import("flags.zig");
const bus = @import("bus.zig");

/// The script the synthetic controller drives.
pub const script = struct {
    pub const payload = [_]u8{ 0xDE, 0xAD };
    pub const cycles: u32 = 4;
    /// Echo capture bound. Two bytes go out per cycle; anything past this is
    /// a firmware fault, not a transfer.
    pub const capture: usize = 8;
};

pub const Phase = enum {
    /// No own address armed: the target model is inert.
    idle,
    /// The controller is writing the payload (RDRF then STOP).
    writing,
    /// The controller is reading the echo back (TDRE and TEND).
    reading,
    /// Script complete: the bus is quiet and no address matches.
    done,
};

pub const Target = struct {
    phase: Phase = .idle,
    armed: bool = false,
    own_address: u7 = 0,
    /// The target-role ICSR2 the firmware polls.
    status: u8 = 0,
    /// ICDRR serves consumed this write; 0 is the matched address byte.
    served: usize = 0,
    /// Echo bytes the firmware transmitted this read.
    echoed: usize = 0,
    captured: [script.capture]u8 = @splat(0),
    cycles: u32 = 0,
    mismatched: bool = false,
    /// Read frames the controller ended by not acknowledging the last byte
    /// it wanted. One per completed read, so it tracks `cycles` on a run
    /// where the firmware respects the NACK.
    nacked: u32 = 0,
    /// ICSER writes that named a slot whose own-address register was still
    /// zero. dev latched it and answered at address 0x00, which is the
    /// general call and never a target's own address, so the firmware looked
    /// like it was being addressed by a controller that could not exist.
    unaddressed: u32 = 0,

    pub fn quiet(self: *const Target) bool {
        return self.cycles == 0 and self.unaddressed == 0 and !self.armed;
    }

    /// ICSER decides whether the responder is armed. The enabled slot's own
    /// address has to be a real one before anything answers.
    pub fn open(self: *Target, icser: u8, own: [3]u8) void {
        if (icser & flag.icser.slots == 0) {
            self.armed = false;
            self.phase = .idle;
            return;
        }
        const slot: usize = if (icser & flag.icser.sar1e != 0)
            1
        else if (icser & flag.icser.sar2e != 0)
            2
        else
            0;
        const address: u7 = @truncate(own[slot] >> bus.wire.addr_shift);
        if (bus.reserved.holds(address)) {
            self.unaddressed += 1;
            self.armed = false;
            self.phase = .idle;
            return;
        }
        self.own_address = address;
        self.armed = true;
        self.beginWrite();
    }

    fn beginWrite(self: *Target) void {
        self.phase = .writing;
        self.served = 0;
        self.status = flag.icsr2.rdrf;
    }

    fn beginRead(self: *Target) void {
        self.phase = .reading;
        self.echoed = 0;
        self.status = flag.icsr2.tdre | flag.icsr2.tend;
    }

    /// ICSR1: the own-address match, asserted while a phase is in flight.
    pub fn matched(self: *const Target) u8 {
        return switch (self.phase) {
            .writing, .reading => flag.icsr1.aas0,
            else => 0,
        };
    }

    /// ICCR2 in target mode: TRS only while the controller is reading.
    pub fn direction(self: *const Target, shadow: u8) u8 {
        const base = shadow & ~flag.iccr2.trs;
        return if (self.phase == .reading) base | flag.iccr2.trs else base;
    }

    /// ICDRR: the matched address byte first, the way the driver's dummy read
    /// expects, then the payload.
    pub fn receive(self: *Target) u8 {
        if (self.phase != .writing) return 0;
        const byte: u8 = if (self.served == 0)
            bus.wire.byte(self.own_address, false)
        else if (self.served <= script.payload.len)
            script.payload[self.served - 1]
        else
            0;
        self.served += 1;
        self.status = if (self.served > script.payload.len) flag.icsr2.stop else flag.icsr2.rdrf;
        return byte;
    }

    /// ICDRT: capture what the firmware echoes back. The controller wants
    /// exactly `script.payload.len` bytes, so it withholds the acknowledge on
    /// the last of them and stops. TDRE stays up because the shift register
    /// really did empty; NACKF is what the send loop tests, and leaving TDRE
    /// standing is what keeps the driver's next TDRE wait from spinning its
    /// whole budget to reach a conclusion NACKF already carries.
    pub fn transmit(self: *Target, byte: u8) void {
        if (self.phase != .reading) return;
        if (self.echoed < script.capture) self.captured[self.echoed] = byte;
        self.echoed += 1;
        if (self.echoed == script.payload.len) {
            self.status |= flag.icsr2.nackf | flag.icsr2.stop;
            self.nacked += 1;
        }
    }

    /// ICSR2 is write-0-to-clear, and the fall of the flag a phase was
    /// waiting on is what moves the script on: the receive path ends when the
    /// firmware clears the STOP the last payload byte raised, the transmit
    /// path when it clears the NACKF the controller's refusal raised. A store
    /// that clears neither leaves the phase where it was.
    pub fn acknowledge(self: *Target, value: u8) void {
        const before = self.status;
        self.status &= value;
        const fell = before & ~self.status;
        switch (self.phase) {
            .writing => if (fell & flag.icsr2.stop != 0) self.beginRead(),
            .reading => if (fell & flag.icsr2.nackf != 0) self.completeRead(),
            else => {},
        }
    }

    fn completeRead(self: *Target) void {
        if (self.echoed != script.payload.len or
            !std.mem.eql(u8, self.captured[0..self.echoed], &script.payload))
        {
            self.mismatched = true;
        }
        self.cycles += 1;
        if (self.cycles < script.cycles) {
            self.beginWrite();
        } else {
            self.phase = .done;
            self.status = 0;
        }
    }
};
