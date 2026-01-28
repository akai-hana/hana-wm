//! Simple XCB + Xft text rendering
//! This is the standard way - what dwm, dmenu, st use

const std = @import("std");
const defs = @import("defs");

const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("X11/Xft/Xft.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xlib-xcb.h");
});

pub const DrawContext = struct {
    allocator: std.mem.Allocator,
    display: *c.Display,
    drawable: c.Drawable,
    xft_draw: *c.XftDraw,
    xft_font: *c.XftFont,
    width: u16,
    height: u16,
    
    pub fn init(allocator: std.mem.Allocator, conn: *defs.xcb.xcb_connection_t, screen: *defs.xcb.xcb_screen_t, drawable: u32, width: u16, height: u16) !*DrawContext {
        _ = conn; // XCB connection not needed for Xft
        _ = screen; // We get screen info from Display
        
        const dc = try allocator.create(DrawContext);
        errdefer allocator.destroy(dc);
        
        // Get Display from XCB connection (required for Xft)
        const display = c.XOpenDisplay(null) orelse return error.DisplayOpenFailed;
        
        // Create Xft drawable
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
        };
        
        return dc;
    }
    
    pub fn deinit(self: *DrawContext) void {
        c.XftFontClose(self.display, self.xft_font);
        c.XftDrawDestroy(self.xft_draw);
        _ = c.XCloseDisplay(self.display);
        self.allocator.destroy(self);
    }
    
    pub fn loadFont(self: *DrawContext, font_name: []const u8) !void {
        const font_name_z = try self.allocator.dupeZ(u8, font_name);
        defer self.allocator.free(font_name_z);
        
        // Xft handles EVERYTHING - fontconfig, freetype, rendering
        const font = c.XftFontOpenName(self.display, 0, font_name_z.ptr);
        if (font != null) {
            self.xft_font = font.?;
            std.log.info("[drawing] Xft font loaded: {s}", .{font_name});
            return;
        }
        
        // Try fallback
        std.log.warn("[drawing] Failed to load '{s}', trying fallback", .{font_name});
        const fallback = c.XftFontOpenName(self.display, 0, "monospace:size=10");
        if (fallback != null) {
            self.xft_font = fallback.?;
            std.log.info("[drawing] Xft fallback font loaded", .{});
            return;
        }
        
        return error.FontLoadFailed;
    }
    
    pub fn setColor(self: *DrawContext, rgb: u32) void {
        _ = self;
        _ = rgb;
        // Color is set per-draw call in Xft
    }
    
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        const r: u16 = @intCast((color >> 16) & 0xFF);
        const g: u16 = @intCast((color >> 8) & 0xFF);
        const b: u16 = @intCast(color & 0xFF);
        
        var xft_color: c.XftColor = undefined;
        _ = c.XftColorAllocValue(
            self.display,
            c.XDefaultVisual(self.display, 0),
            c.XDefaultColormap(self.display, 0),
            &c.XRenderColor{
                .red = r * 0x101,
                .green = g * 0x101,
                .blue = b * 0x101,
                .alpha = 0xFFFF,
            },
            &xft_color,
        );
        
        c.XftDrawRect(self.xft_draw, &xft_color, @intCast(x), @intCast(y), width, height);
        c.XftColorFree(self.display, c.XDefaultVisual(self.display, 0), c.XDefaultColormap(self.display, 0), &xft_color);
    }
    
    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        const r: u16 = @intCast((color >> 16) & 0xFF);
        const g: u16 = @intCast((color >> 8) & 0xFF);
        const b: u16 = @intCast(color & 0xFF);
        
        var xft_color: c.XftColor = undefined;
        _ = c.XftColorAllocValue(
            self.display,
            c.XDefaultVisual(self.display, 0),
            c.XDefaultColormap(self.display, 0),
            &c.XRenderColor{
                .red = r * 0x101,
                .green = g * 0x101,
                .blue = b * 0x101,
                .alpha = 0xFFFF,
            },
            &xft_color,
        );
        defer c.XftColorFree(self.display, c.XDefaultVisual(self.display, 0), c.XDefaultColormap(self.display, 0), &xft_color);
        
        // THIS IS IT - ONE LINE TO DRAW TEXT!
        c.XftDrawStringUtf8(
            self.xft_draw,
            &xft_color,
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
        var len: usize = 0;
        while (len < text.len) : (len += 1) {
            if (self.textWidth(text[0..len]) > available) {
                if (len > 0) len -= 1;
                break;
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
