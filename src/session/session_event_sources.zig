//! Engine-thread source adapters for session events (RA8EMU-192).
const std = @import("std");
const stream_mod = @import("session_event_stream.zig");
const sci = @import("ra8_chip").periph.sci;
const gpio = @import("ra8_chip").periph.gpio;
const registry = @import("ra8_chip").periph.registry;
const TimeBase = @import("ra8_chip").periph.timebase.TimeBase;
const reset = @import("ra8_chip").periph.reset;
const board_events = @import("ra8_board").event_sink;
const eink = @import("ra8_components").eink;
const glcdc = @import("ra8_chip").periph.glcdc;
const wdt = @import("ra8_chip").periph.wdt;
const iwdt = @import("ra8_chip").periph.iwdt;

pub const Core = stream_mod.Core;
pub const Event = stream_mod.Event;
const Stream = stream_mod.Stream;
const Context = struct { sources: *Sources, core: ?Core };

pub const Sources = struct {
    stream: ?*Stream = null,
    time_base: ?*const TimeBase = null,
    issuer: ?*const registry.Issuer = null,
    uart_context: Context = undefined,
    gpio_context: Context = undefined,
    gpio_levels: [gpio.port_count]u16 = @splat(0),
    /// The pins the GPIO tap listens to, for each LED's output latch.
    pins: ?*const gpio.Gpio = null,
    /// Each LED as last published: lit or not.
    led_on: [gpio.led_count]bool = @splat(false),
    active_core: Core = .cpu0,
    observation: board_events.Observation = .{},
    eink_active: bool = false,
    board_panel: ?*const eink.Panel = null,
    attached_eink: ?*const ?*eink.Panel = null,

    pub fn bind(self: *Sources, stream: *Stream, time_base: *const TimeBase) void {
        self.stream = stream;
        self.time_base = time_base;
    }

    pub fn bindBoard(self: *Sources, issuer: *const registry.Issuer, pins: *const gpio.Gpio, initial: board_events.Observation, board_panel: *const eink.Panel, attached_eink: *const ?*eink.Panel) void {
        self.issuer = issuer;
        self.observation = initial;
        self.board_panel = board_panel;
        self.attached_eink = attached_eink;
        for (0..gpio.port_count) |port| {
            const levels = pins.portLevel(@intCast(port));
            self.gpio_levels[port] = levels;
        }
    }

    pub fn uartTap(self: *Sources, core: ?Core) sci.Tap {
        self.uart_context = .{ .sources = self, .core = core };
        return .{ .ctx = &self.uart_context, .sent = uartSent };
    }

    /// The tap for `pins`: a pin change, and each LED as its output latch
    /// stands now, so only a later change is published.
    pub fn gpioTap(self: *Sources, pins: *const gpio.Gpio, core: ?Core) gpio.Gpio.EventTap {
        self.pins = pins;
        for (&self.led_on, 0..) |*on, index| on.* = pins.ledLevel(index) == 1;
        self.gpio_context = .{ .sources = self, .core = core };
        return .{ .context = &self.gpio_context, .changedFn = gpioChanged };
    }

    pub fn boardEventSink(self: *Sources) board_events.EventSink {
        return .{ .context = self, .observeFn = observed, .resetFn = resetOccurred };
    }

    pub fn einkHook(self: *Sources) eink.Panel.EventHook {
        return .{ .context = self, .refreshFn = einkRefreshed };
    }

    pub fn glcdcHook(self: *Sources) glcdc.Glcdc.EventHook {
        return .{ .context = self, .frameFn = glcdcFrame };
    }

    pub fn watchdogHook(self: *Sources) wdt.Wdt.EventHook {
        return .{ .context = self, .refreshErrorFn = watchdogRefreshError, .underflowFn = watchdogUnderflow };
    }

    pub fn independentWatchdogHook(self: *Sources) iwdt.Iwdt.EventHook {
        return .{ .context = self, .underflowFn = independentWatchdogUnderflow };
    }

    fn currentCore(self: *const Sources, fallback: ?Core) Core {
        if (fallback) |core| return core;
        const found = self.issuer orelse return .cpu0;
        return @fromBackingInt(@intCast(@backingInt(found.*)));
    }

    fn publish(self: *Sources, event: Event) void {
        self.publishAt(event, if (self.time_base) |clock| clock.now() else 0);
    }

    fn publishAt(self: *Sources, event: Event, at_ns: u64) void {
        var stamped = event;
        stamped.virtual_ns = at_ns;
        if (self.stream) |stream| stream.publish(stamped);
    }

    fn uartSent(context: *anyopaque, channel: usize, byte: u8) void {
        const source: *Context = @ptrCast(@alignCast(context));
        source.sources.publish(.{ .core = source.sources.currentCore(source.core), .kind = .uart_byte, .payload = .{ .uart = .{ .channel = @intCast(channel), .byte = byte } } });
    }

    fn gpioChanged(context: *anyopaque, port: u8, levels: u16, changed: u16, origin: gpio.Gpio.EventOrigin) void {
        const source: *Context = @ptrCast(@alignCast(context));
        const core = if (origin == .external) source.sources.active_core else source.sources.currentCore(source.core);
        source.sources.gpio_levels[port] = levels;
        if (changed != 0) source.sources.publish(.{ .core = core, .kind = .gpio_changed, .payload = .{ .gpio = .{ .port = port, .changed = changed, .levels = levels } } });
        source.sources.ledsOn(port, core);
    }

    /// Publish each LED on `port` whose output latch has moved. An LED
    /// follows its latch, as the run report and the board view read it
    /// (board_leds.zig), and not the pin's driven level: firmware that makes
    /// the pin an output through PmnPFS never moves the port's own direction
    /// bit, so the driven level would never show its LED (RA8EMU-1121).
    fn ledsOn(self: *Sources, port: u8, core: Core) void {
        const pins = self.pins orelse return;
        for (gpio.leds, 0..) |led, index| {
            if (led.port != port) continue;
            const high = pins.ledLevel(index) == 1;
            if (high == self.led_on[index]) continue;
            self.led_on[index] = high;
            self.publish(.{ .core = core, .kind = .led_changed, .payload = .{ .led = .{ .index = @intCast(index), .level = high } } });
        }
    }

    fn observed(context: *anyopaque, issuer: registry.Issuer, at_ns: u64, latest: board_events.Observation) void {
        _ = at_ns;
        const self: *Sources = @ptrCast(@alignCast(context));
        self.active_core = @fromBackingInt(@intCast(@backingInt(issuer)));
        self.observation = latest;
    }

    fn einkRefreshed(context: *anyopaque, panel: *const eink.Panel) void {
        const self: *Sources = @ptrCast(@alignCast(context));
        const active = if (self.attached_eink) |attached| attached.* orelse self.board_panel else self.board_panel;
        if (active != panel) return;
        if (self.board_panel == panel) self.eink_active = true;
        const dirty = panel.latestRefresh();
        self.publish(.{ .core = self.currentCore(null), .kind = .lcd_frame, .payload = .{ .frame = .{
            .width = panel.planes.geometry.width,
            .height = panel.planes.geometry.height,
            .generation = panel.refreshes,
            .dirty = .{ .x = dirty.x, .y = dirty.y, .width = dirty.width, .height = dirty.height },
        } } });
    }

    fn glcdcFrame(context: *anyopaque, display: *glcdc.Glcdc) void {
        const self: *Sources = @ptrCast(@alignCast(context));
        if (self.eink_active) return;
        if (self.attached_eink) |attached| if (attached.* != null) return;
        const width = display.panelWidth();
        const height = display.panelHeight();
        self.publish(.{ .core = self.active_core, .kind = .lcd_frame, .payload = .{ .frame = .{
            .width = width,
            .height = height,
            .generation = display.system.frames,
            .dirty = .{
                .x = 0,
                .y = 0,
                .width = @intCast(@min(width, std.math.maxInt(u16))),
                .height = @intCast(@min(height, std.math.maxInt(u16))),
            },
        } } });
    }

    fn watchdogRefreshError(context: *anyopaque) void {
        const self: *Sources = @ptrCast(@alignCast(context));
        self.publish(.{ .core = self.currentCore(null), .kind = .watchdog, .payload = .{ .watchdog = .wdt } });
    }

    fn watchdogUnderflow(context: *anyopaque) void {
        const self: *Sources = @ptrCast(@alignCast(context));
        self.publish(.{ .core = self.active_core, .kind = .watchdog, .payload = .{ .watchdog = .wdt } });
    }

    fn independentWatchdogUnderflow(context: *anyopaque) void {
        const self: *Sources = @ptrCast(@alignCast(context));
        self.publish(.{ .core = self.active_core, .kind = .watchdog, .payload = .{ .watchdog = .iwdt } });
    }

    fn resetOccurred(context: *anyopaque, issuer: registry.Issuer, cause: reset.Source, at_ns: u64) void {
        const self: *Sources = @ptrCast(@alignCast(context));
        const reset_kind: @FieldType(Event.Payload, "reset") = switch (cause) {
            .software => .software,
            .watchdog => .watchdog,
            .iwdt => .iwdt,
        };
        self.publishAt(.{ .core = @fromBackingInt(@intCast(@backingInt(issuer))), .kind = .reset, .payload = .{ .reset = reset_kind } }, at_ns);
    }
};
