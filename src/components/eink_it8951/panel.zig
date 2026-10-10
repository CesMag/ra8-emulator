//! The IT8951 e-paper controller on the SPI line: the word protocol a panel
//! answers, and the difference between a panel that is awake and one the
//! firmware put to sleep.
//!
//! The driver clocks bytes through SPDR and the controller assembles them
//! into 16-bit words MSB first. Every transaction opens with a preamble
//! word: command follows, data follows, or the host is about to read. A read
//! burst is four bytes, a dummy word and then the value, which is what the
//! driver's read_data16 takes. There is no chip select in this tree, so the
//! panel self-frames off those preambles, which is what dev does too.
//!
//! Ported from board_periph_eink.c on dev, with five things that model does
//! not do.
//!
//! A COMMAND NEEDS AN AWAKE PANEL. dev declares SYS_RUN and SLEEP in its own
//! command enum and implements neither, so an image that puts the panel into
//! deep sleep and then loads and refreshes gets a full report there and a
//! blank panel on the bench. Here SLEEP stops the controller answering:
//! every command but SYS_RUN is refused and counted until the firmware wakes
//! it back up.
//!
//! A REGISTER KEEPS WHAT WAS WRITTEN. dev latches the address of a REG_WR
//! and throws the value away, and answers zero to every register read, so a
//! driver that programs a register and reads it back to confirm reads zero
//! forever and cannot tell a dead bus from a working one. Here a written
//! register reads back, and LUTAFSR stays the controller's own: a write to
//! it is refused and counted, and a read of it is always the idle status the
//! display poll is waiting for.
//!
//! A LOAD IS BOUNDED BY THE RECTANGLE IT DECLARED. dev counts pixels for
//! every data word after the geometry and never looks at the width and
//! height it just took, so a stream longer than its own target area reads as
//! a clean load there and overruns the area on silicon. Here the rectangle
//! is latched and a word past it moves no pixels and is counted.
//!
//! THE DEVICE-INFO BLOCK ENDS. dev increments its cursor on every read burst
//! for as long as the host keeps clocking and answers zeros past the end of
//! the forty-byte block, so a driver draining too far is told it is still
//! reading device information. Here the block is twenty words and a read
//! past it is counted.
//!
//! A DATA WORD NEEDS A COMMAND IN FLIGHT. dev's data path falls through
//! every branch when no command has arrived, so a stray write preamble in
//! the middle of a transaction is swallowed in silence. Here it is counted,
//! which is how a framing slip shows up in the report at all.
//!
//! KEPT FROM DEV DELIBERATELY: the self-framing itself, the dummy word ahead
//! of every value, the 1530 mV power-on VCOM (a modelled controller value,
//! not any real panel's), and the pixels-per-
//! word decode, which is why a load at 4 bpp accounts four pixels to a word
//! and not two.
//!
//! THE PANEL IS ON SPI_B CHANNEL 0, where the epaper app's k_ep_spi_channel
//! puts it. The card is on SCI0 in Simple-SPI mode, not on SPI_B, so
//! nothing else shares the line and no chip select is needed.
//!
//! NOT MODELLED, AND NOT GUESSED: physical waveform transformations (a
//! refresh copies the requested area from the input buffer to the glass),
//! the image-buffer address, the panel's own busy timing (HRDY is driven
//! ready and stays there), and every register besides LUTAFSR, which are
//! shadowed and never interpreted.
const std = @import("std");
const proto = @import("wire.zig");
const busy = @import("busy.zig");
const image = @import("image.zig");
const refresh = @import("refresh.zig");
const spi = @import("ra8_chip").periph.spi;
/// The LUT busy model, re-exported so a caller reaches it through the
/// panel rather than by a second import.
pub const lut = busy;
/// Which SPI_B channel the panel is wired to. The model's own rule; see the
/// header.
pub const line_channel: usize = 0;
/// The panel's ready line, driven from the board so an HRDY poll reads a
/// level rather than a floating zero. Matches the epaper app's busy pin.
pub const hrdy = struct {
    pub const port: u8 = 4;
    pub const pin: u4 = 1;
};
/// How many host registers the model keeps. Small on purpose: the driver
/// touches a handful, and one nothing ever wrote reads zero anyway.
pub const register_slots: usize = 8;
/// What the next assembled word means.
const State = enum { preamble, command, data };
const Register = struct {
    address: u16 = 0,
    value: u16 = 0,
};
pub const Panel = struct {
    pub const EventHook = struct { context: *anyopaque, refreshFn: *const fn (*anyopaque, *const Panel) void };
    state: State = .preamble,
    /// A high byte is latched and waiting for the low byte behind it.
    high: ?u8 = null,
    burst: proto.Burst = .{},
    /// The command in flight, and how many of its data words have arrived.
    command: ?proto.Command = null,
    data_index: u32 = 0,
    /// The command in flight was refused. Its data words are its own and the
    /// refusal has already been counted, so they are dropped without being
    /// counted again as strays.
    refusing: bool = false,
    /// Awake until the firmware issues SLEEP.
    awake: bool = true,
    registers: [register_slots]Register = @splat(Register{}),
    register_count: usize = 0,
    reg_address: u16 = 0,
    vcom_direction: u16 = 0,
    vcom_mv: u16 = proto.vcom.power_on_mv,
    info_index: u16 = 0,

    /// The rectangle the load in flight declared, and the pixels left in it.
    load_width: u16 = 0,
    load_height: u16 = 0,
    load_x: u16 = 0,
    load_y: u16 = 0,
    load_left: u32 = 0,
    pixels_per_word: u16 = 2,
    load_mode: u16 = 0,
    planes: image.Planes = .{},
    refresh_hook: ?image.RefreshHook = null,
    refresh_log_hook: ?refresh.LogHook = null,
    event_hook: ?EventHook = null,
    loaded_pixels: u32 = 0,
    display_args: [5]u16 = @splat(0),
    /// The film: busy while a refresh is still being driven.
    film: busy.Lut = .{},
    /// Commands the panel took.
    commands: u32 = 0,
    /// Pixels streamed into a load, and refreshes asked for.
    pixels: u64 = 0,
    refreshes: u32 = 0,
    last_waveform: u16 = 0,
    /// Commands refused because the panel was asleep.
    asleep: u32 = 0,
    /// Pixel words past the end of the declared rectangle.
    overrun: u32 = 0,
    /// Device-info reads past the end of the block.
    overdrain: u32 = 0,
    /// Data words with no command in flight.
    stray: u32 = 0,
    /// Writes to a register the controller owns.
    read_only: u32 = 0,
    /// Register writes dropped because the table is full.
    spilled: u32 = 0,

    pub fn init() Panel {
        return .{};
    }

    pub fn deinit(self: *Panel) void {
        self.planes.deinit();
    }

    pub fn quiet(self: *const Panel) bool {
        return self.commands == 0 and self.stray == 0 and self.asleep == 0 and self.film.quiet();
    }

    /// One byte out, one byte back: the whole of the panel's side of the
    /// wire. The controller drives the line low except while it is serving a
    /// read burst.
    pub fn exchange(self: *Panel, tx: u8) u8 {
        if (self.burst.pending()) return self.burst.next();
        const high = self.high orelse {
            self.high = tx;
            return proto.wire.idle_byte;
        };
        self.high = null;
        const word = (@as(u16, high) << proto.wire.byte_bits) | @as(u16, tx);
        self.consumeWord(word);
        return proto.wire.idle_byte;
    }

    /// The seam the SPI channel drives the panel through.
    pub fn device(self: *Panel) spi.Device {
        return .{ .context = self, .exchangeFn = exchangeThunk };
    }

    fn consumeWord(self: *Panel, word: u16) void {
        switch (self.state) {
            .command => {
                self.state = .preamble;
                self.takeCommand(@fromBackingInt(@intCast(word)));
            },
            .data => {
                self.state = .preamble;
                self.takeData(word);
            },
            .preamble => switch (word) {
                proto.preamble.command => self.state = .command,
                proto.preamble.write => self.state = .data,
                proto.preamble.read => self.burst.stage(self.readValue()),
                else => {},
            },
        }
    }

    fn takeCommand(self: *Panel, command: proto.Command) void {
        self.command = command;
        self.data_index = 0;
        self.refusing = false;
        if (command == .sys_run) {
            self.awake = true;
            self.commands +%= 1;
            return;
        }
        if (!self.awake) {
            self.asleep +%= 1;
            self.refusing = true;
            return;
        }
        _ = self.film.arrive();
        self.commands +%= 1;
        switch (command) {
            .sleep => self.awake = false,
            .device_info => self.info_index = 0,
            .load_end => self.load_left = 0,
            else => {},
        }
    }

    fn takeData(self: *Panel, word: u16) void {
        const command = self.command orelse {
            self.stray +%= 1;
            return;
        };
        defer self.data_index +%= 1;
        if (self.refusing) return;
        switch (command) {
            .reg_read, .reg_write => self.takeRegisterArg(command, word),
            .vcom => self.takeVcomArg(word),
            .load_area => self.takeLoadArg(word),
            .display_area => self.takeDisplayArg(word),
            else => {},
        }
    }

    fn takeRegisterArg(self: *Panel, command: proto.Command, word: u16) void {
        if (self.data_index == proto.arg.reg_address) {
            self.reg_address = word;
            return;
        }
        if (self.data_index != proto.arg.reg_value or command != .reg_write) return;
        if (self.reg_address == proto.reg.lutafsr) {
            self.read_only +%= 1;
            return;
        }
        self.writeRegister(self.reg_address, word);
    }

    fn takeVcomArg(self: *Panel, word: u16) void {
        if (self.data_index == proto.arg.vcom_direction) {
            self.vcom_direction = word;
            return;
        }
        if (self.data_index == proto.arg.vcom_value and self.vcom_direction == proto.vcom.set) {
            self.vcom_mv = word;
        }
    }

    fn takeLoadArg(self: *Panel, word: u16) void {
        switch (self.data_index) {
            proto.arg.load_mode => {
                self.load_mode = word;
                self.pixels_per_word = proto.pixelsPerWord(word >> proto.wire.format_shift);
                self.loaded_pixels = 0;
            },
            proto.arg.load_x => self.load_x = word,
            proto.arg.load_y => self.load_y = word,
            proto.arg.load_width => self.load_width = word,
            proto.arg.load_height => {
                self.load_height = word;
                self.load_left = @as(u32, self.load_width) * @as(u32, word);
            },
            else => {
                if (self.data_index >= proto.arg.load_first_pixel) self.takePixels(word);
            },
        }
    }

    /// One data word of image. The rectangle bounds it: past the area the
    /// load declared, the word moves nothing.
    fn takePixels(self: *Panel, word: u16) void {
        if (self.load_left == 0) {
            self.overrun +%= 1;
            return;
        }
        const taken = @min(@as(u32, self.pixels_per_word), self.load_left);
        const bits_per_pixel = proto.bitsPerPixel(self.load_mode >> proto.wire.format_shift);
        const is_big_endian = (self.load_mode & proto.wire.endian_mask) != 0;
        var index: u32 = 0;
        while (index < taken) : (index += 1) {
            const offset = image.pixelBitOffset(index, bits_per_pixel, is_big_endian);
            const mask = (@as(u32, 1) << @intCast(bits_per_pixel)) - 1;
            const sample: u8 = @intCast((@as(u32, word) >> @intCast(offset)) & mask);
            const max_value = (@as(u32, 1) << @intCast(bits_per_pixel)) - 1;
            const grey: u8 = @intCast((@as(u32, sample) * 255 + max_value / 2) / max_value);
            const ordinal = self.loaded_pixels + index;
            const row = ordinal / self.load_width;
            const column = ordinal % self.load_width;
            const target = image.rotate(
                self.load_mode & proto.wire.rotation_mask,
                column,
                row,
                self.load_width,
                self.load_height,
            );
            if (self.planes.ready()) self.planes.image.set(
                @as(u32, self.load_x) + target.x,
                @as(u32, self.load_y) + target.y,
                grey,
            );
        }
        self.loaded_pixels += taken;
        self.load_left -= taken;
        self.pixels += taken;
    }

    fn takeDisplayArg(self: *Panel, word: u16) void {
        if (self.data_index < self.display_args.len) self.display_args[self.data_index] = word;
        if (self.data_index != proto.arg.display_waveform) return;
        self.last_waveform = word;
        if (self.planes.ready()) self.planes.glass.refreshFrom(
            &self.planes.image,
            self.display_args[proto.arg.display_x],
            self.display_args[proto.arg.display_y],
            self.display_args[proto.arg.display_width],
            self.display_args[proto.arg.display_height],
            word,
        );
        self.refreshes +%= 1;
        self.film.start();
        if (self.refresh_hook) |hook| hook.refreshFn(hook.context);
        if (self.event_hook) |hook| hook.refreshFn(hook.context, self);
        refresh.notify(self.refresh_log_hook, self.display_args, word);
    }
    pub fn latestRefresh(self: *const Panel) refresh.Event {
        return .{ .x = self.display_args[proto.arg.display_x], .y = self.display_args[proto.arg.display_y], .width = self.display_args[proto.arg.display_width], .height = self.display_args[proto.arg.display_height], .waveform = self.last_waveform };
    }
    /// What the next read burst carries. A refused command answers zero: the
    /// panel is asleep and is not driving the line at all.
    fn readValue(self: *Panel) u16 {
        const command = self.command orelse return 0;
        if (self.refusing) return 0;
        return switch (command) {
            .reg_read => self.readRegister(self.reg_address),
            .vcom => self.vcom_mv,
            .device_info => self.nextInfoWord(),
            else => 0,
        };
    }

    fn nextInfoWord(self: *Panel) u16 {
        if (self.info_index >= proto.info.words) {
            self.overdrain +%= 1;
            return 0;
        }
        const value = proto.info.word(self.planes.geometry, self.info_index);
        self.info_index += 1;
        return value;
    }

    /// A register read on the wire. LUTAFSR is the controller's own and the
    /// read of it is what advances the film, so this one is not const.
    pub fn readRegister(self: *Panel, address: u16) u16 {
        if (address == proto.reg.lutafsr) return self.film.poll();
        return self.registerValue(address);
    }

    /// A register's value without touching the controller: what the report
    /// and a test ask.
    pub fn registerValue(self: *const Panel, address: u16) u16 {
        if (address == proto.reg.lutafsr) {
            return if (self.film.busy()) busy.status.busy else busy.status.idle;
        }
        for (self.registers[0..self.register_count]) |entry| {
            if (entry.address == address) return entry.value;
        }
        return 0;
    }

    fn writeRegister(self: *Panel, address: u16, value: u16) void {
        for (self.registers[0..self.register_count]) |*entry| {
            if (entry.address == address) {
                entry.value = value;
                return;
            }
        }
        if (self.register_count == self.registers.len) {
            self.spilled +%= 1;
            return;
        }
        self.registers[self.register_count] = .{ .address = address, .value = value };
        self.register_count += 1;
    }
};

fn exchangeThunk(context: *anyopaque, tx: u8) u8 {
    const self: *Panel = @ptrCast(@alignCast(context));
    return self.exchange(tx);
}
