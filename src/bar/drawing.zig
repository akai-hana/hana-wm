//! Status bar text drawing/rendering
//! XCB + Xft for text rendering
//! Includes color caching

const std = @import("std");
const debug = @import("debug");
const defs = @import("defs");

const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("X11/Xft/Xft.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xlib-xcb.h");
    @cInclude("fontconfig/fontconfig.h");
});

// Color conversion constant: 8-bit to 16-bit (0xFF -> 0xFFFF)
const COLOR_8_TO_16_MULTIPLIER: u16 = 0x101;

// Helper to convert RGB888 to XRenderColor
inline fn rgbToXRenderColor(rgb: u32) c.XRenderColor {
    const r: u16 = @intCast((rgb >> 16) & 0xFF);
    const g: u16 = @intCast((rgb >> 8) & 0xFF);
    const b: u16 = @intCast(rgb & 0xFF);
    return .{
        .red = r * COLOR_8_TO_16_MULTIPLIER,
        .green = g * COLOR_8_TO_16_MULTIPLIER,
        .blue = b * COLOR_8_TO_16_MULTIPLIER,
        .alpha = 0xFFFF,
    };
}

// Color cache for performance; avoid allocating/freeing colors repeatedly
const ColorCache = struct {
    colors: std.AutoHashMap(u32, c.XftColor),
    fallback_color: c.XftColor,
    display: *c.Display,
    visual: *c.Visual,
    colormap: c.Colormap,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, display: *c.Display, visual: *c.Visual, colormap: c.Colormap) ColorCache {
        var fallback: c.XftColor = undefined;
        _ = c.XftColorAllocValue(display, visual, colormap, &rgbToXRenderColor(0xFFFFFF), &fallback);
        
        return .{
            .colors = std.AutoHashMap(u32, c.XftColor).init(allocator),
            .fallback_color = fallback,
            .display = display,
            .visual = visual,
            .colormap = colormap,
            .allocator = allocator,
        };
    }

    fn deinit(self: *ColorCache) void {
        var iter = self.colors.iterator();
        while (iter.next()) |entry| {
            var color = entry.value_ptr.*;
            c.XftColorFree(self.display, self.visual, self.colormap, &color);
        }
        self.colors.deinit();
        c.XftColorFree(self.display, self.visual, self.colormap, &self.fallback_color);
    }

    fn get(self: *ColorCache, rgb: u32) *c.XftColor {
        const result = self.colors.getOrPut(rgb) catch {
            debug.warn("Color cache allocation failed, using fallback", .{});
            return &self.fallback_color;
        };

        if (!result.found_existing) {
            _ = c.XftColorAllocValue(self.display, self.visual, self.colormap, 
                &rgbToXRenderColor(rgb), result.value_ptr);
        }
        return result.value_ptr;
    }
};

// UTF-8 font run iterator - DRY principle for text processing
const FontRunIterator = struct {
    text: []const u8,
    pos: usize,
    run_start: usize,
    run_font: *c.XftFont,
    dc: *DrawContext,

    fn init(dc: *DrawContext, text: []const u8) FontRunIterator {
        return .{
            .text = text,
            .pos = 0,
            .run_start = 0,
            .run_font = dc.xft_font,
            .dc = dc,
        };
    }

    const Run = struct {
        start: usize,
        end: usize,
        font: *c.XftFont,
    };

    fn next(self: *FontRunIterator) ?Run {
        if (self.pos >= self.text.len) {
            // Return final run if there's any remaining text
            if (self.run_start < self.pos) {
                const run = Run{ .start = self.run_start, .end = self.pos, .font = self.run_font };
                self.run_start = self.pos; // Mark as consumed
                return run;
            }
            return null;
        }

        const seq_len = std.unicode.utf8ByteSequenceLength(self.text[self.pos]) catch 1;
        const end = @min(self.pos + seq_len, self.text.len);
        const cp = std.unicode.utf8Decode(self.text[self.pos..end]) catch 0xFFFD;
        const font = self.dc.fontForCodepoint(cp);

        if (font != self.run_font and self.pos > self.run_start) {
            // Font changed, return current run
            const run = Run{ .start = self.run_start, .end = self.pos, .font = self.run_font };
            self.run_start = self.pos;
            self.run_font = font;
            return run;
        }

        if (font != self.run_font) {
            self.run_font = font;
        }
        self.pos = end;
        return self.next();
    }
};

pub const DrawContext = struct {
    allocator: std.mem.Allocator,
    display: *c.Display,
    drawable: c.Drawable,
    xft_draw: *c.XftDraw,
    xft_font: *c.XftFont,
    xft_fonts: []*c.XftFont,
    width: u16,
    height: u16,
    color_cache: ColorCache,
    visual: *c.Visual,
    colormap: c.Colormap,
    
    pub fn init(allocator: std.mem.Allocator, drawable: u32, width: u16, height: u16) !*DrawContext {
        const dc = try allocator.create(DrawContext);
        errdefer allocator.destroy(dc);
        
        const display = c.XOpenDisplay(null) orelse return error.DisplayOpenFailed;
        const visual = c.XDefaultVisual(display, 0);
        const colormap = c.XDefaultColormap(display, 0);
        const xft_draw = c.XftDrawCreate(display, drawable, visual, colormap) orelse {
            _ = c.XCloseDisplay(display);
            return error.XftDrawCreateFailed;
        };
        
        dc.* = DrawContext{
            .allocator = allocator, .display = display, .drawable = drawable,
            .xft_draw = xft_draw, .xft_font = undefined, .xft_fonts = &[0]*c.XftFont{},
            .width = width, .height = height,
            .color_cache = ColorCache.init(allocator, display, visual, colormap),
            .visual = visual, .colormap = colormap,
        };
        
        return dc;
    }
    
    pub fn deinit(self: *DrawContext) void {
        for (self.xft_fonts) |font| c.XftFontClose(self.display, font);
        if (self.xft_fonts.len > 0) self.allocator.free(self.xft_fonts);
        self.color_cache.deinit();
        c.XftDrawDestroy(self.xft_draw);
        _ = c.XCloseDisplay(self.display);
        self.allocator.destroy(self);
    }
    
    pub fn loadFont(self: *DrawContext, font_name: []const u8) !void {
        const font_name_z = try self.allocator.dupeZ(u8, font_name);
        defer self.allocator.free(font_name_z);
        
        const font = c.XftFontOpenName(self.display, 0, font_name_z.ptr) orelse 
            c.XftFontOpenName(self.display, 0, "monospace:size=10") orelse {
                debug.warn("Failed to load '{s}' and fallback", .{font_name});
                return error.FontLoadFailed;
            };
        
        if (font == null) debug.warn("Failed to load '{s}', trying fallback", .{font_name});
        
        const slice = try self.allocator.alloc(*c.XftFont, 1);
        slice[0] = font;
        self.xft_fonts = slice;
        self.xft_font = slice[0];
        debug.info("Xft font loaded: {s}", .{font_name});
    }
    
    fn openVerified(self: *DrawContext, pattern: []const u8) ?*c.XftFont {
        const pattern_z = self.allocator.dupeZ(u8, pattern) catch return null;
        defer self.allocator.free(pattern_z);

        const font = c.XftFontOpenName(self.display, 0, pattern_z.ptr) orelse return null;

        var family_cstr: [*:0]const u8 = undefined;
        if (c.FcPatternGetString(font.*.pattern, "family", 0, @ptrCast(&family_cstr)) != 0) {
            debug.warn("Could not verify family for '{s}', accepting anyway", .{pattern});
            return font;
        }
        
        const actual = std.mem.span(family_cstr);
        const colon = std.mem.indexOfScalar(u8, pattern, ':') orelse pattern.len;
        const requested = pattern[0..colon];
        
        const shorter, const longer = if (actual.len < requested.len) 
            .{ actual, requested } else .{ requested, actual };
        
        if (shorter.len == 0 or !std.mem.startsWith(u8, longer, shorter)) {
            c.XftFontClose(self.display, font);
            return null;
        }

        debug.info("Font verified: {s}", .{pattern});
        return font;
    }

    pub fn loadFonts(self: *DrawContext, font_names: []const []const u8) !void {
        var fonts = std.ArrayList(*c.XftFont){};
        defer fonts.deinit(self.allocator);

        for (font_names) |font_name| {
            if (self.openVerified(font_name)) |f| {
                try fonts.append(self.allocator, f);
                continue;
            }

            // Retry with explicit :pixelsize if there's a bare size after ':'
            if (std.mem.indexOfScalar(u8, font_name, ':')) |colon_pos| {
                const after_colon = font_name[colon_pos + 1 ..];
                if (after_colon.len > 0 and std.ascii.isDigit(after_colon[0])) {
                    const retry = std.fmt.allocPrint(self.allocator,
                        "{s}:pixelsize={s}", .{ font_name[0..colon_pos], after_colon }) catch continue;
                    defer self.allocator.free(retry);

                    if (self.openVerified(retry)) |f| {
                        try fonts.append(self.allocator, f);
                        continue;
                    }
                }
            }

            debug.warn("Font not available: {s}", .{font_name});
        }

        if (fonts.items.len == 0) {
            if (c.XftFontOpenName(self.display, 0, "monospace:size=10")) |f| {
                try fonts.append(self.allocator, f);
                debug.warn("All requested fonts failed, using monospace fallback", .{});
            } else {
                return error.NoFontsLoaded;
            }
        }

        self.xft_fonts = try fonts.toOwnedSlice(self.allocator);
        self.xft_font = self.xft_fonts[0];
    }
    
    fn fontForCodepoint(self: *DrawContext, cp: u21) *c.XftFont {
        for (self.xft_fonts) |font| {
            if (c.XftCharIndex(self.display, font, @intCast(cp)) != 0) {
                return font;
            }
        }
        return self.xft_font;
    }
    
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        const xft_color = self.color_cache.get(color);
        c.XftDrawRect(self.xft_draw, xft_color, @intCast(x), @intCast(y), width, height);
    }
    
    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        const xft_color = self.color_cache.get(color);
        
        if (self.xft_fonts.len <= 1) {
            c.XftDrawStringUtf8(self.xft_draw, xft_color, self.xft_font,
                @intCast(x), @intCast(y), text.ptr, @intCast(text.len));
            return;
        }
        
        var current_x: i32 = @intCast(x);
        var iter = FontRunIterator.init(self, text);
        while (iter.next()) |run| {
            const run_text = text[run.start..run.end];
            c.XftDrawStringUtf8(self.xft_draw, xft_color, run.font,
                current_x, @intCast(y), run_text.ptr, @intCast(run_text.len));
            
            var extents: c.XGlyphInfo = undefined;
            c.XftTextExtentsUtf8(self.display, run.font, run_text.ptr, @intCast(run_text.len), &extents);
            current_x += extents.xOff;
        }
    }
    
    pub fn drawTextEllipsis(self: *DrawContext, x: u16, y: u16, text: []const u8, max_width: u16, color: u32) !void {
        const text_width = self.textWidth(text);
        if (text_width <= max_width) {
            try self.drawText(x, y, text, color);
            return;
        }
        
        const ellipsis = "...";
        const ellipsis_width = self.textWidth(ellipsis);
        
        if (max_width <= ellipsis_width) {
            try self.drawText(x, y, ellipsis, color);
            return;
        }
        
        const available = max_width - ellipsis_width;
        
        // Binary search for the longest UTF-8 prefix that fits
        var lo: usize = 0;
        var hi: usize = text.len;
        while (lo < hi) {
            var mid = lo + (hi - lo) / 2;
            // Snap mid to valid UTF-8 boundary
            while (mid < hi and mid < text.len and text[mid] & 0xC0 == 0x80) mid += 1;
            if (mid == lo) { lo = mid + 1; continue; }
            if (self.textWidth(text[0..mid]) <= available) {
                lo = mid;
            } else {
                hi = mid;
            }
        }

        // Try to break at word boundary
        var len = lo;
        if (len > 0) {
            if (std.mem.lastIndexOfScalar(u8, text[0..len], ' ')) |space| {
                if (space > len / 2) len = space;
            }
        }
        
        if (len > 0) {
            try self.drawText(x, y, text[0..len], color);
            try self.drawText(x + self.textWidth(text[0..len]), y, ellipsis, color);
        } else {
            try self.drawText(x, y, ellipsis, color);
        }
    }
    
    pub fn textWidth(self: *DrawContext, text: []const u8) u16 {
        if (self.xft_fonts.len <= 1) {
            var extents: c.XGlyphInfo = undefined;
            c.XftTextExtentsUtf8(self.display, self.xft_font, text.ptr, @intCast(text.len), &extents);
            return @intCast(extents.xOff);
        }
        
        var total_width: i32 = 0;
        var iter = FontRunIterator.init(self, text);
        while (iter.next()) |run| {
            var extents: c.XGlyphInfo = undefined;
            const run_text = text[run.start..run.end];
            c.XftTextExtentsUtf8(self.display, run.font, run_text.ptr, @intCast(run_text.len), &extents);
            total_width += extents.xOff;
        }
        return @intCast(total_width);
    }
    
    pub inline fn getAscender(self: *DrawContext) i16 { return @intCast(self.xft_font.*.ascent); }
    pub inline fn getDescender(self: *DrawContext) i16 { return -@as(i16, @intCast(self.xft_font.*.descent)); }
    pub inline fn flush(self: *DrawContext) void { _ = c.XFlush(self.display); }

    pub inline fn baselineY(self: *DrawContext, bar_height: u16) u16 {
        const asc: i32 = @intCast(self.xft_font.*.ascent);
        const desc: i32 = @intCast(self.xft_font.*.descent);
        const pad: i32 = @divTrunc(@as(i32, bar_height) - (asc + desc), 2);
        return @intCast(@max(asc, pad + asc));
    }
};
