//! The USBHS controller's window: where it answers, and the names of the
//! registers and bits inside it.
//!
//! One place for the vocabulary, so the power machine, the pipe table, the
//! block and the tests all name the same thing. Offsets are the HUM Ch 37
//! register file, the same transcription the firmware's own driver uses.

/// Where the controller sits and how much of it this tree models.
pub const window = struct {
    pub const base: u32 = 0x4035_1000;
    /// The modelled span reaches past the device page to the PHY page
    /// (LPSTS at 0x102), which the bring-up writes.
    pub const span: u32 = 0x200;
    /// Every register in the window is 16 bits wide.
    pub const word: u32 = 2;
    pub const words: u32 = span / word;
};

/// Register offsets from the window base.
pub const reg = struct {
    pub const syscfg: u32 = 0x000;
    pub const buswait: u32 = 0x002;
    pub const syssts0: u32 = 0x004;
    pub const dvstctr0: u32 = 0x008;
    pub const cfifo: u32 = 0x014;
    pub const d0fifo: u32 = 0x018;
    pub const d1fifo: u32 = 0x01C;
    pub const cfifosel: u32 = 0x020;
    pub const cfifoctr: u32 = 0x022;
    pub const d0fifosel: u32 = 0x028;
    pub const d0fifoctr: u32 = 0x02A;
    pub const d1fifosel: u32 = 0x02C;
    pub const d1fifoctr: u32 = 0x02E;
    pub const intenb0: u32 = 0x030;
    pub const intenb1: u32 = 0x032;
    pub const intsts0: u32 = 0x040;
    pub const intsts1: u32 = 0x042;
    pub const brdysts: u32 = 0x046;
    pub const nrdysts: u32 = 0x048;
    pub const bempsts: u32 = 0x04A;
    pub const frmnum: u32 = 0x04C;
    pub const usbaddr: u32 = 0x050;
    pub const usbreq: u32 = 0x054;
    pub const usbval: u32 = 0x056;
    pub const usbindx: u32 = 0x058;
    pub const usbleng: u32 = 0x05A;
    pub const dcpcfg: u32 = 0x05C;
    pub const dcpmaxp: u32 = 0x05E;
    pub const dcpctr: u32 = 0x060;
    pub const pipesel: u32 = 0x064;
    pub const pipecfg: u32 = 0x068;
    pub const pipebuf: u32 = 0x06A;
    pub const pipemaxp: u32 = 0x06C;
    pub const pipeperi: u32 = 0x06E;
    pub const pipectr: u32 = 0x070;
    /// PIPECTR is an array of nine, PIPE1 through PIPE9.
    pub const pipectr_count: u32 = 9;
    /// PLLSTA sits in a reserved gap of the shared device-mode struct, at
    /// 0x006, and PHYSET in another at 0x03E. Both are named there in
    /// ra8_usb_regs.h (HUM Ch 37), and both are where the firmware's own
    /// bring-up reads and writes them.
    pub const pllsta: u32 = 0x006;
    pub const physet: u32 = 0x03E;
    /// The PHY page past the device model's span; per-window state.
    pub const phy_page: u32 = 0x100;
    pub const lpsts: u32 = 0x102;
};

/// SYSCFG: who this controller is and whether it is on at all.
pub const syscfg = struct {
    pub const usbe: u16 = 1 << 0;
    pub const dprpu: u16 = 1 << 4;
    pub const dcfm: u16 = 1 << 6;
    /// CNEN: the single-ended receiver. Without it the HS PHY cannot see the
    /// line at all (HUM Ch 37.2.1 p 2062).
    pub const cnen: u16 = 1 << 8;
    /// SCKE on USBFS. The HS instance has no such bit (HUM Ch 37.2.1 p 2060):
    /// it is kept only so a store of it can be dropped by name.
    pub const scke: u16 = 1 << 10;
};

/// SYSSTS0 line state, and the DVSTCTR0 port control the host drives.
pub const port = struct {
    /// SYSSTS0.LNST, the two bits that say what is on the wires. The
    /// encoding is HUM Ch 37.2.3 p 2063 and Table 37.4 p 2064, written out
    /// in ra8_usb_device.c's own g_syssts0_after_attach comment: 00b is
    /// SE0 (no pull-up visible), 01b is J-state, 10b is K-state (an HS
    /// chirp, or FS K). 11b is not a line state at all.
    pub const lnst_j: u16 = 0x0001;
    /// K-state. Nothing here drives a chirp yet, so no read answers this;
    /// it is named so the next slice does not have to guess the encoding.
    pub const lnst_k: u16 = 0x0002;
    pub const lnst_mask: u16 = 0x0003;
    /// DVSTCTR0.RHST, the speed the reset settled on.
    pub const rhst_mask: u16 = 0x0007;
    pub const rhst_full: u16 = 0x0002;
    pub const rhst_high: u16 = 0x0003;
    pub const usbrst: u16 = 1 << 6;
    pub const uact: u16 = 1 << 8;
    /// VBUSEN: the external VBUS switch on the USBHS jack. Nothing on the
    /// far end is powered until the host closes it (HUM Ch 37.2.5).
    pub const vbusen: u16 = 1 << 9;
};

/// PLLSTA: the PHY PLL's lock flag, which the bring-up spins on.
pub const pllsta = struct {
    pub const plllock: u16 = 0x0001;
};

/// PHYSET: the embedded PHY's analog power-down, its PLL reset, and which
/// reference clock the PLL takes off the EXTAL pin.
pub const physet = struct {
    pub const dirpd: u16 = 1 << 0;
    pub const pllreset: u16 = 1 << 1;
    pub const clksel_mask: u16 = 0x0030;
    pub const clksel_24: u16 = 0x0030;
};

/// LPSTS: SUSPENDM, which starts the PHY clock oscillating.
pub const lpsts = struct {
    pub const suspendm: u16 = 1 << 14;
};

/// The pipe table's shape and the fields the host programs into it.
pub const pipe = struct {
    /// DCP is pipe 0; PIPE1..PIPE9 follow.
    pub const count: u32 = 10;
    pub const epnum_mask: u16 = 0x000F;
    /// PIPECFG.DIR: set, the pipe transmits. On the host that is an OUT
    /// pipe; a pipe left clear receives, so a host IN pipe has it clear.
    pub const dir_transmit: u16 = 1 << 4;
    pub const maxp_mask: u16 = 0x07FF;
    /// The largest packet a high-speed bulk endpoint can carry.
    pub const maxp_limit: u16 = 512;
    pub const pid_mask: u16 = 0x0003;
    pub const pid_nak: u16 = 0;
    pub const pid_buf: u16 = 1;
    pub const pid_stall: u16 = 2;
};

/// CFIFOSEL / CFIFOCTR: which pipe the control FIFO port is aimed at.
pub const fifo = struct {
    pub const curpipe_mask: u16 = 0x000F;
    pub const isel: u16 = 1 << 5;
    pub const bclr: u16 = 1 << 6;
    pub const bval: u16 = 1 << 15;
    pub const frdy: u16 = 1 << 13;
    pub const dtln_mask: u16 = 0x0FFF;
};

/// DnFIFOSEL: the two data ports' own selector. It is not CFIFOSEL with a
/// different offset: there is no ISEL here, because a data port runs the
/// direction its pipe was configured for, and MBW says how wide an access
/// the port answers.
pub const dfifo = struct {
    /// How many data ports the controller has: D0FIFO and D1FIFO.
    pub const count: u32 = 2;
    pub const mbw_shift: u4 = 10;
    pub const mbw_mask: u16 = 0x3 << mbw_shift;
    pub const mbw_8: u16 = 0;
    pub const mbw_16: u16 = 1;
    pub const mbw_32: u16 = 2;
    pub const dreqe: u16 = 1 << 12;
    /// DCLRM: clear the buffer automatically at the end of a short packet.
    pub const dclrm: u16 = 1 << 13;

    /// The access width, in bytes, that MBW asks the port to answer.
    pub fn accessWidth(sel: u16) ?u3 {
        return switch ((sel & mbw_mask) >> mbw_shift) {
            mbw_8 => 1,
            mbw_16 => 2,
            mbw_32 => 4,
            else => null,
        };
    }
};

/// DCPCTR: the control pipe's own control register, and the two edges the
/// host drives a control transfer with.
pub const dcpctr = struct {
    pub const pid_mask: u16 = 0x0003;
    /// PID[1] is set for either STALL response, which is the bit the host's
    /// data-stage wait reads back (ra8_usb_internal.h k_ra8_usb_pid_stall_bit).
    pub const pid_stall: u16 = 0x0002;
    /// PID=BUF, the armed state the host re-arms the pipe with.
    pub const pid_buf: u16 = 0x0001;
    pub const ccpl: u16 = 1 << 2;
    /// SUREQCLR (HUM 37.2.24): the USBHS host's way to abort a wedged SETUP.
    /// SUREQ never latches here, so there is nothing for it to clear.
    pub const sureqclr: u16 = 1 << 11;
    /// SUREQ is bit 14 (HUM 37.2.24). Bit 6 is SQMON, read-only.
    pub const sureq: u16 = 1 << 14;
    pub const bsts: u16 = 1 << 15;
};

/// INTSTS1 bits the SIE raises on a control transfer.
pub const int1 = struct {
    pub const sack: u16 = 1 << 4;
    pub const sign: u16 = 1 << 5;
};

/// INTSTS0's summary bits, the mask ra8_usb_dispatch reads before it looks at
/// any per-pipe status register (ra8_usb_regs.h: k_ra8_int0_bit_brdy = 8,
/// k_ra8_int0_bit_nrdy = 9, k_ra8_int0_bit_bemp = 10).
pub const int0 = struct {
    pub const brdy: u16 = 1 << 8;
    pub const nrdy: u16 = 1 << 9;
    pub const bemp: u16 = 1 << 10;
};

/// BRDYSTS / NRDYSTS / BEMPSTS are one bit per pipe; bit 0 is the DCP.
pub const status = struct {
    pub const dcp: u16 = 1 << 0;
};

/// SETUP packet vocabulary: the wire fields and the direction bit.
pub const setup = struct {
    pub const len: u32 = 8;
    /// bmRequestType device-to-host (USB 2.0 section 9.3).
    pub const dir_in: u8 = 0x80;
};

/// How much this model stages on either side of the FIFO port.
pub const staging = struct {
    /// The largest packet a pipe carries, so the staging matches the wire.
    pub const packet_cap: u32 = 512;
    /// A control-read answer is a descriptor, not a payload.
    pub const reply_cap: u32 = 64;
};

/// True when the offset names a PIPECTR array slot.
pub fn isPipeCtr(offset: u32) bool {
    return offset >= reg.pipectr and
        offset < reg.pipectr + reg.pipectr_count * window.word;
}

/// Which pipe a PIPECTR offset names. PIPECTR[0] is PIPE1, so the index is
/// one higher than the slot.
pub fn pipeCtrIndex(offset: u32) u32 {
    return (offset - reg.pipectr) / window.word + 1;
}
