//! XCB + Xft text rendering with color caching

const std = @import("std");
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
    xft_font: *c.XftFont,       // Primary font (first in list)
    xft_fonts: []*c.XftFont,    // All loaded fonts for per-glyph fallback (owned slice)
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
            .xft_font = undefined,  // Set in loadFont/loadFonts
            .xft_fonts = &[0]*c.XftFont{},
            .width = width,
            .height = height,
            .color_cache = ColorCache.init(allocator, display, visual, colormap),
            .visual = visual,
            .colormap = colormap,
        };
        
        return dc;
    }
    
    pub fn deinit(self: *DrawContext) void {
        // Close all fonts in the owned slice
        for (self.xft_fonts) |font| {
            c.XftFontClose(self.display, font);
        }
        // Free the owned slice if it was allocated (len > 0 means it came from loadFont/loadFonts)
        if (self.xft_fonts.len > 0) {
            self.allocator.free(self.xft_fonts);
        }
        self.color_cache.deinit();
        c.XftDrawDestroy(self.xft_draw);
        _ = c.XCloseDisplay(self.display);
        self.allocator.destroy(self);
    }
    
    pub fn loadFont(self: *DrawContext, font_name: []const u8) !void {
        const font_name_z = try self.allocator.dupeZ(u8, font_name);
        defer self.allocator.free(font_name_z);
        
        var font: ?*c.XftFont = c.XftFontOpenName(self.display, 0, font_name_z.ptr);
        
        if (font == null) {
            std.log.warn("[drawing] Failed to load '{s}', trying fallback", .{font_name});
            font = c.XftFontOpenName(self.display, 0, "monospace:size=10");
        }
        
        if (font == null) return error.FontLoadFailed;
        
        // Store in a 1-element owned slice
        const slice = try self.allocator.alloc(*c.XftFont, 1);
        slice[0] = font.?;
        self.xft_fonts = slice;
        self.xft_font = slice[0];
        std.log.info("[drawing] Xft font loaded: {s}", .{font_name});
    }
    
    /// Open a font by pattern string and verify via fontconfig that the loaded
    /// font's family actually matches what we asked for.  XftFontOpenName never
    /// returns null — fontconfig silently substitutes — so we must check.
    /// Returns the font on success, or null if the family didn't match.
    fn openVerified(self: *DrawContext, pattern: []const u8) ?*c.XftFont {
        const pattern_z = self.allocator.dupeZ(u8, pattern) catch return null;
        defer self.allocator.free(pattern_z);

        const font = c.XftFontOpenName(self.display, 0, pattern_z.ptr) orelse return null;

        // Extract the family name from the loaded font's FcPattern
        var family_cstr: [*:0]const u8 = undefined;
        const rc = c.FcPatternGetString(font.*.pattern, "family", 0, @ptrCast(&family_cstr));
        if (rc != 0) {  // 0 == FcResultMatch
            // Can't verify — accept it but warn
            std.log.warn("[drawing] Could not verify family for '{s}', accepting anyway", .{pattern});
            return font;
        }
        const actual_family = std.mem.span(family_cstr);

        // Extract the requested family: everything before the first ':'
        const colon = std.mem.indexOfScalar(u8, pattern, ':') orelse pattern.len;
        const req_family = pattern[0..colon];

        std.log.info("[drawing] openVerified: requested='{s}' actual='{s}'", .{ req_family, actual_family });

        // Check: actual family must be a prefix of (or equal to) the requested family,
        // or vice versa.  This handles e.g. requested "FiraCode Nerd Font" matching
        // actual "FiraCode Nerd Font".
        const shorter = if (actual_family.len < req_family.len) actual_family else req_family;
        const longer  = if (actual_family.len < req_family.len) req_family  else actual_family;

        if (shorter.len == 0 or longer.len == 0) {
            c.XftFontClose(self.display, font);
            return null;
        }

        // Count matching prefix characters
        var prefix: usize = 0;
        while (prefix < shorter.len and shorter[prefix] == longer[prefix]) prefix += 1;

        // Require the entire shorter string to match as a prefix
        if (prefix < shorter.len) {
            std.log.warn("[drawing] Family mismatch: wanted '{s}', got '{s}'. Rejecting.", .{ req_family, actual_family });
            c.XftFontClose(self.display, font);
            return null;
        }

        return font;
    }

    /// Load multiple fonts for per-glyph fallback rendering.
    /// Each font name is tried as-is first.  If fontconfig silently substitutes
    /// a different font (detected via FcPatternGetString), we retry by splitting
    /// the last word off the family as a :style= property — this handles config
    /// entries like "Noto Sans CJK JP Medium" where "Medium" is a style, not
    /// part of the family name.
    pub fn loadFonts(self: *DrawContext, font_names: []const []const u8) !void {
        if (font_names.len == 0) return error.NoFontsProvided;

        var fonts = std.ArrayList(*c.XftFont){};
        errdefer {
            for (fonts.items) |f| c.XftFontClose(self.display, f);
            fonts.deinit(self.allocator);
        }

        for (font_names) |font_name| {
            // --- attempt 1: name as-is ---
            if (self.openVerified(font_name)) |f| {
                try fonts.append(self.allocator, f);
                continue;
            }

            // --- attempt 2: split last word as :style= ---
            // font_name looks like "Family Style:size=N"
            // We want                "Family:style=Style:size=N"
            const colon = std.mem.indexOfScalar(u8, font_name, ':') orelse font_name.len;
            const name_part  = font_name[0..colon];       // "Family Style"
            const props_part = font_name[colon..];        // ":size=N"  (or "" if no colon)

            if (std.mem.lastIndexOfScalar(u8, name_part, ' ')) |space| {
                const family = name_part[0..space];       // "Family"
                const style  = name_part[space + 1..];    // "Style"

                const retry = std.fmt.allocPrint(self.allocator,
                    "{s}:style={s}{s}", .{ family, style, props_part }) catch continue;
                defer self.allocator.free(retry);

                if (self.openVerified(retry)) |f| {
                    try fonts.append(self.allocator, f);
                    continue;
                }
            }

            std.log.warn("[drawing] Font not available: {s}", .{font_name});
        }

        if (fonts.items.len == 0) {
            if (c.XftFontOpenName(self.display, 0, "monospace:size=10")) |f| {
                try fonts.append(self.allocator, f);
                std.log.warn("[drawing] All requested fonts failed, using monospace fallback", .{});
            } else {
                return error.NoFontsLoaded;
            }
        }

        self.xft_fonts = try fonts.toOwnedSlice(self.allocator);
        self.xft_font = self.xft_fonts[0];
    }
    
    /// Return the first font in xft_fonts that has a glyph for the given codepoint.
    /// Falls back to the primary font if none cover it.
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
        
        // Single font fast path
        if (self.xft_fonts.len <= 1) {
            c.XftDrawStringUtf8(
                self.xft_draw, xft_color, self.xft_font,
                @intCast(x), @intCast(y), text.ptr, @intCast(text.len),
            );
            return;
        }
        
        // Multi-font: iterate codepoints, batch into runs per font, draw each run
        var current_x: i32 = @intCast(x);
        var run_start: usize = 0;
        var run_font: *c.XftFont = self.xft_font;
        var pos: usize = 0;
        
        while (pos < text.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
            const end = @min(pos + seq_len, text.len);
            const cp = std.unicode.utf8Decode(text[pos..end]) catch 0xFFFD;
            const font = self.fontForCodepoint(cp);
            
            if (font != run_font) {
                // Font changed — flush the current run
                if (pos > run_start) {
                    c.XftDrawStringUtf8(
                        self.xft_draw, xft_color, run_font,
                        current_x, @intCast(y),
                        text[run_start..pos].ptr, @intCast(pos - run_start),
                    );
                    var extents: c.XGlyphInfo = undefined;
                    c.XftTextExtentsUtf8(self.display, run_font, text[run_start..pos].ptr, @intCast(pos - run_start), &extents);
                    current_x += extents.xOff;
                }
                run_start = pos;
                run_font = font;
            }
            pos = end;
        }
        
        // Flush final run
        if (pos > run_start) {
            c.XftDrawStringUtf8(
                self.xft_draw, xft_color, run_font,
                current_x, @intCast(y),
                text[run_start..pos].ptr, @intCast(pos - run_start),
            );
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
        // Single font fast path
        if (self.xft_fonts.len <= 1) {
            var extents: c.XGlyphInfo = undefined;
            c.XftTextExtentsUtf8(self.display, self.xft_font, text.ptr, @intCast(text.len), &extents);
            return @intCast(extents.xOff);
        }
        
        // Multi-font: sum run widths using the same font-selection logic as drawText
        var total_width: i32 = 0;
        var run_start: usize = 0;
        var run_font: *c.XftFont = self.xft_font;
        var pos: usize = 0;
        
        while (pos < text.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
            const end = @min(pos + seq_len, text.len);
            const cp = std.unicode.utf8Decode(text[pos..end]) catch 0xFFFD;
            const font = self.fontForCodepoint(cp);
            
            if (font != run_font) {
                if (pos > run_start) {
                    var extents: c.XGlyphInfo = undefined;
                    c.XftTextExtentsUtf8(self.display, run_font, text[run_start..pos].ptr, @intCast(pos - run_start), &extents);
                    total_width += extents.xOff;
                }
                run_start = pos;
                run_font = font;
            }
            pos = end;
        }
        
        // Flush final run
        if (pos > run_start) {
            var extents: c.XGlyphInfo = undefined;
            c.XftTextExtentsUtf8(self.display, run_font, text[run_start..pos].ptr, @intCast(pos - run_start), &extents);
            total_width += extents.xOff;
        }
        
        return @intCast(total_width);
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
