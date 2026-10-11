//! The transfer half of the host controller: a SETUP launched, a data stage
//! staged through the CFIFO, and a status stage completed.
//!
//! dev drove this from the register handler itself, bridging each step into a
//! second emulated part and raising BRDY and BEMP as soon as it had made the
//! call, so the polled host ran ahead of a device that had not answered yet.
//! Here the control transfer is a value with a state, the flags follow the
//! device, and a step the transfer is not in is refused.
//!
//! A SUREQ LAUNCH LATCHES EXACTLY ONE OUTCOME, SACK OR SIGN, and that is the
//! only thing the polled host can see. ra8_usb_host_ctrl.c's
//! internal_host_setup_wait W0C-clears both latches, asserts SUREQ, and then
//! spins on them: SACK returns ok, SIGN returns hw_error, and falling out of
//! the loop returns hw_timeout. Its own comment is blunt about why it cannot
//! watch SUREQ instead: "SUREQ self-clearing alone is NOT an ACK indication,
//! so gate on these." The loop is bound by k_ra8_usb_ctrl_poll_limit, which
//! is two million iterations.
//!
//! So a launch that latched nothing cost the driver that whole spin and then
//! reported a timeout, which is the wrong diagnosis twice over: it names the
//! clock rather than the bus, and it is the one outcome the HAL cannot tell
//! apart from a wedged controller. Both legs latch now:
//!
//!   SIGN when there was nothing on the bus to answer. That is what SIGN
//!   means on this part, per ra8_usb_regs.h: "SETUP transaction failed
//!   (3x)", three transmission attempts with no handshake back.
//!
//!   SACK the moment the token reaches something attached, BEFORE the
//!   request itself is judged. A SETUP token is ACKed at the token level by
//!   anything on the bus; a device that will not honour the request says so
//!   afterwards, in the stages that follow. So a refused request latches
//!   SACK too, and is counted as a stall on top.
//!
//! A REFUSED REQUEST PARKS THE DCP AT PID=STALL, which is how the refusal
//! reaches the driver at all. ra8_usb_host_ctrl.c's internal_host_dcp_in_wait
//! spins on BRDYSTS for the reply and checks DCPCTR against
//! k_ra8_usb_pid_stall_bit (0x0002, "PID[1]: set for either STALL") on every
//! turn of the loop, returning hw_error the moment it is up. Without it the
//! SACK from the token says go on, the reply never comes, and the driver
//! spends k_ra8_usb_ctrl_poll_limit before calling it a timeout. The bit is
//! the difference between "this device will not do that" and "this
//! controller is wedged", and only the first is true.
//!
//! The host clears it the way it clears any PID field, by storing a new PID
//! into DCPCTR: priv_dcp_pid(reg, k_ra8_pid_buf) re-arms the pipe. So the
//! stall survives reads and is dropped by the next write that names a
//! different PID, and a fresh SUREQ starts from whatever the host left.
//!
//! NOT MODELLED, AND NOT GUESSED: the bulk pipes' own STALL. Its reader
//! exists (internal_host_wait_pipe reads PIPECTR against the same bit) and
//! its own comment says the C host fake cannot raise it either, so nothing
//! in the tree says what stalls a bulk pipe here. Own slice, if an image
//! ever needs it.
//!
//! INTSTS0 IS THE DISPATCH MASK, not a spare shadow word. This model raised
//! BRDYSTS and BEMPSTS and left INTSTS0 reading back as a bare shadow word,
//! which is zero, so a driver dispatching on the mask saw an idle controller
//! on every turn no matter how many pipes had answers standing. BRDY and BEMP
//! now latch alongside their per-pipe bit; int.zig holds the latch and
//! says what the rest of the register is and is not.
const regs = @import("../regs.zig");
const usbhs_dfifo = @import("../dfifo.zig");
const usbhs_fifo = @import("../fifo.zig");
const usbhs_int = @import("../int.zig");
const usbhs_far = @import("../far.zig");
const usbhs_pipe = @import("../pipe.zig");
const usbhs_setup = @import("../setup.zig");
pub const loop = @import("loop.zig");

pub const Transfer = struct {
    port: usbhs_fifo.Port = .{},
    data: usbhs_dfifo.Ports = .{},
    /// The part on the far end, which the board plugs in: the echo device,
    /// or the self-loop cable. With none, nothing answers a token.
    far: ?usbhs_far.Far = null,

    /// The SETUP staging registers, as the host wrote them.
    usbreq: u16 = 0,
    usbval: u16 = 0,
    usbindx: u16 = 0,
    usbleng: u16 = 0,

    /// The request in flight, and which way its data stage runs.
    packet: usbhs_setup.Packet = .{},
    control_read: bool = false,
    in_flight: bool = false,

    brdy: u16 = 0,
    bemp: u16 = 0,
    intsts0: usbhs_int.Summary = .{},
    intsts1: u16 = 0,
    dcpctr: u16 = 0,

    setups: u32 = 0,
    stalls: u32 = 0,
    /// Steps refused, each for its own reason.
    no_device: u32 = 0,
    stray_ccpl: u32 = 0,
    /// OUT packets the device would not take, and the bytes still staged
    /// behind them. They are not gone: the host can send them again.
    refused_out: u32 = 0,
    refused_bytes: u32 = 0,
    /// Pipes whose BVAL landed while PID was still NAK. The buffer is valid
    /// and waits for the host to arm the pipe; it is not a refusal.
    held: u16 = 0,

    /// DCPCTR.SUREQ: send the staged SETUP. A token needs something on the
    /// bus that has been through a reset; dev delivered it whatever the port
    /// said, so an image that never reset the port enumerated in the
    /// emulator and found nothing on a bench.
    pub fn launch(self: *Transfer, live: bool) void {
        const far = self.far orelse return self.unanswered();
        if (!live) return self.unanswered();
        self.packet = usbhs_setup.Packet.fromRegisters(
            self.usbreq,
            self.usbval,
            self.usbindx,
            self.usbleng,
        );
        self.control_read = self.packet.controlRead();
        self.in_flight = true;
        self.setups += 1;
        self.port.in[0].clear();
        // The SIE latches SACK when the token is ACKed, which anything on
        // the bus does at the token level. Whether the request itself can be
        // honoured is a later question and a later stage.
        self.intsts1 |= regs.int1.sack;
        far.setup(loop.bytes(self.packet));
        // A far end that refuses at once is seen at once. The cable answers
        // only once its driver has run, so it is pending here and BRDYSTS
        // picks the answer up.
        if (far.answer() == .stall) self.stall();
    }

    /// Nothing on the bus handshook the token.
    fn unanswered(self: *Transfer) void {
        self.no_device += 1;
        self.intsts1 |= regs.int1.sign;
    }

    /// The far end refused the request: park the DCP at PID=STALL. The
    /// refusal has to be readable, or the driver's data-stage wait has
    /// nothing to break out on but the clock.
    pub fn stall(self: *Transfer) void {
        self.stalls += 1;
        self.in_flight = false;
        self.dcpctr = (self.dcpctr & ~regs.dcpctr.pid_mask) | regs.dcpctr.pid_stall;
    }

    /// A pipe has an answer standing: raise its BRDYSTS bit and the INTSTS0
    /// summary above it together, so a dispatcher and a poller see the same
    /// packet.
    pub fn raiseReady(self: *Transfer, bits: u16) void {
        self.brdy |= bits;
        self.intsts0.ready();
    }

    /// The mirror on the empty side: a staged buffer has gone out.
    pub fn raiseEmpty(self: *Transfer, bits: u16) void {
        self.bemp |= bits;
        self.intsts0.empty();
    }

    /// INTSTS0. The reply materialises on a read of the summary exactly as it
    /// does on a read of BRDYSTS, so a driver that only ever reads the mask
    /// still sees the packet arrive.
    pub fn interruptStatus(self: *Transfer, pipes: *usbhs_pipe.Table) u16 {
        _ = self.readyStatus(pipes);
        return self.intsts0.value();
    }

    /// W0C, the same shape as INTSTS1.
    pub fn clearInterrupt(self: *Transfer, value: u16) void {
        self.intsts0.ack(value);
    }

    /// DCPCTR.CCPL: the host closes the transfer. dev ran this on any write
    /// with the bit set, so a driver that left CCPL standing completed the
    /// same transfer on every store.
    pub fn complete(self: *Transfer) void {
        if (!self.in_flight) {
            self.stray_ccpl += 1;
            return;
        }
        self.in_flight = false;
        if (self.far) |far| far.statusStage();
        if (self.control_read) {
            self.raiseEmpty(regs.status.dcp);
            return;
        }
        self.port.in[0].clear();
        self.port.in[0].ready = true;
        self.raiseReady(regs.status.dcp);
    }

    /// BEMPSTS is where the polled host waits for its OUT packet to go. On
    /// the cable a packet the device NAKed is sent again here, as the SIE
    /// retries the token until the device takes it.
    pub fn emptyStatus(self: *Transfer, pipes: *usbhs_pipe.Table) u16 {
        if (self.far) |far| loop.empty(self, far, pipes);
        return self.bemp;
    }

    /// BRDYSTS is the register the polled host spins on, so it is where the
    /// device's answers become visible: a control-read reply, and a bulk-IN
    /// packet on any pipe the host has armed.
    pub fn readyStatus(self: *Transfer, pipes: *usbhs_pipe.Table) u16 {
        const far = self.far orelse return self.brdy;
        return loop.ready(self, far, pipes);
    }

    /// W0C, and a cleared bit re-arms that pipe for the next packet.
    pub fn clearReady(self: *Transfer, value: u16) void {
        self.brdy &= value;
    }

    /// CFIFOCTR.BVAL: hand the staged OUT bytes to the device. A pipe the
    /// host has not armed moves nothing: dev committed whatever PIPECTR
    /// said, so a packet went out on a pipe the driver had left NAKing.
    pub fn commit(self: *Transfer, pipes: *usbhs_pipe.Table) void {
        const index = self.port.pipe() orelse {
            self.port.bad_pipe += 1;
            return;
        };
        self.commitPipe(index, pipes);
    }

    /// Hand one pipe's staged OUT bytes to the device, whichever port staged
    /// them. A pipe the host has not armed moves nothing: dev committed
    /// whatever PIPECTR said, so a packet went out on a pipe the driver had
    /// left NAKing.
    ///
    /// The buffer is emptied by the device taking it, never before. A device
    /// that refuses the packet, because it is not configured and has no bulk
    /// endpoint yet, leaves the bytes where the host put them: BEMP stays
    /// down, and the same BVAL after enumeration sends the same packet. The
    /// buffer was drained ahead of the answer before, so a refused packet was
    /// gone from both ends at once and the retry sent nothing.
    fn commitPipe(self: *Transfer, index: u32, pipes: *usbhs_pipe.Table) void {
        if (index != 0 and !pipes.pipes[index].armed()) {
            self.held |= @as(u16, 1) << @intCast(index);
            return;
        }
        const staging = &self.port.out[index];
        if (staging.len == 0) return;
        if (index == 0) {
            staging.clear();
            self.raiseEmpty(regs.status.dcp);
            return;
        }
        const sent = if (self.far) |far|
            far.bulkOut(@truncate(pipes.pipes[index].endpoint), staging.staged())
        else
            false;
        if (!sent) {
            self.refused_out += 1;
            self.refused_bytes +%= staging.len;
            return;
        }
        staging.clear();
        self.raiseEmpty(@as(u16, 1) << @intCast(index));
    }

    /// PIPEnCTR was written. The HAL marks a packet valid with BVAL and only
    /// then turns PID to BUF, so a held packet goes out the moment its pipe
    /// is armed, the way the SIE sends a valid buffer on the next token.
    pub fn pipeArmed(self: *Transfer, index: u32, pipes: *usbhs_pipe.Table) void {
        if (index == 0 or index >= regs.pipe.count) return;
        const bit = @as(u16, 1) << @intCast(index);
        if (self.held & bit == 0 or !pipes.pipes[index].armed()) return;
        self.held &= ~bit;
        self.commitPipe(index, pipes);
    }

    pub fn clearEmpty(self: *Transfer, value: u16) void {
        self.bemp &= value;
    }

    /// DnFIFOSEL. The CFIFO's own aim is passed in so the pair can refuse a
    /// data port aimed at the pipe the control port already holds.
    pub fn selectData(self: *Transfer, which: u32, value: u16) void {
        self.data.select(which, value, self.port.pipe());
    }

    /// DnFIFOCTR. A port aimed at nothing is never ready, and the length it
    /// reports is what its pipe's staging actually holds.
    pub fn dataStatus(self: *Transfer, which: u32, pipes: *usbhs_pipe.Table) u16 {
        const index = self.data.ports[which].pipe() orelse return 0;
        if (!pipes.pipes[index].in) return regs.fifo.frdy;
        const staging = &self.port.in[index];
        if (!staging.ready) return 0;
        return regs.fifo.frdy | (staging.remaining() & regs.fifo.dtln_mask);
    }

    /// A host load from a data port. Three gates the control port does not
    /// have: the access width MBW asked for, the direction the pipe was
    /// configured for, and DCLRM taking the buffer away once it runs dry.
    pub fn readData(self: *Transfer, which: u32, access: u3, pipes: *usbhs_pipe.Table) u32 {
        const index = self.data.ports[which].pipe() orelse {
            self.data.ports[which].bad_pipe += 1;
            return 0;
        };
        if (!self.data.accepts(which, access)) return 0;
        if (!self.data.runs(which, pipes.pipes[index].in, true)) return 0;
        const staging = &self.port.in[index];
        if (!staging.ready) {
            self.port.not_ready += 1;
            return 0;
        }
        const value = usbhs_fifo.drainWord(staging, access, &self.port.overdrain);
        if (!staging.ready and self.data.ports[which].autoClears()) staging.clear();
        return value;
    }

    /// A host store into a data port, staged against the pipe's own maximum
    /// packet size rather than the control pipe's reply cap.
    pub fn writeData(self: *Transfer, which: u32, access: u3, value: u32, pipes: *usbhs_pipe.Table) void {
        const index = self.data.ports[which].pipe() orelse {
            self.data.ports[which].bad_pipe += 1;
            return;
        };
        if (!self.data.accepts(which, access)) return;
        if (!self.data.runs(which, pipes.pipes[index].in, false)) return;
        usbhs_fifo.fillWord(
            &self.port.out[index],
            value,
            access,
            pipes.pipes[index].maxp,
            &self.port.oversize,
        );
    }

    /// DnFIFOCTR: BCLR throws the aimed-at side away, BVAL hands a staged
    /// OUT packet to the device, the same two edges CFIFOCTR carries.
    pub fn dataControl(self: *Transfer, which: u32, value: u16, pipes: *usbhs_pipe.Table) void {
        const index = self.data.ports[which].pipe() orelse {
            self.data.ports[which].bad_pipe += 1;
            return;
        };
        if (value & regs.fifo.bclr != 0) {
            if (pipes.pipes[index].in) self.port.in[index].clear() else self.port.out[index].clear();
        }
        if (value & regs.fifo.bval != 0) self.commitPipe(index, pipes);
    }

    /// USBRST released: the device drops back to Default and every staged
    /// packet on the bus goes with it.
    pub fn busReset(self: *Transfer) void {
        if (self.far) |far| far.busReset();
        self.in_flight = false;
        self.brdy = 0;
        self.bemp = 0;
        self.intsts0.busReset();
        for (&self.port.in) |*staging| staging.clear();
        for (&self.port.out) |*staging| staging.clear();
        self.held = 0;
        self.data.release();
    }

    pub fn refusals(self: *const Transfer) u32 {
        return self.no_device + self.stray_ccpl + self.stalls +
            self.refused_out + self.port.refusals() + self.data.refusals();
    }

    pub fn quiet(self: *const Transfer) bool {
        return self.setups == 0 and self.refusals() == 0 and self.port.quiet() and
            self.data.quiet();
    }
};
