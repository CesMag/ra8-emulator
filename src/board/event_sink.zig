//! Board-to-session event sink contract (RA8EMU-192).
const reset = @import("ra8_chip").periph.reset;
const registry = @import("ra8_chip").periph.registry;

pub const Rect = struct { x: u16 = 0, y: u16 = 0, width: u16 = 0, height: u16 = 0 };

pub const Observation = struct {
    wdt_underflows: u32 = 0,
    wdt_refresh_errors: u32 = 0,
    iwdt_underflows: u32 = 0,
    glcdc_frames: u32 = 0,
    glcdc_width: u32 = 0,
    glcdc_height: u32 = 0,
    eink_refreshes: u32 = 0,
    eink_width: u32 = 0,
    eink_height: u32 = 0,
    eink_dirty: Rect = .{},
};

pub const EventSink = struct {
    context: *anyopaque,
    observeFn: *const fn (*anyopaque, registry.Issuer, u64, Observation) void,
    resetFn: *const fn (*anyopaque, registry.Issuer, reset.Source, u64) void,
};
