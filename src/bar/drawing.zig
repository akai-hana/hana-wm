//! XCB + Xft text rendering with color caching

const std = @import("std");
const defs = @import("defs");

const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("X11/Xft/Xft.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xlib-xcb.h");
});

// Color conversion constant: 8-bit to 16-bit (0xFF -> 0xFFFF)
const COLOR_8_TO_16_MULTIPLIER: u16 = 0x101;

// Helper to convert RGB888 to XRenderColor
fn rgbToXRenderColor(rgb: u32) c.XRenderColor {
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

// Color cache for performance - avoid allocating/freeing colors repeatedly
const ColorCache = struct {
    colors: std.AutoHashMap(u32, c.XftColor),
    fallback_color: c.XftColor, // For allocation failures
    display: *c.Display,
    visual: *c.Visual,
    colormap: c.Colormap,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, display: *c.Display, visual: *c.Visual, colormap: c.Colormap) ColorCache {
        // Pre-allocate white as fallback color
        var fallback: c.XftColor = undefined;
        _ = c.XftColorAllocValue(
            display,
            visual,
            colormap,
            &rgbToXRenderColor(0xFFFFFF),
            &fallback,
        );
        
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
            // Allocation failed - return fallback color instead of stack pointer
            std.log.warn("[drawing] Color cache allocation failed, using fallback", .{});
            return &self.fallback_color;
        };

        if (result.found_existing) {
            return result.value_ptr;
        }

        // Allocate new color
        const render_color = rgbToXRenderColor(rgb);
        _ = c.XftColorAllocValue(
            self.display,
            self.visual,
            self.colormap,
            &render_color,
            result.value_ptr,
        );

        return result.value_ptr;
    }
};

pub const DrawContext = struct {
    allocator: std.mem.Allocator,
    display: *c.Display,
    drawable: c.Drawable,
    xft_draw: *c.XftDraw,
    xft_font: *c.XftFont,
    width: u16,
    height: u16,
    color_cache: ColorCache,
    visual: *c.Visual,
    colormap: c.Colormap,
    
    pub fn init(allocator: std.mem.Allocator, conn: *defs.xcb.xcb_connection_t, screen: *defs.xcb.xcb_screen_t, drawable: u32, width: u16, height: u16) !*DrawContext {
        _ = conn;
        _ = screen;
        
        const dc = try allocator.create(DrawContext);
        errdefer allocator.destroy(dc);
        
        const display = c.XOpenDisplay(null) orelse return error.DisplayOpenFailed;
        
        const visual = c.XDefaultVisual(display, 0);
        const colormap = c.XDefaultColormap(display, 0);
        const xft_draw = c.XftDrawCreate(display, drawable, visual, colormap) orelse {
            _ = c.XCloseDisplay(display);
            return error.XftDrawCreateFailed;
        };
        
        dc.* = .{
            .allocator = allocator,
            .display = display,
            .drawable = drawable,
            .xft_draw = xft_draw,
            .xft_font = undefined, // Set in loadFont
            .width = width,
            .height = height,
            .color_cache = ColorCache.init(allocator, display, visual, colormap),
            .visual = visual,
            .colormap = colormap,
        };
        
        return dc;
    }
    
    pub fn deinit(self: *DrawContext) void {
        c.XftFontClose(self.display, self.xft_font);
        self.color_cache.deinit();
        c.XftDrawDestroy(self.xft_draw);
        _ = c.XCloseDisplay(self.display);
        self.allocator.destroy(self);
    }
    
    pub fn loadFont(self: *DrawContext, font_name: []const u8) !void {
        const font_name_z = try self.allocator.dupeZ(u8, font_name);
        defer self.allocator.free(font_name_z);
        
        const font = c.XftFontOpenName(self.display, 0, font_name_z.ptr);
        if (font != null) {
            self.xft_font = font.?;
            std.log.info("[drawing] Xft font loaded: {s}", .{font_name});
            return;
        }
        
        std.log.warn("[drawing] Failed to load '{s}', trying fallback", .{font_name});
        const fallback = c.XftFontOpenName(self.display, 0, "monospace:size=10");
        if (fallback != null) {
            self.xft_font = fallback.?;
            std.log.info("[drawing] Xft fallback font loaded", .{});
            return;
        }
        
        return error.FontLoadFailed;
    }
    
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        const xft_color = self.color_cache.get(color);
        c.XftDrawRect(self.xft_draw, xft_color, @intCast(x), @intCast(y), width, height);
    }
    
    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        const xft_color = self.color_cache.get(color);
        
        c.XftDrawStringUtf8(
            self.xft_draw,
            xft_color,
            self.xft_font,
            @intCast(x),
            @intCast(y),
            text.ptr,
            @intCast(text.len),
        );
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
        
        // Try to break at word boundary for better appearance
        var len: usize = 0;
        var last_space: usize = 0;
        
        while (len < text.len) {
            if (text[len] == ' ') {
                last_space = len;
            }
            
            if (self.textWidth(text[0..len + 1]) > available) {
                // Use last space if found and reasonable
                if (last_space > 0 and last_space > len / 2) {
                    len = last_space;
                }
                break;
            }
            len += 1;
        }
        
        if (len > 0) {
            try self.drawText(x, y, text[0..len], color);
            try self.drawText(x + self.textWidth(text[0..len]), y, ellipsis, color);
        } else {
            try self.drawText(x, y, ellipsis, color);
        }
    }
    
    pub fn textWidth(self: *DrawContext, text: []const u8) u16 {
        var extents: c.XGlyphInfo = undefined;
        c.XftTextExtentsUtf8(
            self.display,
            self.xft_font,
            text.ptr,
            @intCast(text.len),
            &extents,
        );
        return @intCast(extents.xOff);
    }
    
    pub fn getAscender(self: *DrawContext) i16 {
        return @intCast(self.xft_font.*.ascent);
    }
    
    pub fn getDescender(self: *DrawContext) i16 {
        return -@as(i16, @intCast(self.xft_font.*.descent));
    }
    
    pub fn flush(self: *DrawContext) void {
        _ = c.XFlush(self.display);
    }
};
