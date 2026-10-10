//! The emulated RA8D2 address space.
//!
//! The regions are silicon facts, so they are
//! constants here, not options.
//!
//! THE NON-SECURE ALIAS IS PART OF THE MAP, not a detail of TrustZone. The
//! IDAU on this part splits the space by address bit 28: the Secure view of a
//! region and the Non-secure view of the same bytes sit 0x1000_0000 apart, so
//! a permanent-Non-secure initiator reaches SRAM at 0x3200_0000 rather than at
//! 0x2200_0000. The firmware states that bit three times over. The peripheral
//! window's pair is already named in src/chip/periph/registry.zig
//! (`ns_offset`, 0x4000_0000 and 0x5000_0000), and `cpu1_pingpong_ipc`'s own
//! CPU1 image names both of the other two: `k_cpu1_sau_periph_ns_base`
//! 0x5000_0000, and an SAU Non-secure SRAM window it then writes through at
//! 0x3210_0200.
//!
//! SDRAM's alias was mapped here from the start and SRAM's was not, which is
//! the gap this note exists to record. CPU1 in `cpu1_pingpong_ipc` is a
//! permanent-Non-secure controller, so every marker it writes goes through
//! the alias, and its first one (`k_cpu1_probe_reset_addr`, 0x3210_0200,
//! written at the top of the reset handler) landed nowhere: the run ended on
//! an unmapped store four instructions into the image, before the SAU was
//! programmed and before anything of the ping-pong ran. Both aliases are now
//! derived from one named offset rather than one of them being a literal and
//! the other missing.
//!
//! AN ALIAS IS THE SAME BYTES, and `alias_of` below is what says so. When the
//! alias was first mapped it was a region of its own with its own backing
//! store, so a marker written through 0x3210_0200 was not there at
//! 0x2210_0200 and cpu1_main.c's own description of the two views as "the
//! same backing store" was false here. src/chip/core/cpu/memory/store.zig now puts
//! both views of a region over one host allocation, so the alias aliases.
//!
//! DTCM's alias is deliberately not mapped. The rule would place it at
//! 0x3000_0000, but the core's tightly coupled memory is reached over the
//! CPU's private port and nothing in the tree or the corpus asks for it
//! there, so mapping it would be following the arithmetic past the evidence.
const std = @import("std");

pub const Region = struct {
    name: []const u8,
    base: u32,
    size: u32,
    perms: Perms,

    pub const Perms = packed struct {
        read: bool = true,
        write: bool = true,
        exec: bool = true,
    };

    pub fn end(self: Region) u64 {
        return @as(u64, self.base) + self.size;
    }
};

/// M85 instruction tightly coupled memory (HUM 2.1.1), where the firmware
/// linker scripts place it. NOT MAPPED: on the EK-RA8D2 a data read at 0 takes
/// a precise BusFault (BFAR 0, RA8EMU-495), so an access here is refused and
/// raises the same fault. No firmware places code or data in it. The startup
/// copy that read here (RA8EMU-426) was the empty-.sram_text bug, RA8FW-549.
pub const itcm_base: u32 = 0x0000_0000;
pub const itcm_end: u32 = itcm_base + 0x0001_0000;

/// The 1 MB of code MRAM. src/chip/core/part_map.zig gives its size for both
/// parts. The board maps the whole array, so a read anywhere in it lands,
/// as it does on silicon. A Secure boot that copies a fixed-size window out
/// of it (secure_boot_ns_hil copies 64 KB of the Non-Secure image) reads
/// past the bytes the ELF loads. Unprogrammed cells read as the CPU model's
/// reset fill (zero). The documentation found so far does not name a value
/// for them.
pub const mram_base: u32 = 0x0200_0000;
pub const mram_end: u32 = 0x0210_0000;
pub const dtcm_base: u32 = 0x2000_0000;
pub const dtcm_end: u32 = 0x2001_0000;
pub const sram_base: u32 = 0x2200_0000;
/// The on-chip system SRAM runs to 0x221A_0000, not to the 0x2210_0000 a
/// 1 MB part would give: it is SRAM0's 1024 KB plus SRAM1's 640 KB, 1664 KB
/// in one contiguous ECC-backed block, and it is the same size on both
/// parts. The firmware states it twice, at ra8_device.h
/// `k_ra8_mem_sram_size = 0x001A0000U` ("1664 KB system SRAM (both parts)")
/// and in every app linker script's SRAM region. The upper 640 KB is what
/// an RA8D2 script calls NS_SRAM at 0x2210_0000: a Non-secure alias
/// placeholder over the same physical bytes, not a separate memory, which
/// is why one region covers it rather than two.
pub const sram_end: u32 = 0x221A_0000;
pub const sdram_base: u32 = 0x6800_0000;
pub const sdram_end: u32 = 0x6C00_0000;

/// How far above a Secure region its Non-secure alias sits: IDAU address
/// bit 28. src/chip/periph/registry.zig carries the same offset for the
/// peripheral window, where it folds the alias onto the Secure address so
/// one model answers both; a memory region cannot be folded that way, so
/// each alias is its own region here.
pub const ns_offset: u32 = 0x1000_0000;

/// The Non-secure view of the system SRAM, which is where a
/// permanent-Non-secure initiator writes.
pub const ns_sram_base: u32 = sram_base + ns_offset;
pub const ns_sram_end: u32 = ns_sram_base + (sram_end - sram_base);
pub const ns_sdram_base: u32 = sdram_base + ns_offset;
pub const ns_sdram_end: u32 = ns_sdram_base + (sdram_end - sdram_base);
/// The Non-secure view of code MRAM, where the firmware links its Non-secure
/// image: the IDAU keeps every bit-28-clear address Secure (RA8FW-510). Code
/// MRAM is per engine rather than shared, so this view is not in `alias_of`;
/// the store maps it onto the engine's own MRAM pages (RA8EMU-412).
pub const ns_mram_base: u32 = mram_base + ns_offset;
pub const ns_mram_end: u32 = ns_mram_base + (mram_end - mram_base);

/// A Non-secure view and the Secure region whose bytes it is. Both entries
/// of a pair appear in `ram` as regions in their own right, because the CPU
/// model maps guest addresses and there are two of them; this table is what
/// says the two share one backing store, and src/chip/core/cpu/memory/store.zig
/// is what honours it.
pub const View = struct {
    view: u32,
    of: u32,
};

pub const alias_of = [_]View{
    .{ .view = ns_sram_base, .of = sram_base },
    .{ .view = ns_sdram_base, .of = sdram_base },
};

/// The Cortex-M Private Peripheral Bus: SCB, NVIC, SysTick, MPU, SAU and the
/// debug block. The C emulator maps this as plain RAM rather than callback
/// MMIO, so a write lands and a read gives it back. Several of the registers
/// the firmware touches (VTOR, SHPRn, MPU_RBAR/RLAR) are read back by the very
/// code that wrote them, and that is the behaviour plain RAM gives for free.
pub const ppb_base: u32 = 0xE000_0000;
pub const ppb_size: u32 = 0x0010_0000;

/// RAM and flash-like regions the loader maps before an image is streamed in.
pub const ram = [_]Region{
    .{ .name = "MRAM", .base = mram_base, .size = mram_end - mram_base, .perms = .{} },
    .{ .name = "NS MRAM", .base = ns_mram_base, .size = ns_mram_end - ns_mram_base, .perms = .{} },
    .{ .name = "DTCM", .base = dtcm_base, .size = dtcm_end - dtcm_base, .perms = .{} },
    .{ .name = "SRAM", .base = sram_base, .size = sram_end - sram_base, .perms = .{} },
    .{ .name = "NS SRAM", .base = ns_sram_base, .size = ns_sram_end - ns_sram_base, .perms = .{} },
    .{ .name = "SDRAM", .base = sdram_base, .size = sdram_end - sdram_base, .perms = .{} },
    .{ .name = "NS SDRAM", .base = ns_sdram_base, .size = ns_sdram_end - ns_sdram_base, .perms = .{} },
    .{ .name = "PPB", .base = ppb_base, .size = ppb_size, .perms = .{ .exec = false } },
};

/// Register addresses inside the PPB the rest of the emulator names. They are
/// architectural, so they are constants rather than options.
pub const scb = struct {
    pub const icsr: u32 = 0xE000_ED04;
    pub const vtor: u32 = 0xE000_ED08;
    /// The Non-Secure view of the vector base, at the SCB_NS alias. The
    /// secure boot writes the Non-Secure vector table's base here right
    /// before it hands the world over, so it is where the Non-Secure stack
    /// and reset handler can be found.
    pub const vtor_ns: u32 = 0xE002_ED08;
    pub const aircr: u32 = 0xE000_ED0C;
    pub const ccr: u32 = 0xE000_ED14;
    /// SHPR1 holds the configurable fault priorities: MemManage in its low
    /// byte, then BusFault and UsageFault above it.
    pub const shpr1: u32 = 0xE000_ED18;
    pub const shpr2: u32 = 0xE000_ED1C;
    pub const shpr3: u32 = 0xE000_ED20;
    /// SHCSR: SHCSR.MEMFAULTENA [16] is what enables MemManage at all. With
    /// it clear the fault is disabled and escalates to HardFault instead.
    pub const shcsr: u32 = 0xE000_ED24;
    pub const cfsr: u32 = 0xE000_ED28;
    /// HFSR: HFSR.FORCED [30] says the HardFault is an escalated one rather
    /// than a fault of its own.
    pub const hfsr: u32 = 0xE000_ED2C;
    pub const mmfar: u32 = 0xE000_ED34;
    pub const bfar: u32 = 0xE000_ED38;
    /// AFSR: IMPLEMENTATION DEFINED auxiliary fault status, write one to
    /// clear (src/chip/periph/afsr.zig says which bits this model raises).
    pub const afsr: u32 = 0xE000_ED3C;
    pub const demcr: u32 = 0xE000_EDFC;
};

/// The Armv8-M Memory Protection Unit window. TYPE is read-only and reports
/// how many data regions the core implements; RNR selects one and RBAR/RLAR
/// program it, with three alias pairs that reach the following regions without
/// another RNR write. Architectural, so constants like the rest of the PPB.
/// The Armv8-M Security Attribution Unit window, the third PPB block this
/// model answers for after the MPU and the cache maintenance one. TYPE is
/// hardwired and reports how many regions the core implements; RNR picks
/// which one RBAR/RLAR reach. Architectural addresses, so constants.
pub const sau = struct {
    pub const ctrl: u32 = 0xE000_EDD0;
    pub const type_: u32 = 0xE000_EDD4;
    pub const rnr: u32 = 0xE000_EDD8;
    pub const rbar: u32 = 0xE000_EDDC;
    pub const rlar: u32 = 0xE000_EDE0;
};

pub const mpu = struct {
    pub const type_: u32 = 0xE000_ED90;
    pub const ctrl: u32 = 0xE000_ED94;
    pub const rnr: u32 = 0xE000_ED98;
    pub const rbar: u32 = 0xE000_ED9C;
    pub const rlar: u32 = 0xE000_EDA0;
    pub const rbar_a1: u32 = 0xE000_EDA4;
    pub const rlar_a1: u32 = 0xE000_EDA8;
    pub const rbar_a2: u32 = 0xE000_EDAC;
    pub const rlar_a2: u32 = 0xE000_EDB0;
    pub const rbar_a3: u32 = 0xE000_EDB4;
    pub const rlar_a3: u32 = 0xE000_EDB8;
    pub const mair0: u32 = 0xE000_EDC0;
    pub const mair1: u32 = 0xE000_EDC4;
};

/// The Arm v8-M cache maintenance window, the other half of the SCB the
/// firmware drives. CTR and CCSIDR report the geometry and are read-only;
/// CSSELR picks which cache CCSIDR describes; the rest are write-only
/// maintenance ports. Architectural, so constants like the rest of the PPB.
pub const cache = struct {
    pub const ctr: u32 = 0xE000_ED7C;
    pub const ccsidr: u32 = 0xE000_ED80;
    pub const csselr: u32 = 0xE000_ED84;
    pub const iciallu: u32 = 0xE000_EF50;
    pub const dcimvac: u32 = 0xE000_EF5C;
    pub const dcisw: u32 = 0xE000_EF60;
    pub const dccmvac: u32 = 0xE000_EF68;
    pub const dccimvac: u32 = 0xE000_EF70;
    pub const dccisw: u32 = 0xE000_EF74;
};

/// The SysTick block. Architectural on every Cortex-M, so these are constants
/// like the rest of the PPB.
pub const syst = struct {
    pub const csr: u32 = 0xE000_E010;
    pub const rvr: u32 = 0xE000_E014;
    pub const cvr: u32 = 0xE000_E018;
    pub const calib: u32 = 0xE000_E01C;
};

/// The NVIC's register file. Set and clear registers are separate on
/// hardware, and against a plain-RAM PPB both are just words:
/// src/chip/periph/nvic.zig folds the clear side into the set side at the
/// chunk boundary.
pub const nvic = struct {
    pub const iser: u32 = 0xE000_E100;
    pub const icer: u32 = 0xE000_E180;
    pub const ispr: u32 = 0xE000_E200;
    pub const icpr: u32 = 0xE000_E280;
    pub const iabr: u32 = 0xE000_E300;
    pub const ipr: u32 = 0xE000_E400;
};

/// The Data Watchpoint and Trace unit. Only the free-running cycle counter and
/// its enable are named: that counter is the time base the firmware spins on
/// with interrupts masked, which is the whole reason the emulator models it.
pub const dwt = struct {
    pub const ctrl: u32 = 0xE000_1000;
    pub const cyccnt: u32 = 0xE000_1004;
};

/// A span of addresses, as a base and the first address past it.
pub const Window = struct {
    base: u32,
    end: u32,

    /// Whether `len` bytes at `at` lie wholly inside this window.
    pub fn holds(self: Window, at: u32, len: u32) bool {
        return at >= self.base and @as(u64, at) + len <= @as(u64, self.end);
    }
};

/// The RAM a bus initiator other than the CPU can reach: the on-chip SRAM and
/// the external SDRAM, each through both its Secure and its Non-secure view.
///
/// DTCM is deliberately not here. It is the core's own tightly coupled
/// memory, reached over the CPU's private port rather than over the fabric
/// the descriptor engines and the drawing engine issue on, so a ring or a
/// texture pointed into it is a programming bug on the bench as much as it
/// is here. The peripheral window is not here either, for the same reason it
/// never was: it is registers, not somewhere a frame may be read out of or
/// written into.
pub const initiator_ram = [_]Window{
    .{ .base = sram_base, .end = sram_end },
    .{ .base = ns_sram_base, .end = ns_sram_end },
    .{ .base = sdram_base, .end = sdram_end },
    .{ .base = ns_sdram_base, .end = ns_sdram_end },
};

/// The RAM a debug probe can read and write over the debug port: every
/// region the loader maps as RAM, the core's own TCM included. The probe
/// is not a bus initiator on the fabric, it reaches memory through the core,
/// so the `initiator_ram` exclusions do not apply to it. The peripheral window
/// is still not here: registers are not somewhere a log ring lives.
pub const debug_ram = [_]Window{
    .{ .base = dtcm_base, .end = dtcm_end },
    .{ .base = sram_base, .end = sram_end },
    .{ .base = ns_sram_base, .end = ns_sram_end },
    .{ .base = sdram_base, .end = sdram_end },
    .{ .base = ns_sdram_base, .end = ns_sdram_end },
};

/// Whether a span of `len` bytes at `at` is RAM a debug probe may read or
/// write. A model that follows a pointer out of a structure the firmware
/// published for a probe asks this rather than `initiatorHolds`.
pub fn debugHolds(at: u32, len: u32) bool {
    if (len == 0) return false;
    for (debug_ram) |window| {
        if (window.holds(at, len)) return true;
    }
    return false;
}

/// Whether a span of `len` bytes at `at` is somewhere a bus initiator may read
/// or write. A model that follows a pointer the firmware gave it asks this
/// first, because a half-built descriptor points anywhere.
pub fn initiatorHolds(at: u32, len: u32) bool {
    if (len == 0) return false;
    for (initiator_ram) |window| {
        if (window.holds(at, len)) return true;
    }
    return false;
}

/// The window an address sits in, or null when it sits in none. A model
/// that walks forward from a base it was handed (a scan-out down a
/// framebuffer, a walk along a ring) asks this instead of `initiatorHolds`,
/// because it needs to know where the room runs out, not only that the
/// first byte is in it.
pub fn initiatorWindow(at: u32) ?Window {
    for (initiator_ram) |window| {
        if (at >= window.base and at < window.end) return window;
    }
    return null;
}

/// The page size the part's regions are aligned to.
pub const page: usize = 0x1000;

/// Whether a span of `len` bytes at `base` lies wholly inside one of the
/// part's RAM regions in `ram`. A span running off a region's end is not.
pub fn coversRam(base: u32, len: u32) bool {
    for (ram) |region| {
        if (base >= region.base and @as(u64, base) + len <= region.end()) return true;
    }
    return false;
}
