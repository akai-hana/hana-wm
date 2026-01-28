//! XCB drawing context with proper baseline positioning

const std = @import("std");
const defs = @import("defs");
const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/render.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("stdio.h");
});

pub const DrawContext = struct {
    allocator: std.mem.Allocator,
    conn: *c.xcb_connection_t,
    screen: *c.xcb_screen_t,
    drawable: u32,
    width: u16,
    height: u16,
    picture: u32,
    ft_library: c.FT_Library,
    ft_face: ?c.FT_Face,
    font_height: u16,
    font_ascender: i16,
    current_color: struct {
        red: u16,
        green: u16,
        blue: u16,
        alpha: u16,
    },
    pictformat: u32,
    alpha_format: ?u32,
    font_loaded: bool,

    pub fn init(allocator: std.mem.Allocator, conn: *defs.xcb.xcb_connection_t, screen: *defs.xcb.xcb_screen_t, drawable: u32, width: u16, height: u16) !*DrawContext {
        const dc = try allocator.create(DrawContext);
        errdefer allocator.destroy(dc);

        const c_conn: *c.xcb_connection_t = @ptrCast(conn);
        const c_screen: *c.xcb_screen_t = @ptrCast(screen);

        var ft_lib: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&ft_lib) != 0) {
            return error.FreeTypeInitFailed;
        }
        errdefer _ = c.FT_Done_FreeType(ft_lib);

        const pictformat = try findRGBFormat(c_conn, c_screen);

        const picture = c.xcb_generate_id(c_conn);
        _ = c.xcb_render_create_picture(
            c_conn,
            picture,
            drawable,
            pictformat,
            0,
            null,
        );

        const alpha_format = findAlphaFormat(c_conn) catch |err| {
            std.log.err("[drawing] No alpha format found: {}", .{err});
            return error.NoAlphaFormat;
        };

        dc.* = .{
            .allocator = allocator,
            .conn = c_conn,
            .screen = c_screen,
            .drawable = drawable,
            .width = width,
            .height = height,
            .picture = picture,
            .ft_library = ft_lib,
            .ft_face = null,
            .font_height = 14,
            .font_ascender = 11,
            .current_color = .{
                .red = 0xBBBB,
                .green = 0xBBBB,
                .blue = 0xBBBB,
                .alpha = 0xFFFF,
            },
            .pictformat = pictformat,
            .alpha_format = alpha_format,
            .font_loaded = false,
        };

        return dc;
    }

    pub fn deinit(self: *DrawContext) void {
        if (self.ft_face) |face| {
            _ = c.FT_Done_Face(face);
        }
        _ = c.FT_Done_FreeType(self.ft_library);
        _ = c.xcb_render_free_picture(self.conn, self.picture);
        self.allocator.destroy(self);
    }

    fn findRGBFormat(conn: *c.xcb_connection_t, screen: *c.xcb_screen_t) !u32 {
        const formats_cookie = c.xcb_render_query_pict_formats(conn);
        const formats_reply = c.xcb_render_query_pict_formats_reply(conn, formats_cookie, null) orelse {
            return error.RenderFormatQueryFailed;
        };
        defer std.c.free(formats_reply);

        const formats = c.xcb_render_query_pict_formats_formats(formats_reply);
        const formats_len = c.xcb_render_query_pict_formats_formats_length(formats_reply);

        const depth: u8 = screen.root_depth;

        var i: usize = 0;
        while (i < formats_len) : (i += 1) {
            const fmt = &formats[i];
            if (fmt.type == c.XCB_RENDER_PICT_TYPE_DIRECT and fmt.depth == depth) {
                if ((depth == 32 and fmt.direct.red_shift == 16 and fmt.direct.green_shift == 8 and fmt.direct.blue_shift == 0) or
                    (depth == 24 and fmt.direct.red_shift == 16 and fmt.direct.green_shift == 8 and fmt.direct.blue_shift == 0)) {
                    return fmt.id;
                }
            }
        }

        i = 0;
        while (i < formats_len) : (i += 1) {
            const fmt = &formats[i];
            if (fmt.type == c.XCB_RENDER_PICT_TYPE_DIRECT and fmt.depth == depth) {
                return fmt.id;
            }
        }

        return error.NoSuitableRenderFormat;
    }

    pub fn loadFont(self: *DrawContext, font_name: []const u8) !void {
        var font_path: []const u8 = undefined;
        var size: u16 = 10;

        if (std.mem.indexOf(u8, font_name, ":size=")) |idx| {
            const name_part = font_name[0..idx];
            const size_str = font_name[idx + 6 ..];
            size = std.fmt.parseInt(u16, size_str, 10) catch 10;
            font_path = try self.findFontFile(name_part);
        } else {
            font_path = try self.findFontFile(font_name);
        }
        defer self.allocator.free(font_path);

        const font_path_z = try self.allocator.dupeZ(u8, font_path);
        defer self.allocator.free(font_path_z);

        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(self.ft_library, font_path_z.ptr, 0, &face) != 0) {
            std.log.err("[drawing] Failed to load font from: {s}", .{font_path_z});
            return error.FontLoadFailed;
        }
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_Set_Pixel_Sizes(face, 0, size) != 0) {
            std.log.err("[drawing] Failed to set font size: {}", .{size});
            return error.FontSizeFailed;
        }

        if (self.ft_face) |old_face| {
            _ = c.FT_Done_Face(old_face);
        }

        self.ft_face = face;
        const height_64 = face.*.size.*.metrics.height >> 6;
        const ascender_64 = face.*.size.*.metrics.ascender >> 6;
        self.font_height = @intCast(@max(8, height_64));
        self.font_ascender = @intCast(ascender_64);
        self.font_loaded = true;

        std.log.info("[drawing] Font loaded: height={}, ascender={}", .{ self.font_height, self.font_ascender });
    }

    fn findFontFile(self: *DrawContext, font_name: []const u8) ![]const u8 {
        if (self.findFontWithFcMatch(font_name)) |path| {
            return path;
        } else |_| {}

        const variants = [_][]const u8{
            "DejaVu Sans",
            "Liberation Sans",
            "Noto Sans",
            "monospace",
        };

        for (variants) |variant| {
            if (self.findFontWithFcMatch(variant)) |path| {
                return path;
            } else |_| {}
        }

        return self.findFallbackFont();
    }

    fn findFontWithFcMatch(self: *DrawContext, font_name: []const u8) ![]const u8 {
        const cmd = try std.fmt.allocPrint(self.allocator, "fc-match --format=%{{file}} '{s}'", .{font_name});
        defer self.allocator.free(cmd);

        const cmd_z = try self.allocator.dupeZ(u8, cmd);
        defer self.allocator.free(cmd_z);

        const pipe = c.popen(cmd_z.ptr, "r") orelse return error.FcMatchFailed;
        defer _ = c.pclose(pipe);

        var buf: [4096]u8 = undefined;
        const line = c.fgets(&buf, buf.len, pipe);
        if (line == null) return error.FontNotFound;

        const path = std.mem.trim(u8, std.mem.sliceTo(&buf, 0), " \t\n\r");
        if (path.len == 0) return error.FontNotFound;

        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const fd = std.posix.open(path_z, .{ .ACCMODE = .RDONLY }, 0) catch return error.FontNotFound;
        std.posix.close(fd);

        return try self.allocator.dupe(u8, path);
    }

    fn findFallbackFont(self: *DrawContext) ![]const u8 {
        const fallback_fonts = [_][]const u8{
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
            "/usr/share/fonts/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
            "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
            "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        };

        for (fallback_fonts) |path| {
            const path_z = self.allocator.dupeZ(u8, path) catch continue;
            defer self.allocator.free(path_z);

            const fd = std.posix.open(path_z, .{ .ACCMODE = .RDONLY }, 0) catch continue;
            std.posix.close(fd);

            return try self.allocator.dupe(u8, path);
        }

        return error.FontNotFound;
    }

    pub fn setColor(self: *DrawContext, rgb: u32) void {
        const r: u16 = @intCast((rgb >> 16) & 0xFF);
        const g: u16 = @intCast((rgb >> 8) & 0xFF);
        const b: u16 = @intCast(rgb & 0xFF);

        self.current_color = .{
            .red = r * 0x101,
            .green = g * 0x101,
            .blue = b * 0x101,
            .alpha = 0xFFFF,
        };
    }

    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16) void {
        const color = c.xcb_render_color_t{
            .red = self.current_color.red,
            .green = self.current_color.green,
            .blue = self.current_color.blue,
            .alpha = self.current_color.alpha,
        };

        const rect = c.xcb_rectangle_t{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = width,
            .height = height,
        };

        _ = c.xcb_render_fill_rectangles(
            self.conn,
            c.XCB_RENDER_PICT_OP_SRC,
            self.picture,
            color,
            1,
            &rect,
        );
    }

    pub fn getAscender(self: *DrawContext) i16 {
        return self.font_ascender;
    }

    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8) !void {
        if (!self.font_loaded) {
            std.log.warn("[drawing] drawText called but font not loaded", .{});
            return;
        }

        const face = self.ft_face orelse {
            std.log.warn("[drawing] drawText called but no face", .{});
            return error.NoFont;
        };
        
        if (self.alpha_format == null) {
            std.log.warn("[drawing] drawText called but no alpha format", .{});
            return;
        }

        var cursor_x: i16 = @intCast(x);
        const baseline_y: i16 = @intCast(y);

        for (text) |ch| {
            const load_result = c.FT_Load_Char(face, ch, c.FT_LOAD_RENDER);
            if (load_result != 0) {
                cursor_x += @intCast(face.*.glyph.*.advance.x >> 6);
                continue;
            }

            const glyph = face.*.glyph;
            const bitmap = &glyph.*.bitmap;

            if (bitmap.width == 0 or bitmap.rows == 0) {
                cursor_x += @intCast(glyph.*.advance.x >> 6);
                continue;
            }

            const glyph_x = cursor_x + @as(i16, @intCast(glyph.*.bitmap_left));
            const glyph_y = baseline_y - @as(i16, @intCast(glyph.*.bitmap_top));

            // More lenient clipping - allow partial glyphs
            if (glyph_x + @as(i16, @intCast(bitmap.width)) <= 0 or 
                glyph_x >= self.width or
                glyph_y + @as(i16, @intCast(bitmap.rows)) <= 0 or
                glyph_y >= self.height) {
                cursor_x += @intCast(glyph.*.advance.x >> 6);
                continue;
            }

            self.drawGlyph(glyph_x, glyph_y, bitmap) catch |err| {
                std.log.warn("[drawing] Failed to draw glyph '{}': {}", .{ ch, err });
                cursor_x += @intCast(glyph.*.advance.x >> 6);
                continue;
            };

            cursor_x += @intCast(glyph.*.advance.x >> 6);
        }
    }

    fn drawGlyph(self: *DrawContext, x: i16, y: i16, bitmap: *const c.FT_Bitmap) !void {
        if (bitmap.width == 0 or bitmap.rows == 0) return;

        const alpha_fmt = self.alpha_format orelse return error.NoAlphaFormat;

        const pixmap = c.xcb_generate_id(self.conn);
        defer _ = c.xcb_free_pixmap(self.conn, pixmap);

        _ = c.xcb_create_pixmap(
            self.conn,
            8,
            pixmap,
            self.drawable,
            @intCast(bitmap.width),
            @intCast(bitmap.rows),
        );

        const glyph_picture = c.xcb_generate_id(self.conn);
        defer _ = c.xcb_render_free_picture(self.conn, glyph_picture);

        _ = c.xcb_render_create_picture(
            self.conn,
            glyph_picture,
            pixmap,
            alpha_fmt,
            0,
            null,
        );

        const gc = c.xcb_generate_id(self.conn);
        defer _ = c.xcb_free_gc(self.conn, gc);

        _ = c.xcb_create_gc(self.conn, gc, pixmap, 0, null);

        _ = c.xcb_put_image(
            self.conn,
            c.XCB_IMAGE_FORMAT_Z_PIXMAP,
            pixmap,
            gc,
            @intCast(bitmap.width),
            @intCast(bitmap.rows),
            0,
            0,
            0,
            8,
            @intCast(bitmap.width * bitmap.rows),
            bitmap.buffer,
        );

        const color = c.xcb_render_color_t{
            .red = self.current_color.red,
            .green = self.current_color.green,
            .blue = self.current_color.blue,
            .alpha = self.current_color.alpha,
        };

        const solid_fill = c.xcb_generate_id(self.conn);
        defer _ = c.xcb_render_free_picture(self.conn, solid_fill);

        _ = c.xcb_render_create_solid_fill(self.conn, solid_fill, color);

        _ = c.xcb_render_composite(
            self.conn,
            c.XCB_RENDER_PICT_OP_OVER,
            solid_fill,
            glyph_picture,
            self.picture,
            0,
            0,
            0,
            0,
            x,
            y,
            @intCast(bitmap.width),
            @intCast(bitmap.rows),
        );
    }

    fn findAlphaFormat(conn: *c.xcb_connection_t) !u32 {
        const formats_cookie = c.xcb_render_query_pict_formats(conn);
        const formats_reply = c.xcb_render_query_pict_formats_reply(conn, formats_cookie, null) orelse {
            return error.RenderFormatQueryFailed;
        };
        defer std.c.free(formats_reply);

        const formats = c.xcb_render_query_pict_formats_formats(formats_reply);
        const formats_len = c.xcb_render_query_pict_formats_formats_length(formats_reply);

        var i: usize = 0;
        while (i < formats_len) : (i += 1) {
            const fmt = &formats[i];
            if (fmt.type == c.XCB_RENDER_PICT_TYPE_DIRECT and fmt.depth == 8) {
                return fmt.id;
            }
        }

        return error.NoAlphaFormat;
    }

    pub fn drawTextEllipsis(self: *DrawContext, x: u16, y: u16, text: []const u8, max_width: u16) !void {
        const text_width = self.textWidth(text);
        if (text_width <= max_width) {
            try self.drawText(x, y, text);
            return;
        }

        const ellipsis = "...";
        const ellipsis_width = self.textWidth(ellipsis);

        if (max_width <= ellipsis_width) {
            try self.drawText(x, y, ellipsis);
            return;
        }

        const available_width = max_width - ellipsis_width;

        var len: usize = 0;
        while (len < text.len) : (len += 1) {
            const width = self.textWidth(text[0..len]);
            if (width > available_width) {
                if (len > 0) len -= 1;
                break;
            }
        }

        if (len > 0) {
            try self.drawText(x, y, text[0..len]);
            try self.drawText(x + self.textWidth(text[0..len]), y, ellipsis);
        } else {
            try self.drawText(x, y, ellipsis);
        }
    }

    pub fn textWidth(self: *DrawContext, text: []const u8) u16 {
        if (!self.font_loaded) return 0;

        const face = self.ft_face orelse return 0;

        var total_width: i32 = 0;
        for (text) |ch| {
            if (c.FT_Load_Char(face, ch, c.FT_LOAD_DEFAULT) != 0) continue;
            total_width += @intCast(face.*.glyph.*.advance.x >> 6);
        }

        return @intCast(@max(0, total_width));
    }

    pub fn flush(self: *DrawContext) void {
        _ = c.xcb_flush(self.conn);
    }
};
