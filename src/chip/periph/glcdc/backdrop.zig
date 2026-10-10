//! The panel when only the background plane is on (RA8EMU-489). The output
//! stage composes BG x GR2 x GR1, so with BG_EN.EN set and the pixel clock
//! running the controller scans frames of the BG_BGC colour even when
//! neither graphics layer reads a byte. lcd_color_cycle drives the panel
//! this way. A layer that has RENB set but a descriptor this model cannot
//! believe is still refused as no layer: on silicon that fetch would
//! underflow, and painting the backdrop over it would hide the fault.

const glcdc = @import("glcdc.zig");
const scan = @import("scan.zig");
const mix = @import("mix.zig");

/// Whether either graphics layer has RENB set, believable or not.
pub fn anyLayerReading(unit: *const glcdc.Glcdc) bool {
    for (0..mix.layers) |index| {
        const at = glcdc.off.layer_base + glcdc.off.layer_stride * @as(u32, @intCast(index)) +
            glcdc.off.flmrd;
        if (unit.registers[at / 4] & glcdc.field.renb != 0) return true;
    }
    return false;
}

/// A frame of the background colour alone, or the refusal that explains
/// why there is none.
pub fn show(unit: *glcdc.Glcdc) ?scan.Picture {
    if (!unit.domain.powered()) return unit.scanner.refuseNoLayer();
    if (anyLayerReading(unit)) return unit.scanner.refuseNoLayer();
    if (!unit.outputEnabled()) return unit.scanner.refuseNoLayer();
    if (!unit.system.startFrame()) return unit.scanner.refuseUnclocked();
    const memory = unit.memory orelse return null;
    const panel = mix.Panel{
        .width = unit.panelWidth(),
        .height = unit.panelHeight(),
        .background = unit.registers[glcdc.off.bg_bgc / 4],
        .stage = &unit.output,
    };
    if (panel.width == 0 or panel.height == 0) return unit.scanner.refuseNoLayer();
    return switch (unit.mixer.run(memory, panel, &.{})) {
        .picture => |picture| unit.frameLanded(picture),
        .refused => |why| unit.scanner.refuseWith(why),
    };
}
