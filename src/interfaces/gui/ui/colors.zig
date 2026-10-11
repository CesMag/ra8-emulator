//! The GUI's one palette (RA8EMU-1082, ADR 0004 cleanup): every chrome colour
//! the shell, the bars and the panes paint, as named roles. Files under
//! src/interfaces/gui read from here instead of writing their own
//! Color.rgb literals; tests/interfaces/gui/ui/colors_test.zig keeps it that
//! way. The board picture (src/interfaces/render/board_view.zig), the LCD image and
//! colours computed from data are not chrome and stay where they are.
const draw_list = @import("ra8_render").draw_list;

const Color = draw_list.Color;
const palette = @This();

pub const background = Color.rgb(0x0F, 0x11, 0x17);
pub const preview = Color.rgb(0x1B, 0x20, 0x2C);
pub const border = Color.rgb(0x28, 0x2E, 0x3C);
pub const ink = Color.rgb(0xF1, 0xF5, 0xF9);
/// Secondary text: Tailwind slate-400, at least 4.5:1 on every surface it is drawn on.
pub const muted = Color.rgb(0x94, 0xA3, 0xB8);
pub const face = Color.rgb(0x1E, 0x24, 0x32);
pub const pressed_face = Color.rgb(0x33, 0x3E, 0x52);
pub const button_face = Color.rgb(0x27, 0x30, 0x41);
pub const selected_face = Color.rgb(0x22, 0x2C, 0x3D);
pub const well = Color.rgb(0x0A, 0x0C, 0x10);
pub const gutter = Color.rgb(0x0B, 0x0D, 0x12);
pub const black = Color.rgb(0x00, 0x00, 0x00);
pub const led_off = Color.rgb(0x1A, 0x20, 0x2A);
/// The band behind the current line, the top frame and the field being edited.
pub const band = Color.rgb(0x1E, 0x2A, 0x38);
/// Text on that band, and a value that just changed.
pub const highlight = Color.rgb(0xF5, 0x9E, 0x0B);
pub const fitted_band = Color.rgb(0x2E, 0x4A, 0x3A);
pub const accent = Color.rgb(0x38, 0xBD, 0xF8);
pub const bad = Color.rgb(0xEF, 0x44, 0x44);
pub const good = Color.rgb(0x10, 0xB9, 0x81);
pub const recording = Color.rgb(0xE0, 0x3C, 0x31);

// Semantic tokens for debugger data panes and controls
pub const surface = Color.rgb(0x15, 0x19, 0x23);
pub const pane_bg = Color.rgb(0x0F, 0x11, 0x17);
pub const dirty_register = Color.rgb(0xF5, 0x9E, 0x0B);
pub const dirty_cell_bg = Color.rgb(0x2E, 0x24, 0x12);
pub const pc_cyan = Color.rgb(0x00, 0xE5, 0xFF);
pub const pc_band_bg = Color.rgb(0x10, 0x2A, 0x3C);
pub const pc_band = pc_band_bg;
/// The disassembly breakpoint square: Tailwind rose-500.
pub const breakpoint = Color.rgb(0xF4, 0x3F, 0x5E);
pub const run_lit = Color.rgb(0x10, 0xB9, 0x81);
pub const pause_lit = Color.rgb(0xF5, 0x9E, 0x0B);
pub const step_active = Color.rgb(0x06, 0xB6, 0xD4);
pub const led_bezel = Color.rgb(0x18, 0x1F, 0x2B);
pub const led_specular = Color.rgb(0xFF, 0xFF, 0xFF);
pub const ribbon_bg = Color.rgb(0x13, 0x17, 0x20);
pub const control_border = Color.rgb(0x33, 0x3D, 0x4E);
pub const status_pill = Color.rgb(0x19, 0x20, 0x2C);

/// The status strip's tones.
pub const tone = struct {
    pub const waiting = muted;
    pub const good = palette.good;
    pub const bad = palette.bad;
    pub const running = palette.accent;
    pub const halted = palette.highlight;
};

/// Marker hues for camera sources and the camera permission buttons.
pub const hue = struct {
    pub const blue = Color.rgb(0x5E, 0x81, 0xAC);
    pub const purple = Color.rgb(0xB4, 0x8E, 0xAD);
    pub const green = Color.rgb(0xA3, 0xBE, 0x8C);
    pub const yellow = Color.rgb(0xEB, 0xCB, 0x8B);
    pub const red = Color.rgb(0xBF, 0x61, 0x6A);
};
