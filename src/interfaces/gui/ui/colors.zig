//! The GUI's themes (RA8EMU-961, after RA8EMU-1082 and RA8EMU-1136): every
//! chrome colour the shell, the bars and the panes paint, as named roles in a
//! `Theme`, with one baked-in value per palette. Panes take the active
//! `*const Theme` from the shell and read roles only, so adding a role is one
//! field plus one value per palette. Files under src/interfaces/gui never
//! write their own Color.rgb literals; tests/interfaces/gui/ui/colors_test.zig
//! keeps it that way, and contrast_test.zig holds every palette to WCAG AA.
//! The board picture (src/interfaces/render/board_view.zig), the LCD image and
//! colours computed from data are not chrome and stay where they are.
const draw_list = @import("ra8_render").draw_list;

const Color = draw_list.Color;
const rgb = Color.rgb;

/// The status strip's tones.
pub const Tones = struct { waiting: Color, good: Color, bad: Color, running: Color, halted: Color };

/// Marker hues for camera sources and the camera permission buttons.
pub const Hues = struct { blue: Color, purple: Color, green: Color, yellow: Color, red: Color };

pub const Theme = struct {
    background: Color,
    preview: Color,
    border: Color,
    ink: Color,
    /// Secondary text, at least 4.5:1 on every surface it is drawn on.
    muted: Color,
    face: Color,
    pressed_face: Color,
    button_face: Color,
    selected_face: Color,
    well: Color,
    gutter: Color,
    led_off: Color,
    /// The band behind the current line, the top frame and the field being edited.
    band: Color,
    /// Text on that band, and a value that just changed.
    highlight: Color,
    fitted_band: Color,
    accent: Color,
    bad: Color,
    good: Color,
    recording: Color,
    surface: Color,
    dirty_cell_bg: Color,
    pc_cyan: Color,
    pc_band_bg: Color,
    /// The disassembly breakpoint square.
    breakpoint: Color,
    step_active: Color,
    led_bezel: Color,
    led_specular: Color,
    ribbon_bg: Color,
    control_border: Color,
    status_pill: Color,
    hue: Hues,

    /// A register or byte that changed since the last stop.
    pub fn dirtyRegister(self: *const Theme) Color {
        return self.highlight;
    }

    pub fn runLit(self: *const Theme) Color {
        return self.good;
    }

    pub fn pauseLit(self: *const Theme) Color {
        return self.highlight;
    }

    pub fn tone(self: *const Theme) Tones {
        return .{ .waiting = self.muted, .good = self.good, .bad = self.bad, .running = self.accent, .halted = self.highlight };
    }
};

/// The board picture before its first frame arrives. The picture is the
/// board's own output, not chrome, so every theme shares it.
pub const unseen = rgb(0x00, 0x00, 0x00);

/// `system` follows the OS light or dark setting (RA8EMU-962).
pub const Choice = enum { dark, light, system };

/// The palette a theme choice paints with when the OS gives no answer:
/// System falls back to Light.
pub fn of(choice: Choice) *const Theme {
    return resolve(choice, false);
}

/// The palette `choice` paints with on an OS set to dark (`os_dark`) or not.
pub fn resolve(choice: Choice, os_dark: bool) *const Theme {
    return switch (choice) {
        .dark => &palettes.dark,
        .light => &palettes.light,
        .system => if (os_dark) &palettes.dark else &palettes.light,
    };
}

pub const palettes = struct {
    /// Cesar's Instrument Bench look (RA8EMU-1136): Tailwind slate surfaces
    /// with amber, emerald, sky and rose accents. The default.
    pub const dark: Theme = .{
        .background = rgb(0x0F, 0x11, 0x17),
        .preview = rgb(0x1B, 0x20, 0x2C),
        .border = rgb(0x28, 0x2E, 0x3C),
        .ink = rgb(0xF1, 0xF5, 0xF9),
        .muted = rgb(0x94, 0xA3, 0xB8),
        .face = rgb(0x1E, 0x24, 0x32),
        .pressed_face = rgb(0x33, 0x3E, 0x52),
        .button_face = rgb(0x27, 0x30, 0x41),
        .selected_face = rgb(0x22, 0x2C, 0x3D),
        .well = rgb(0x0A, 0x0C, 0x10),
        .gutter = rgb(0x0B, 0x0D, 0x12),
        .led_off = rgb(0x1A, 0x20, 0x2A),
        .band = rgb(0x1E, 0x2A, 0x38),
        .highlight = rgb(0xF5, 0x9E, 0x0B),
        .fitted_band = rgb(0x2E, 0x4A, 0x3A),
        .accent = rgb(0x38, 0xBD, 0xF8),
        .bad = rgb(0xEF, 0x44, 0x44),
        .good = rgb(0x10, 0xB9, 0x81),
        .recording = rgb(0xE0, 0x3C, 0x31),
        .surface = rgb(0x15, 0x19, 0x23),
        .dirty_cell_bg = rgb(0x2E, 0x24, 0x12),
        .pc_cyan = rgb(0x00, 0xE5, 0xFF),
        .pc_band_bg = rgb(0x10, 0x2A, 0x3C),
        .breakpoint = rgb(0xF4, 0x3F, 0x5E),
        .step_active = rgb(0x06, 0xB6, 0xD4),
        .led_bezel = rgb(0x18, 0x1F, 0x2B),
        .led_specular = rgb(0xFF, 0xFF, 0xFF),
        .ribbon_bg = rgb(0x13, 0x17, 0x20),
        .control_border = rgb(0x33, 0x3D, 0x4E),
        .status_pill = rgb(0x19, 0x20, 0x2C),
        .hue = .{
            .blue = rgb(0x5E, 0x81, 0xAC),
            .purple = rgb(0xB4, 0x8E, 0xAD),
            .green = rgb(0xA3, 0xBE, 0x8C),
            .yellow = rgb(0xEB, 0xCB, 0x8B),
            .red = rgb(0xBF, 0x61, 0x6A),
        },
    };

    /// The same roles on Tailwind slate-50 paper: slate-900 ink, slate-600
    /// secondary text, and the darker steps of amber, emerald, sky, cyan and
    /// rose so text and marks keep their contrast on a light surface.
    pub const light: Theme = .{
        .background = rgb(0xF8, 0xFA, 0xFC),
        .preview = rgb(0xF1, 0xF5, 0xF9),
        .border = rgb(0xCB, 0xD5, 0xE1),
        .ink = rgb(0x0F, 0x17, 0x2A),
        .muted = rgb(0x47, 0x55, 0x69),
        .face = rgb(0xE2, 0xE8, 0xF0),
        .pressed_face = rgb(0xCB, 0xD5, 0xE1),
        .button_face = rgb(0xE2, 0xE8, 0xF0),
        .selected_face = rgb(0xE0, 0xF2, 0xFE),
        .well = rgb(0xFF, 0xFF, 0xFF),
        .gutter = rgb(0xE2, 0xE8, 0xF0),
        .led_off = rgb(0xCB, 0xD5, 0xE1),
        .band = rgb(0xFE, 0xF3, 0xC7),
        .highlight = rgb(0x92, 0x40, 0x0E),
        .fitted_band = rgb(0xD1, 0xFA, 0xE5),
        .accent = rgb(0x03, 0x69, 0xA1),
        .bad = rgb(0xB9, 0x1C, 0x1C),
        .good = rgb(0x04, 0x78, 0x57),
        .recording = rgb(0xDC, 0x26, 0x26),
        .surface = rgb(0xF1, 0xF5, 0xF9),
        .dirty_cell_bg = rgb(0xFF, 0xFB, 0xEB),
        .pc_cyan = rgb(0x0E, 0x74, 0x90),
        .pc_band_bg = rgb(0xEC, 0xFE, 0xFF),
        .breakpoint = rgb(0xE1, 0x1D, 0x48),
        .step_active = rgb(0x0E, 0x74, 0x90),
        .led_bezel = rgb(0xCB, 0xD5, 0xE1),
        .led_specular = rgb(0xFF, 0xFF, 0xFF),
        .ribbon_bg = rgb(0xF1, 0xF5, 0xF9),
        .control_border = rgb(0x64, 0x74, 0x8B),
        .status_pill = rgb(0xE2, 0xE8, 0xF0),
        .hue = .{
            .blue = rgb(0x25, 0x63, 0xEB),
            .purple = rgb(0x93, 0x33, 0xEA),
            .green = rgb(0x16, 0xA3, 0x4A),
            .yellow = rgb(0xCA, 0x8A, 0x04),
            .red = rgb(0xDC, 0x26, 0x26),
        },
    };
};
